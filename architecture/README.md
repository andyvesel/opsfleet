# Innovate Inc. — Cloud Arch.

## Cloud provider: AWS

Went with AWS over GCP mainly because the EKS ecosystem is more mature, there's a larger pool of engineers who know it, and the managed services around it (RDS, ECR, Secrets Manager) are battle-tested. GCP would work fine too, but AWS is the safer default for a startup that'll be hiring.

---

## Account structure

Three accounts under AWS Organizations:

| Account | What it's for |
|---|---|
| **management** | Billing, SSO, org-level policies. Nothing runs here. |
| **staging** | Pre-prod. CI deploys here first. |
| **production** | Live traffic. Stricter access controls. |

We want to avoid the creation of just one account. It's a bad IAM policy or a runaway cost spike in staging shouldn't be able to touch production. Splitting them now would be relatively cheap.

---

## Network

Each account gets its own VPC:

```
VPC 10.0.0.0/16
├── Public subnets   — ALB, NAT Gateway
└── Private subnets  — EKS nodes, RDS
```

Traffic comes in through an ALB in the public subnet. Everything else, like nodes, databases sit in private subnets with no public IPs. Outbound goes through NAT.

Security groups are tight: ALB talks to the app on 8080, app talks to RDS on 5432, nothing else is open. VPC Flow Logs go to CloudWatch for audit purposes.

Staging and prod are fully isolated — no peering between them.

---

## Kubernetes (EKS)

EKS with Karpenter for node autoscaling. Two node groups:

- **system** 2× m7g.large Graviton On-Demand nodes. Runs Karpenter itself, CoreDNS, monitoring. Tainted so app workloads don't land here.
- **app** Karpenter-managed, Spot + On-Demand mix, arm64 preferred for cost. Scales to zero when idle, scales out fast when traffic spikes.

Flask backend and React frontend (served via nginx) are separate Deployments, each with an HPA. Minimum 2 replicas per service so there's always one pod per AZ.

Resource `requests` and `limits` are set on every container — without these, HPA and Karpenter can't do the job properly.

### Containers & CI/CD

Images are built in GitHub Actions on every merge to `main`, pushed to ECR (private, per-account). Tags are Git SHAs — no `latest` in production. ECR image scanning is on; critical CVEs block promotion.

```
merge to main
  → build image
  → push to ECR
  → deploy to staging (automatic)
  → deploy to prod (manual approval)
```

Helm for templating — one chart, separate values files per environment.

---

## Database

RDS PostgreSQL.(The Aurora would be overkill and costs more). RDS is simpler to reason about and plenty capable until read replicas or connection pooling become a real problem.

- **Prod**: Multi-AZ, automatic failover (~60s), no manual intervention needed
- **Staging**: Single-AZ, no point paying for HA here
- Storage: gp3 with autoscaling, encrypted at rest (KMS), TLS enforced in transit
- Backups: automated daily snapshots, 14-day retention, PITR down to 5 minutes

Credentials live in Secrets Manager and get injected into pods via the Secrets Store CSI driver. No passwords in env vars or ConfigMaps.

---

## High-level diagram

```
                   ┌──────────────────────────────────────────────┐
                   │             AWS — Production Account          │
                   │                                               │
  Users ─ HTTPS ─► │  ALB  (public subnet)                        │
                   │   │                                           │
                   │  ┌▼─────────────────────────────────────┐    │
                   │  │           EKS Cluster                 │    │
                   │  │                                        │    │
                   │  │   Flask API        React (nginx)       │    │
                   │  │   Deployment       Deployment          │    │
                   │  │        │                               │    │
                   │  │   Karpenter nodes (Spot + On-Demand)  │    │
                   │  └──────────────────┬────────────────────┘    │
                   │                     │                          │
                   │   RDS PostgreSQL  (private subnet, Multi-AZ)  │
                   │                                               │
                   │   ECR · Secrets Manager · CloudWatch          │
                   └──────────────────────────────────────────────┘

                   GitHub Actions → ECR → staging → [approval] → prod
```

---

## Scaling to the traffic increase (i.e. millions of users)

The following needs to be tuned:

- **EKS**: HPA + Karpenter handle it. Maybe add KEDA for queue-based scaling if async jobs appear.
- **RDS**: bump the instance size first, then add a read replica when reads dominate. If connection count becomes the bottleneck, add PgBouncer or move to Aurora Serverless v2.
- **Frontend**: put CloudFront in front of the ALB. Static assets get cached at the edge, origin load drops significantly.

---

## Potential issues at scale

**Database becomes the bottleneck first.** PostgreSQL on a single RDS instance will hit connection limits well before it hits CPU or memory limits. Flask apps tend to open a connection per request unless a connection pooler is in place. Add PgBouncer (as a sidecar or a small dedicated Deployment) early — before you actually need it.

**Stateful sessions don't scale horizontally.** If the Flask app stores session state in memory or local files, adding more replicas breaks things. Sessions need to be either stateless (JWT) or stored externally (ElastiCache Redis) before horizontal scaling works correctly.

**Single NAT Gateway is a hidden cost and a single point of failure.** One NAT Gateway per VPC is fine for a POC but at high egress volume the cost adds up, and it's in a single AZ. At scale, deploy one NAT Gateway per AZ and route each AZ's private subnet through its own.

**ECR image pull latency under rapid scale-out.** When Karpenter provisions many nodes at once, they all pull images simultaneously. Large images slow this down. Keep images small, use multi-stage builds, and consider enabling ECR pull-through cache or pre-pulling images via a DaemonSet if cold-start time matters.

**ALB target group deregistration lag.** During rolling deployments, the ALB keeps sending traffic to terminating pods for up to 300s by default. Set `deregistrationDelay` to something sensible (30–60s) and add a `preStop` sleep hook in the container to avoid dropped requests during deploys.

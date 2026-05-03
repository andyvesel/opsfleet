# EKS + Karpenter

EKS 1.35 cluster in a dedicated VPC with Karpenter managing x86 and Graviton (arm64) node pools. Nodes run on Spot by default, falls back to On-Demand.

## Requirements

- Terraform >= 1.9
- AWS CLI with credentials
- `kubectl`, `helm`

## Usage

```bash
terraform init
terraform apply -var="cluster_name=my-cluster"
```

Then configure kubectl:

```bash
aws eks update-kubeconfig --region eu-west-1 --name my-cluster
```

## Running workloads

Target a specific architecture via `nodeSelector`:

```bash
# x86
kubectl apply -f examples/deployment-x86.yaml

# Graviton (arm64)
kubectl apply -f examples/deployment-arm64.yaml
```

Karpenter will provision a node automatically if none is available. Check what came up:

```bash
kubectl get nodes -L kubernetes.io/arch
```

To force On-Demand for a workload, add to `spec.template.spec`:

```yaml
nodeSelector:
  kubernetes.io/arch: arm64
  karpenter.sh/capacity-type: on-demand
```

## Troubleshooting

```bash
# Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50

# Why is my pod pending?
kubectl describe pod <pod-name>

# What arch are my nodes?
kubectl get nodes -L kubernetes.io/arch
```

Spot unavailability: Karpenter falls back to On-Demand automatically. If it keeps failing, widen the instance requirements in the NodePool.

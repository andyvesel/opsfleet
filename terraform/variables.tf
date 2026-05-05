variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "api_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS API endpoint. Empty list allows all (0.0.0.0/0). Restrict to VPN/office CIDRs in production."
  type        = list(string)
  default     = []
}

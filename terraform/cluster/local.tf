locals {
  azs               = slice(data.aws_availability_zones.available.names, 0, 3)
  karpenter_version = "1.13.1"
  pod_cidr          = var.pod_cidr
}

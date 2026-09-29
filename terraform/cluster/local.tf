locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
  pod_cidr = var.pod_cidr
}

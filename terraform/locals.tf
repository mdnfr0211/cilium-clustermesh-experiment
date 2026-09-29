locals {
  cluster_1 = {
    name                = var.cluster_1_name
    kubernetes_version  = "1.36"
    node_instance_types = ["c7i-flex.large"]
    pod_cidr            = "10.2.0.0/16"
    vpc_cidr            = "10.0.0.0/16"
  }
  cluster_2 = {
    name                = var.cluster_2_name
    kubernetes_version  = "1.36"
    node_instance_types = ["c7i-flex.large"]
    pod_cidr            = "10.3.0.0/16"
    service_ipv4_cidr   = "172.21.0.0/16"
    vpc_cidr            = "10.1.0.0/16"
  }
}

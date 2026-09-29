variable "aws_region" {
  description = "AWS region used by the Kubernetes provider token command"
  type        = string
}

variable "ca_cert_pem" {
  description = "Shared ClusterMesh CA certificate"
  type        = string
}

variable "ca_key_pem" {
  description = "Shared ClusterMesh CA private key"
  type        = string
  sensitive   = true
}

variable "cilium_wait" {
  description = "Whether Helm waits for Cilium resources to become ready"
  type        = bool
  default     = true
}

variable "cluster_id" {
  description = "Unique Cilium numeric cluster ID"
  type        = number
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group"
  type        = list(string)
}

variable "nginx_service_affinity" {
  description = "Cilium endpoint affinity for the demo nginx global Service"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "local", "remote"], var.nginx_service_affinity)
    error_message = "nginx_service_affinity must be one of: none, local, remote."
  }
}

variable "peer_cluster_name" {
  description = "Cilium cluster name of the ClusterMesh peer"
  type        = string
}

variable "peer_clustermesh_address" {
  description = "Private DNS name of the peer ClusterMesh API server"
  type        = string
}

variable "peer_vpc_cidr" {
  description = "VPC CIDR block of the ClusterMesh peer"
  type        = string
}

variable "pod_cidr" {
  description = "Cilium cluster-pool pod CIDR"
  type        = string
}

variable "service_ipv4_cidr" {
  description = "Optional Kubernetes service IPv4 CIDR"
  type        = string
  default     = null
  nullable    = true
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

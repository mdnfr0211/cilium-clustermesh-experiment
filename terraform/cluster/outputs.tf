output "cluster_ca" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "clustermesh_nlb_hostname" {
  description = "Hostname assigned to the ClusterMesh API server NLB"
  value       = kubernetes_service_v1.clustermesh_apiserver.status[0].load_balancer[0].ingress[0].hostname
}

output "clustermesh_dns_name" {
  description = "Private DNS name for this ClusterMesh API server"
  value       = "${var.cluster_name}.mesh.cilium.io"
}

output "node_security_group_id" {
  value = module.node_security_group.security_group_id
}

output "pod_cidr" {
  value = local.pod_cidr
}

output "route_table_ids" {
  value = concat(module.vpc.private_route_table_ids, module.vpc.public_route_table_ids)
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

resource "aws_route" "cluster_1_to_cluster_2" {
  for_each = {
    for index, route_table_id in module.cluster_1.route_table_ids : index => route_table_id
  }

  destination_cidr_block    = module.cluster_2.vpc_cidr
  route_table_id            = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.clusters.id
}

resource "aws_route" "cluster_2_to_cluster_1" {
  for_each = {
    for index, route_table_id in module.cluster_2.route_table_ids : index => route_table_id
  }

  destination_cidr_block    = module.cluster_1.vpc_cidr
  route_table_id            = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.clusters.id
}

resource "aws_vpc_peering_connection" "clusters" {
  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  auto_accept = true
  peer_vpc_id = module.cluster_1.vpc_id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = {
    Name         = "${local.cluster_2.name}-to-${local.cluster_1.name}"
    peer-cluster = local.cluster_1.name
  }
  vpc_id = module.cluster_2.vpc_id
}

resource "tls_private_key" "clustermesh_ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "clustermesh_ca" {
  allowed_uses      = ["cert_signing", "digital_signature", "key_encipherment"]
  is_ca_certificate = true
  private_key_pem   = tls_private_key.clustermesh_ca.private_key_pem

  subject {
    common_name  = "clustermesh"
    organization = "cilium-clustermesh"
  }

  validity_period_hours = 24 * 365 * 10
}

module "cluster_1" {
  source = "./cluster"

  aws_region               = var.aws_region
  ca_cert_pem              = tls_self_signed_cert.clustermesh_ca.cert_pem
  ca_key_pem               = tls_private_key.clustermesh_ca.private_key_pem
  cilium_wait              = true
  cluster_id               = 1
  cluster_name             = local.cluster_1.name
  cluster_version          = local.cluster_1.kubernetes_version
  node_instance_types      = local.cluster_1.node_instance_types
  nginx_service_affinity   = "remote"
  peer_cluster_name        = local.cluster_2.name
  peer_clustermesh_address = module.cluster_2.clustermesh_dns_name
  peer_vpc_cidr            = local.cluster_2.vpc_cidr
  pod_cidr                 = local.cluster_1.pod_cidr
  vpc_cidr                 = local.cluster_1.vpc_cidr
}

module "cluster_2" {
  source = "./cluster"

  aws_region               = var.aws_region
  ca_cert_pem              = tls_self_signed_cert.clustermesh_ca.cert_pem
  ca_key_pem               = tls_private_key.clustermesh_ca.private_key_pem
  cilium_wait              = false
  cluster_id               = 2
  cluster_name             = local.cluster_2.name
  cluster_version          = local.cluster_2.kubernetes_version
  node_instance_types      = local.cluster_2.node_instance_types
  nginx_service_affinity   = "remote"
  peer_cluster_name        = local.cluster_1.name
  peer_clustermesh_address = module.cluster_1.clustermesh_dns_name
  peer_vpc_cidr            = local.cluster_1.vpc_cidr
  pod_cidr                 = local.cluster_2.pod_cidr
  service_ipv4_cidr        = local.cluster_2.service_ipv4_cidr
  vpc_cidr                 = local.cluster_2.vpc_cidr
}

module "clustermesh_dns" {
  source  = "terraform-aws-modules/route53/aws"
  version = "~> 6.0"

  comment = "Private DNS names for Cilium ClusterMesh"
  name    = "mesh.cilium.io"
  records = {
    cluster_1 = {
      full_name = module.cluster_1.clustermesh_dns_name
      type      = "CNAME"
      ttl       = 60
      records   = [module.cluster_1.clustermesh_nlb_hostname]
    }
    cluster_2 = {
      full_name = module.cluster_2.clustermesh_dns_name
      type      = "CNAME"
      ttl       = 60
      records   = [module.cluster_2.clustermesh_nlb_hostname]
    }
  }
  vpc = {
    cluster_1 = {
      vpc_id = module.cluster_1.vpc_id
    }
    cluster_2 = {
      vpc_id = module.cluster_2.vpc_id
    }
  }
}

resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"
}

resource "aws_security_group_rule" "cluster_nodes_443" {
  description              = "Node groups to cluster API"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = module.node_security_group.security_group_id
  to_port                  = 443
  type                     = "ingress"
}

resource "helm_release" "cilium" {
  chart            = "cilium"
  create_namespace = true
  name             = "cilium"
  namespace        = "cilium"
  repository       = "https://helm.cilium.io/"
  set = [
    {
      name  = "cluster.id"
      value = var.cluster_id
    },
    {
      name  = "cluster.name"
      value = var.cluster_name
    },
    {
      name  = "ipam.operator.clusterPoolIPv4PodCIDRList"
      value = "{${var.pod_cidr}}"
    },
    {
      name  = "k8sServiceHost"
      value = replace(module.eks.cluster_endpoint, "https://", "")
    },
    {
      name  = "k8sServicePort"
      value = 443
    },
    {
      name  = "clustermesh.config.enabled"
      value = "true"
    },
    {
      name  = "clustermesh.config.clusters.${var.peer_cluster_name}.address"
      value = var.peer_clustermesh_address
    },
    {
      name  = "clustermesh.config.clusters.${var.peer_cluster_name}.port"
      value = 2379
    },
  ]
  timeout = 900
  values = [
    file("${path.module}/fixtures/cilium-values.yaml"),
    yamlencode({
      tls = {
        ca = {
          cert = base64encode(var.ca_cert_pem)
          key  = base64encode(var.ca_key_pem)
        }
      }
    })
  ]
  version = "1.20.0"
  wait    = var.cilium_wait

  depends_on = [module.eks_blueprints_addons]
}

resource "kubernetes_service_v1" "clustermesh_apiserver" {
  metadata {
    name      = "clustermesh-apiserver"
    namespace = "cilium"
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-scheme"                  = "internal"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"         = "instance"
      "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "preserve_client_ip.enabled=false"
    }
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "service.k8s.aws/nlb"
    external_traffic_policy = "Cluster"
    internal_traffic_policy = "Cluster"
    selector = {
      "k8s-app" = "clustermesh-apiserver"
    }

    port {
      port     = 2379
      protocol = "TCP"
    }
  }

  wait_for_load_balancer = true

  depends_on = [
    helm_release.cilium,
    kubectl_manifest.albc_targetgroupbinding_webhooks,
  ]
}

resource "kubectl_manifest" "gp3_storage_class" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3"
      annotations = {
        "storageclass.kubernetes.io/is-default-class" = "true"
      }
    }
    provisioner          = "ebs.csi.aws.com"
    volumeBindingMode    = "WaitForFirstConsumer"
    allowVolumeExpansion = true
    parameters = {
      type      = "gp3"
      encrypted = "true"
    }
  })

  depends_on = [module.eks_blueprints_addons]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  compute_config = {
    enabled = false
  }
  create_auto_mode_iam_resources           = false
  create_node_security_group               = false
  enable_cluster_creator_admin_permissions = true
  enabled_log_types                        = []
  endpoint_private_access                  = true
  endpoint_public_access                   = true
  kubernetes_version                       = var.cluster_version
  name                                     = var.cluster_name
  node_security_group_id                   = module.node_security_group.security_group_id
  service_ipv4_cidr                        = var.service_ipv4_cidr
  subnet_ids                               = module.vpc.private_subnets
  vpc_id                                   = module.vpc.vpc_id
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  aws_load_balancer_controller = {
    chart_version = "3.4.0"
    set = [
      { name = "enableServiceMutatorWebhook", value = "false" },
      { name = "controllerConfig.featureGates.ALBGatewayAPI", value = "true" },
      { name = "vpcId", value = module.vpc.vpc_id },
    ]
  }
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_name     = module.eks.cluster_name
  cluster_version  = module.eks.cluster_version
  eks_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        nodeSelector = { workload = "system" }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
      configuration_values = jsonencode({
        nodeSelector = { workload = "system" }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.iam_role_ebs_csi.arn
    }
  }
  enable_aws_load_balancer_controller = true
  enable_karpenter                    = true
  karpenter = {
    repository_username = "AWS"
  }
  karpenter_enable_spot_termination = true
  karpenter_node = {
    iam_role_use_name_prefix = false
  }
  oidc_provider_arn = module.eks.oidc_provider_arn

  depends_on = [module.eks]
}

module "eks_managed_node_group" {
  source   = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version  = "~> 21.0"
  for_each = { 0 = "system", 1 = "cilium" }

  cluster_name                      = module.eks.cluster_name
  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  cluster_service_cidr              = module.eks.cluster_service_cidr
  desired_size                      = 1
  disk_size                         = 20
  instance_types                    = var.node_instance_types
  labels = {
    workload = each.value
  }
  max_size   = 1
  min_size   = 1
  name       = each.value
  subnet_ids = module.vpc.private_subnets
  update_config = {
    update_strategy            = "DEFAULT"
    max_unavailable_percentage = 100
  }
  vpc_security_group_ids = [module.eks.node_security_group_id]
}

module "iam_role_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  attach_ebs_csi_policy = true
  name                  = "ebs-csi-controller-role"
  oidc_providers = {
    0 = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  policies = {
    EC2FullAccess = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  }
}

module "node_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  description             = "Node security group for ${var.cluster_name}"
  egress_ipv6_cidr_blocks = []
  egress_rules            = ["all-all"]
  ingress_with_cidr_blocks = [
    { description = "Cilium VXLAN from ${var.peer_cluster_name} nodes", protocol = "udp", from_port = 8472, to_port = 8472, cidr_blocks = var.peer_vpc_cidr },
    { description = "Cilium WireGuard from ${var.peer_cluster_name} nodes", protocol = "udp", from_port = 51871, to_port = 51871, cidr_blocks = var.peer_vpc_cidr },
    { description = "ClusterMesh KVStoreMesh + NLB health probes from ${var.peer_cluster_name}", protocol = "tcp", from_port = 2379, to_port = 2379, cidr_blocks = var.peer_vpc_cidr },
    { description = "clustermesh-apiserver NLB health probes from own VPC", protocol = "tcp", from_port = 2379, to_port = 2379, cidr_blocks = var.vpc_cidr },
    { description = "Cilium node health probes (TCP 4240) from ${var.peer_cluster_name}", protocol = "tcp", from_port = 4240, to_port = 4240, cidr_blocks = var.peer_vpc_cidr },
    { description = "Cilium node health probes (UDP 4240) from ${var.peer_cluster_name}", protocol = "udp", from_port = 4240, to_port = 4240, cidr_blocks = var.peer_vpc_cidr },
    { description = "Cilium node health probes (ICMP) from ${var.peer_cluster_name}", protocol = "icmp", from_port = -1, to_port = -1, cidr_blocks = var.peer_vpc_cidr },
  ]
  ingress_with_self = [
    { description = "Node to node CoreDNS", protocol = "tcp", from_port = 53, to_port = 53 },
    { description = "Node to node CoreDNS UDP", protocol = "udp", from_port = 53, to_port = 53 },
    { description = "Node to node ingress on ephemeral ports", protocol = "tcp", from_port = 1025, to_port = 65535 },
    { description = "Cilium health probes within cluster", protocol = "-1", from_port = 0, to_port = 0 },
  ]
  ingress_with_source_security_group_id = [
    { description = "Cluster API to node groups", protocol = "tcp", from_port = 443, to_port = 443, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node kubelets", protocol = "tcp", from_port = 10250, to_port = 10250, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node 4443/tcp webhook", protocol = "tcp", from_port = 4443, to_port = 4443, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node 10251/tcp webhook", protocol = "tcp", from_port = 10251, to_port = 10251, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node 6443/tcp webhook", protocol = "tcp", from_port = 6443, to_port = 6443, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node 8443/tcp webhook", protocol = "tcp", from_port = 8443, to_port = 8443, source_security_group_id = module.eks.cluster_primary_security_group_id },
    { description = "Cluster API to node 9443/tcp webhook", protocol = "tcp", from_port = 9443, to_port = 9443, source_security_group_id = module.eks.cluster_primary_security_group_id },
  ]
  name = "${var.cluster_name}-node"
  tags = {
    Name                     = "${var.cluster_name}-node"
    "karpenter.sh/discovery" = var.cluster_name
  }
  vpc_id = module.vpc.vpc_id
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  azs                          = local.azs
  cidr                         = var.vpc_cidr
  create_database_subnet_group = true
  database_subnets             = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 20)]
  enable_dns_hostnames         = true
  enable_dns_support           = true
  enable_nat_gateway           = true
  name                         = "${var.cluster_name}-vpc"
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
  private_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 10)]
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
  public_subnets     = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index)]
  single_nat_gateway = true
}

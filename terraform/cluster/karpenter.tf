resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "mesh"
    }
    spec = {
      amiFamily = "AL2023"
      role      = module.eks_blueprints_addons.karpenter.node_iam_role_name
      subnetSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = var.cluster_name
        }
      }]
      securityGroupSelectorTerms = [{
        tags = {
          "karpenter.sh/discovery" = var.cluster_name
        }
      }]
    }
  })

  depends_on = [module.eks_blueprints_addons]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata = {
      name     = "mesh"
      workload = "mesh"
    }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            name = "mesh"
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = ["c7i-flex.large", "m7i-flex.large"] },
          ]
        }
      }
      limits = {
        cpu    = "100"
        memory = "200Gi"
      }
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}

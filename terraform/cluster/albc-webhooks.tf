resource "kubectl_manifest" "albc_targetgroupbinding_webhooks" {
  for_each = {
    mutating = {
      kind         = "MutatingWebhookConfiguration"
      webhook_name = "mtargetgroupbinding.elbv2.k8s.aws"
    }
    validating = {
      kind         = "ValidatingWebhookConfiguration"
      webhook_name = "vtargetgroupbinding.elbv2.k8s.aws"
    }
  }

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = each.value.kind
    metadata = {
      name = "aws-load-balancer-webhook"
    }
    webhooks = [{
      name          = each.value.webhook_name
      failurePolicy = "Ignore"
    }]
  })

  field_manager     = "terraform"
  force_conflicts   = true
  server_side_apply = true

  depends_on = [module.eks_blueprints_addons]
}

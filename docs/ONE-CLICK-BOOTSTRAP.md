# One-command ClusterMesh deployment

After an infrastructure teardown, create the complete environment with:

```bash
terraform -chdir=terraform init && terraform -chdir=terraform apply
```

Run Terraform from `terraform/` only. Its root module calls `cluster-1` and
`cluster-2`; it owns the shared CA, VPC peering, peer routes, and the private
`mesh.cilium.io` hosted zone. The cluster directories are child modules, not
independent Terraform entry points.

The root Terraform configuration creates the shared CA, both VPCs and EKS
clusters, VPC peering, Cilium, the internal ClusterMesh NLBs, private Route53
records, and both sides of ClusterMesh. Cilium is configured to leave its API
server Service externally created. Terraform creates that Service, waits for
the AWS Load Balancer Controller to report the NLB hostname, and passes the
hostname directly to `terraform-aws-modules/route53/aws` in the same graph.

Prerequisites are Terraform, AWS CLI credentials for the target account, and
the `kubectl` binary. The provider token commands call the AWS CLI with the
configured region, while the AWS Load Balancer Controller Helm post-renderer
uses `kubectl kustomize`; neither needs a local kubeconfig. No manual `kubectl
patch`, secret creation, Route53 edit, or NLB modification is needed.

Each cluster uses a separately managed node security group. It deliberately has
no `kubernetes.io/cluster/<name>` tag, leaving the EKS primary security group as
the sole discovery-tagged group on every worker ENI. This satisfies the AWS Load
Balancer Controller without any tag deletion or target-binding reconciliation
workaround.

There is no bootstrap script or staged apply: resource dependencies drive the
complete deployment from a normal Terraform apply.

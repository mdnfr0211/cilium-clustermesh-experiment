# ClusterMesh apply

The root `terraform/` directory is the only Terraform state and execution
entry point. `cluster-1` and `cluster-2` are child modules.

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

The apply creates both EKS clusters, peering and routes, the Cilium releases,
and the two ClusterMesh API server Services. Each Service waits for its NLB
hostname; the Route53 module then creates the private `mesh.cilium.io` zone
and CNAMEs in that same apply. No target applies, mesh tfvars, hostname files,
or `kubectl` commands are required.

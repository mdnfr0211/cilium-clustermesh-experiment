# Cilium ClusterMesh on Amazon EKS

A Terraform lab that creates two EKS clusters connected with Cilium
ClusterMesh. It is designed to be deployed from the root `terraform/`
directory in one apply, with no manual Kubernetes patching or Load Balancer
reconciliation.

## What it creates

- Two isolated VPCs and EKS clusters: `cluster-1` and `cluster-2`
- VPC peering and routes for node-to-node connectivity
- Cilium with VXLAN, WireGuard node encryption, Hubble, Gateway API, and
  ClusterMesh enabled
- An internal NLB for each ClusterMesh API server
- A Route53 private zone, `mesh.cilium.io`, associated with both VPCs
- Private names such as `cluster-2.mesh.cilium.io` for the NLBs
- AWS Load Balancer Controller, EBS CSI, Karpenter, and a small global
  `nginx` connectivity demo in each cluster

The private DNS names are important: Cilium's ClusterMesh API server
certificate covers `*.mesh.cilium.io`, whereas an AWS-generated NLB hostname
is not a certificate SAN. The NLB remains a TCP pass-through; Cilium etcd
terminates and verifies mutual TLS.

## Architecture

```text
cluster-1 KVStoreMesh
  -> cluster-2.mesh.cilium.io
  -> internal NLB TCP/2379
  -> NodePort
  -> cluster-2 clustermesh-apiserver (mTLS)

Application pods
  -> Cilium global Service
  -> VXLAN + WireGuard between cluster nodes
  -> remote pod
```

The root module owns the shared infrastructure: the CA, VPC peering, routes,
and private hosted zone. Both clusters are instances of the reusable
[`terraform/cluster`](terraform/cluster) module. Their distinct settings are
passed from the root: IDs, CIDRs, service CIDR, and peer information.

## Prerequisites

- Terraform 1.0 or later
- AWS CLI authenticated to the target AWS account
- AWS permissions to create EKS, EC2/VPC, IAM, Route53, and EKS add-on
  resources
- `kubectl` for the optional post-deployment demo

This lab currently provisions both clusters in **one AWS account**. ClusterMesh
can span accounts, but cross-account use requires separate AWS provider
credentials, requester/accepter VPC peering, routes in both accounts, and an
authorized cross-account Route53 private-zone association.

## Deploy

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Terraform waits for each ClusterMesh API server Service to receive its NLB
hostname, then creates the Route53 CNAME records. No separate bootstrap step,
`kubectl patch`, or manual NLB change is required.

## Verify the mesh

Configure local contexts after apply:

```sh
aws eks update-kubeconfig --region ap-south-1 --name cluster-1 --alias cluster-1
aws eks update-kubeconfig --region ap-south-1 --name cluster-2 --alias cluster-2
```

The demo deploys an identically named global Service, `nginx`, in the global
`test-mesh` namespace. Both copies use remote affinity, so in this two-cluster
lab a request goes to the peer cluster:

```sh
kubectl --context cluster-1 -n test-mesh exec mesh-client -- \
  curl -s http://nginx.test-mesh.svc.cluster.local
# served-by=cluster-2

kubectl --context cluster-2 -n test-mesh exec mesh-client -- \
  curl -s http://nginx.test-mesh.svc.cluster.local
# served-by=cluster-1
```

For additional mesh state, inspect Cilium's status:

```sh
kubectl --context cluster-1 -n kube-system exec ds/cilium -- \
  cilium-dbg clustermesh status --wait
```

## Teardown

```sh
terraform -chdir=terraform destroy
```

## Security note

For this lab, Terraform creates the shared ClusterMesh CA and stores its
private key in Terraform state. In production, use an organization-controlled
CA or AWS Private CA with cert-manager; share the trust chain, not server or
client private keys.

## Further reading

- [ClusterMesh setup](https://docs.cilium.io/en/stable/network/clustermesh/setup/)
- [Global Service affinity](https://docs.cilium.io/en/stable/network/clustermesh/affinity/)
- [Significant troubleshooting record](docs/TROUBLESHOOTING-LOG.md)

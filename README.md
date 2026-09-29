# Cilium ClusterMesh on Amazon EKS

This Terraform lab creates two EKS clusters connected with Cilium
ClusterMesh. It is intended to explore a different Kubernetes networking
model: pod addressing is decoupled from VPC addressing, service routing and
policy use an eBPF datapath rather than large iptables chains, traffic between
nodes is encrypted, and remote Service backends can be selected without a
sidecar in every application pod.

## Why Cilium

### Decouple pod capacity from VPC address capacity

The AWS VPC CNI normally assigns pod addresses from the VPC. That is simple,
but large or dense clusters can consume VPC secondary IP capacity quickly.

This lab uses Cilium cluster-pool IPAM and VXLAN. Nodes keep their VPC
addresses, while pods use Cilium-managed ranges:

| Cluster | VPC CIDR | Pod CIDR |
| --- | --- | --- |
| `cluster-1` | `10.0.0.0/16` | `10.2.0.0/16` |
| `cluster-2` | `10.1.0.0/16` | `10.3.0.0/16` |

That means pod capacity can be planned independently of VPC secondary IP
capacity. It does not remove the need for network design: VPC, node, pod, and
service ranges must be unique and non-overlapping, and nodes in all connected
clusters must be able to reach each other.

### Move service routing and policy away from iptables

Kubernetes service routing and policy enforcement have traditionally relied
heavily on iptables. As the number of Services and endpoints grows, those
chains grow too and their update and debugging model becomes part of normal
operations.

Cilium attaches eBPF programs to the Linux datapath. With
`kubeProxyReplacement: true`, this lab uses Cilium for Service
load-balancing, policy enforcement, and flow visibility instead of using
kube-proxy's iptables rules. eBPF is not a blanket performance guarantee for
every workload; it is an architectural change that removes iptables as the
primary dependency for these networking functions.

### Encrypt traffic and enforce policy by workload identity

The lab enables Cilium WireGuard node encryption. Cilium establishes encrypted
tunnels between known nodes; remote pod traffic is VXLAN-encapsulated and then
encrypted while crossing the VPC network.

Cilium also supplies one place to enforce Kubernetes and Cilium network policy
using workload identities and labels. Through ClusterMesh, that model extends
to remote endpoints in shared namespaces.

WireGuard protects traffic in transit between nodes. It is not application
mTLS and does not replace application-level authentication or authorization.

### Connect clusters without a per-workload sidecar

With a traditional sidecar mesh, each workload pod gets a local proxy that
intercepts traffic and receives destination information from the mesh control
plane. This is powerful, but it adds a proxy lifecycle, CPU and memory use,
an upgrade surface, and a troubleshooting hop to every application pod.

For L3/L4 traffic, Cilium performs service selection and routing in the eBPF
datapath on each node. ClusterMesh synchronizes remote nodes, identities,
endpoints, and Service backends, so the local node can select a remote pod
using the same Service lookup that it uses for a local pod.

```text
client pod in cluster-1
  -> nginx.test-mesh.svc.cluster.local
  -> Cilium Service lookup in eBPF
  -> a cluster-2 nginx endpoint
  -> VXLAN + WireGuard between nodes
  -> destination pod
```

This does not mean every L7 service-mesh feature is free. Cilium can use
Envoy-based proxies for HTTP, gRPC, DNS, Gateway API, and ingress features
that require L7 parsing. The distinction is that ordinary pod-to-pod and
Service traffic does not require a sidecar in every application pod.

### The precise difference from Istio, App Mesh, and ECS Service Connect

The useful comparison is not simply “Cilium has no proxy.” Cilium has a
different **default datapath and control-plane distribution model** for
service-to-service traffic.

| Concern | Istio on EKS / AWS App Mesh | ECS Service Connect | Cilium ClusterMesh in this lab |
| --- | --- | --- | --- |
| Client traffic path | Traffic is intercepted and sent through an Envoy proxy associated with the workload. | The application connects to the Service Connect proxy sidecar in its own ECS task. | The application connects to a normal Kubernetes Service; Cilium's eBPF datapath performs L3/L4 lookup and backend selection on the node. |
| Where a client chooses a backend | The Envoy proxy receives endpoint/configuration updates from the mesh control plane and chooses a backend. | The local Service Connect proxy uses ECS/Cloud Map service configuration and selects a task, normally round-robin. | Cilium programs Service and endpoint state into eBPF maps on the node; the datapath selects a local or remote pod backend. |
| Per-workload proxy | Usually yes for sidecar mode. Istio also has Ambient mode, which changes that deployment model. | Yes: ECS adds the managed proxy container to every participating task. | No for ordinary L3/L4 pod-to-pod traffic. Cilium agents run per node, not beside every application container. |
| Cross-cluster state | A mesh control plane distributes configuration to the participating proxies. | Service Connect can connect services across VPCs, but each participating task still has its proxy. | KVStoreMesh synchronizes remote nodes, identities, and endpoints to each cluster's local ClusterMesh state; Cilium agents consume that state. |
| Application-layer features | Strong L7 traffic management, retries, timeouts, circuit breaking, request routing, and workload mTLS are core proxy capabilities. | Managed service discovery, retries, metrics, and proxy-based traffic routing. | This lab provides L3/L4 load-balancing, policy, node-to-node WireGuard, and multi-cluster discovery. L7 features require explicitly using Cilium's Envoy-based capabilities. |
| Workload mTLS | Commonly implemented as mutual TLS between workload proxies. | Available through Service Connect's proxy features where configured. | Not enabled by this lab. WireGuard encrypts node-to-node transport; ClusterMesh etcd uses its own mTLS. |

So your statement is fundamentally right: in Istio sidecar mode, App Mesh, and
ECS Service Connect, a client-local proxy receives destination information and
participates in round-robin/routing decisions. In this Cilium design, that
L3/L4 decision is made by eBPF on the node from Cilium's locally synchronized
Service and endpoint maps. The application pod does not carry a proxy.

The trade-off is equally important: Cilium ClusterMesh alone is **not** a
drop-in replacement for all application-level Istio or Service Connect
features. Use it when the goal is efficient, sidecarless network connectivity,
security enforcement, and cross-cluster service discovery. Add Cilium's L7
features or another dedicated solution when you need request-aware retries,
weighted traffic shifting, application mTLS, or other L7 mesh behavior.

AWS App Mesh is included here as an architectural comparison to an Envoy
sidecar mesh. AWS has announced that App Mesh support ends on September 30,
2026; new ECS designs should evaluate Service Connect or another supported
mesh approach instead.

### Consolidate the network datapath

Cilium can provide the CNI, kube-proxy replacement, NetworkPolicy,
encryption, Service load-balancing, Hubble observability, Gateway API, and
multi-cluster connectivity. The goal is not to enable every feature by
default, but to avoid maintaining several overlapping datapaths for this lab.

## What the lab creates

| Area | Resources and responsibility |
| --- | --- |
| Clusters | Two EKS clusters, `cluster-1` and `cluster-2`, each in its own VPC |
| Pod network | Cilium cluster-pool IPAM, VXLAN, kube-proxy replacement, WireGuard, Hubble, and Gateway API |
| Underlay | VPC peering, routes, and node security-group rules for VXLAN, WireGuard, health checks, and ClusterMesh |
| Mesh control plane | A `clustermesh-apiserver` in each cluster and an internal instance-mode NLB on TCP/2379 |
| TLS and discovery | A shared lab CA and a Route53 private zone, `mesh.cilium.io`, associated with both VPCs |
| AWS integration | AWS Load Balancer Controller, EBS CSI, and Karpenter through EKS Blueprints |
| Demo | A global `nginx` Service and `mesh-client` pod in the `test-mesh` namespace |

The root Terraform module owns shared infrastructure: the lab CA, VPC
peering, routes, and private hosted zone. Both clusters are instances of the
reusable [`terraform/cluster`](terraform/cluster) module.

## How ClusterMesh works here

ClusterMesh has two separate traffic paths. Keeping them distinct is crucial.

### Control plane: synchronize remote cluster state

Before the mesh exists, one cluster cannot rely on the other cluster's pod
network. Each cluster exposes `clustermesh-apiserver` behind an internal NLB
that is reachable over the already-peered VPC node network.

```text
KVStoreMesh in cluster-1
  -> resolve cluster-2.mesh.cilium.io
  -> cluster-2 internal NLB, TCP/2379
  -> NodePort and Kubernetes Service
  -> cluster-2 clustermesh-apiserver / etcd
```

The NLB is TCP pass-through. Cilium's API server ends mutual TLS; the NLB does
not terminate it.

Private DNS is required because Cilium's serving certificate covers
`*.mesh.cilium.io`, while an AWS-generated `*.elb.amazonaws.com` NLB hostname
is not a certificate SAN. Route53 CNAME records provide stable,
certificate-valid peer names even when an NLB is recreated.

The NLB target group disables source-IP preservation. Otherwise, an initial
connection could try to return through a remote overlay path before the
reverse ClusterMesh state exists.

### Data plane: send application traffic between nodes

After KVStoreMesh synchronizes remote endpoint and identity information,
Cilium programs each node's eBPF maps. Application packets do not traverse the
NLB:

```text
client pod -> local node eBPF -> VXLAN -> WireGuard -> remote node eBPF -> nginx pod
```

The NLB exists only for ClusterMesh state synchronization, not application
load-balancing.

## Deploy

### Prerequisites

- Terraform 1.0 or later
- AWS CLI authenticated to the target AWS account
- AWS permissions for EKS, EC2/VPC, IAM, Route53, and EKS add-on resources
- `kubectl` for the optional post-deployment verification

The current Terraform provisions both clusters in **one AWS account**.
ClusterMesh can span accounts, but that requires separate AWS provider
credentials, requester/accepter VPC peering, routes in both accounts, and an
authorized cross-account association to the Route53 private zone.

### Apply everything

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Terraform creates the underlay, installs Cilium and its dependencies, creates
the ClusterMesh API Services, waits for the NLB hostnames, and creates the
private Route53 records. No separate bootstrap apply, manual NLB edit, Helm
post-renderer, or `kubectl patch` is required.

## Verify cross-cluster Service connectivity

Configure local contexts after the apply:

```sh
aws eks update-kubeconfig --region ap-south-1 --name cluster-1 --alias cluster-1
aws eks update-kubeconfig --region ap-south-1 --name cluster-2 --alias cluster-2
```

Both clusters define a Service named `nginx` in the global `test-mesh`
namespace. The Service is annotated as global, so Cilium shares backends
across clusters. It also uses `service.cilium.io/affinity: remote`; in this
two-cluster lab, `remote` means the peer cluster.

```sh
kubectl --context cluster-1 -n test-mesh exec mesh-client -- \
  curl -s http://nginx.test-mesh.svc.cluster.local
# served-by=cluster-2

kubectl --context cluster-2 -n test-mesh exec mesh-client -- \
  curl -s http://nginx.test-mesh.svc.cluster.local
# served-by=cluster-1
```

Verify that the ClusterMesh control plane has converged:

```sh
kubectl --context cluster-1 -n kube-system exec ds/cilium -- \
  cilium-dbg clustermesh status --wait
```

## Production considerations

- This lab stores the shared ClusterMesh CA private key in Terraform state.
  Use an organization-controlled CA or AWS Private CA with cert-manager for
  production, and share trust roots rather than server or client private keys.
- Keep node, pod, and service ranges unique across all connected clusters.
- `remote` affinity is a two-cluster demonstration. Design locality, failure,
  and traffic-steering behavior deliberately in a larger topology.
- Review encryption mode, NetworkPolicies, IAM boundaries, observability, and
  availability requirements before using this repository as a template.

## Teardown

```sh
terraform -chdir=terraform destroy
```

## References

- [Cilium ClusterMesh overview](https://docs.cilium.io/en/stable/network/clustermesh/intro/)
- [Cilium ClusterMesh setup](https://docs.cilium.io/en/stable/network/clustermesh/setup/)
- [Cilium Global Services](https://docs.cilium.io/en/stable/network/clustermesh/global-services/)
- [Cilium transparent WireGuard encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
- [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/)
- [Amazon ECS Service Connect components](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-connect-concepts-deploy.html)
- [AWS App Mesh end-of-support notice](https://docs.aws.amazon.com/app-mesh/latest/userguide/doc-history.html)
- [Significant troubleshooting record](docs/TROUBLESHOOTING-LOG.md)

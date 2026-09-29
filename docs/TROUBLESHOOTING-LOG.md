# Significant ClusterMesh Troubleshooting Record

This is a curated record of investigations that materially changed the design
of this lab. Routine Terraform syntax mistakes, transient command failures,
and superseded bootstrap workarounds are intentionally omitted.

## 1. Cilium could not reach the Kubernetes API during bootstrap

**Symptom:** Cilium reported `dial tcp 172.20.0.1:443: i/o timeout`.

**Cause:** `172.20.0.1` is the in-cluster `kubernetes` Service IP. Cilium is
the CNI, so pod networking is not available until Cilium itself is running.
With kube-proxy replacement enabled, the agent must contact the real EKS API
endpoint instead.

**Resolution:** Configure `k8sServiceHost` from `module.eks.cluster_endpoint`
and set `k8sServicePort` to `443` in the Cilium Helm release.

## 2. Cilium and CoreDNS could not schedule during bootstrap

**Symptom:** Pods remained Pending with untolerated `not-ready` taints and
node-affinity/selector failures.

**Cause:** A `nodeSelector` limited the Cilium DaemonSet to one node group,
even though the CNI must run on every node. New nodes also carry the
`node.kubernetes.io/not-ready` taint before a CNI is available.

**Resolution:** Remove the Cilium node selector and retain a broad toleration
in the shared Cilium values. Managed node groups label system and Cilium
workloads separately without restricting the DaemonSet.

## 3. AWS Load Balancer Controller depended on IMDS for VPC discovery

**Symptom:** The controller timed out while reading EC2 instance metadata to
discover its VPC.

**Cause:** During CNI bootstrap, the controller pod cannot reliably reach
IMDS. Relying on automatic VPC discovery also made the installation less
deterministic.

**Resolution:** Pass `vpcId = module.vpc.vpc_id` explicitly to the EKS
Blueprints AWS Load Balancer Controller add-on.

## 4. ClusterMesh API server mounted a ConfigMap the chart did not create

**Symptom:** `clustermesh-apiserver` failed with
`configmap "clustermesh-remote-users" not found`.

**Cause:** In Cilium 1.20, the API server Deployment mounts the remote-users
ConfigMap when TLS authentication mode is not legacy, while the chart renders
that ConfigMap only when `clustermesh.config.enabled` is true.

**Resolution:** Keep `clustermesh.config.enabled: true` in the shared Cilium
values for both clusters, even before remote entries have synchronized.

## 5. No controller owned the ClusterMesh LoadBalancer Service

**Symptom:** `clustermesh-apiserver` remained at `EXTERNAL-IP <pending>` and
no NLB was created.

**Cause:** The in-tree EKS service controller was excluded by the NLB
annotations, but the AWS Load Balancer Controller did not claim the Service
without `spec.loadBalancerClass: service.k8s.aws/nlb`.

**Resolution:** Terraform owns the externally-created Cilium API server
Service. It sets `load_balancer_class = "service.k8s.aws/nlb"`, uses an
internal instance-mode NLB, and waits for the assigned hostname before
creating the Route53 record.

## 6. The EKS control plane could not call AWS Load Balancer Controller webhooks

**Symptom:** TargetGroupBinding reconciliation failed with
`Address is not allowed` when kube-apiserver called the controller webhook.

**Cause:** The EKS control plane is outside the cluster overlay. In Cilium
cluster-pool VXLAN mode, Service ClusterIPs are not VPC-routable, so the
control plane cannot reach webhook Service addresses.

**Resolution:** Disable the controller's Service mutator webhook and manage
the two TargetGroupBinding webhook configurations with Terraform, setting
their `failurePolicy` to `Ignore`. The AWS Load Balancer Controller add-on is
still installed by EKS Blueprints; no shell post-renderer or manual
`kubectl patch` is required.

## 7. Two cluster-tagged security groups on node ENIs blocked target registration

**Symptom:** AWS Load Balancer Controller reported `expected exactly one
securityGroup tagged with kubernetes.io/cluster/...` and registered no NLB
targets.

**Cause:** The EKS primary security group and a module-managed node security
group both had the EKS ownership tag. The controller cannot select a unique
cluster security group on the node ENI.

**Resolution:** The EKS module no longer creates a node security group. The
configuration creates a separate, untagged node security group with
`terraform-aws-modules/security-group/aws`; the EKS primary security group is
the only discovery-tagged group attached to nodes.

## 8. ClusterMesh TLS failed because the NLB hostname was not a certificate SAN

**Symptom:** KVStoreMesh watchers stalled, etcd logged `tls: bad certificate`,
and reconnects fell into a long retry loop. `openssl -verify_hostname` against
the NLB hostname returned verification error 62.

**Cause:** Cilium's serving certificate covered
`clustermesh-apiserver.cilium.svc`, `*.mesh.cilium.io`, and localhost. The
AWS-generated `*.elb.amazonaws.com` hostname used by the peer was not covered.

**Resolution:** Create the Route53 private zone `mesh.cilium.io`, associate it
with both VPCs, and CNAME `cluster-1.mesh.cilium.io` and
`cluster-2.mesh.cilium.io` to the corresponding NLBs. ClusterMesh peers use
these certificate-valid names rather than AWS NLB hostnames.

## 9. Instance-mode NLB preserved a source IP whose reverse path was not ready

**Symptom:** The cluster-2 NLB had healthy targets and passed health checks,
but real ClusterMesh client connections sent SYNs without receiving replies.

**Cause:** With instance targets, NLB source-IP preservation caused the target
to reply to the original peer-cluster client IP. Before reverse ClusterMesh
state existed, Cilium sent that reply into the overlay instead of back through
the NLB path.

**Resolution:** Set the target-group attribute
`preserve_client_ip.enabled=false` on both ClusterMesh API server Services.
The NLB no longer requires the initial return flow to traverse an already
established mesh.

## Current design checks

- Node-to-node security group rules allow VXLAN (`8472/udp`), WireGuard
  (`51871/udp`), ClusterMesh API traffic (`2379/tcp`), and Cilium health
  probes (`4240`) between VPC CIDRs.
- The ClusterMesh NLB is TCP pass-through; Cilium etcd performs mutual TLS.
- The root Terraform module owns the shared CA, peering, routes, and private
  DNS. It deploys two instances of the shared `terraform/cluster` module.
- The `nginx` global Service demo uses remote affinity and replies with the
  serving cluster name, making cross-cluster traffic observable.

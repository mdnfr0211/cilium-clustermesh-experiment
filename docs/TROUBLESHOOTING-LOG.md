# Troubleshooting Log — EKS + Cilium ClusterMesh Build

Running log of problems hit while building cluster-1/cluster-2 + clustermesh.
Each entry: symptom → root cause → fix. Newest at bottom.

---

## 1. Helm provider: `set` block syntax rejected

**Symptom**
```
Error: Unsupported block type ... Blocks of type "set" are not expected here.
Did you mean to define argument "set"?
```

**Cause:** Helm provider v3 (`~> 3.0`) removed repeatable `set { ... }` blocks.
`set` is now a list-of-maps attribute.

**Fix**
```hcl
set = [
  { name = "cluster.id", value = 1 },
]
```

---

## 2. `nodeSelector` as jsonencode → "got array, want object"

**Symptom**
```
values don't meet the specifications of the schema(s): cilium:
- at '/nodeSelector': got array, want object
```

**Cause:** `value = jsonencode({workload = "cilium"})` passes a JSON string;
helm `--set` cannot parse JSON (that's `--set-json`, which the provider
doesn't map to `set`).

**Fix:** dot notation instead:
```hcl
{ name = "nodeSelector.workload", value = "cilium" }
```

---

## 3. Helm provider v3: `values` expects content, not file paths

**Symptom**
```
error unmarshaling JSON: ... cannot unmarshal string into Go value of type
map[string]interface {} fixtures/cilium-values.yaml
```

**Cause:** Provider v3 reads `values` entries as raw YAML strings. A bare
path string is treated as YAML content (which is just a scalar → unmarshal
error).

**Fix**
```hcl
values = [file("fixtures/cilium-values.yaml")]
```

---

## 4. Providers referencing `module.eks` → k8s resources skipped on first apply

**Symptom:** `terraform apply` creates `module.eks_managed_node_group`
(AWS-only) but not `helm_release` / k8s resources; no obvious error.

**Cause:** `kubernetes` / `helm` / `kubectl` provider blocks read
`module.eks.cluster_endpoint` etc. Providers are configured at plan time;
on first apply those outputs are unknown → provider-backed resources are
deferred/dropped.

**Fix:** two-phase bootstrap per fresh stack:
```bash
terraform apply -target=module.vpc
terraform apply -target=module.eks
terraform apply
```
Only needed on the first apply of a stack; later applies have outputs in state.

---

## 5. Cilium agent: `dial tcp 172.20.0.1:443: i/o timeout`

**Symptom**
```
Unable to contact k8s api-server ipAddr=https://172.20.0.1:443
```

**Cause:** `172.20.0.1` is the `kubernetes` ClusterIP. Cilium IS the CNI —
pod networking doesn't exist before Cilium runs (chicken-and-egg). With
`kubeProxyReplacement: true`, Cilium must reach the real EKS API endpoint.

**Fix**
```hcl
{ name = "k8sServiceHost", value = replace(module.eks.cluster_endpoint, "https://", "") }
{ name = "k8sServicePort", value = 443 }
```
Note: after changing helm values, existing pods keep old env — restart:
`kubectl rollout restart daemonset/cilium -n cilium`.

---

## 6. Cilium pods: `untolerated taint(s)` + `node affinity/selector` FailedScheduling

**Symptom:** `0/N nodes are available: ... untolerated taint(s)`,
`didn't match Pod's node affinity/selector` (seen on CoreDNS too — cascades
from no CNI).

**Cause:** Two stack-ups:
1. `nodeSelector.workload=cilium` pinned the daemonset to one node group —
   a CNI daemonset must run on ALL nodes.
2. Nodes carry the `node.kubernetes.io/not-ready` taint until a CNI is up;
   Cilium needs to tolerate it to bootstrap itself.

**Fix:** removed the nodeSelector override; values file:
```yaml
tolerations:
  - operator: Exists
```

---

## 7. AWS Load Balancer Controller: IMDS timeout getting VPC ID

**Symptom**
```
failed to get VPC ID: ... ec2imds: GetMetadata, canceled, context deadline exceeded
```

**Cause:** Controller falls back to instance metadata (169.254.169.254) for
VPC discovery; fails while pod networking is down (no CNI yet), and can stay
flaky otherwise.

**Fix:** pass VPC explicitly, bypassing IMDS:
```hcl
{ name = "vpcId", value = module.vpc.vpc_id }
```

---

## 8. EKS module: wrong argument name for service CIDR

**Symptom**
```
An argument named "cluster_service_ipv4_cidr" is not expected here.
```

**Cause:** terraform-aws-modules/eks `~> 21.0` argument is
`service_ipv4_cidr` (maps to `kubernetesNetworkConfig.serviceIpv4Cidr`).

**Fix**
```hcl
module "eks" {
  service_ipv4_cidr = "172.21.0.0/16"   # cluster-2; must not overlap cluster-1
}
```
Gotcha: clustermesh breaks if service CIDRs overlap. cluster-1 is EKS-default
(172.20.0.0/16) and is NOT changed — setting it on an existing cluster forces
EKS replacement.

---

## 9. Conditional locals: `Inconsistent conditional result types`

**Symptom**
```
The false result value has the wrong type: map has no element for required
attribute "cilium_health_self"
```
(even with `: tomap({})`)

**Cause:** Terraform eagerly unifies both branches of `? :` into one type.
An object with keys vs an empty map cannot unify.

**Fix:** uniform rule defs + `for`-expression with `if` filter — result type
identical regardless of flag:
```hcl
mesh_sg_rules = {
  for name, r in local.mesh_sg_rule_defs :
  name => {
    description = r.description
    protocol    = r.protocol
    from_port   = r.from_port
    to_port     = r.to_port
    type        = "ingress"
    cidr_blocks = r.self ? null : [r.cidr]
    self        = r.self ? true : null
  }
  if var.mesh_enabled || name == "cilium_health_self"
}
```
`null` = attribute omitted (avoids invalid empty-cidr AWS rules).
Peer-CIDR lookups from remote state wrapped in `try(..., "")` so phase-1
(state not populated) still evaluates.

---

## 10. kubernetes_service data source: status schema

**Symptom**
```
Can't access attributes on a list of objects. Did you mean to access
attribute "ingress" ...?
```

**Cause:** `data.kubernetes_service...status[0].load_balancer` is itself a
list.

**Fix**
```hcl
try(data.kubernetes_service.clustermesh_apiserver.status[0].load_balancer[0].ingress[0].hostname, "")
```

---

## 11. clustermesh-apiserver: `configmap "clustermesh-remote-users" not found`

**Symptom**
```
MountVolume.SetUp failed for volume "etcd-users-config" :
configmap "clustermesh-remote-users" not found
```

**Cause:** Cilium 1.20 chart inconsistency:
- Deployment mounts `etcd-users-config` whenever
  `clustermesh.apiserver.tls.authMode != "legacy"` (default `migration`
  → mount ALWAYS present).
- The ConfigMap is only rendered when `clustermesh.config.enabled: true`.

With `useAPIServer: true` + `config.enabled: false` the pod mounts a
ConfigMap the chart never creates. Verified via
`helm template ... --set clustermesh.config.enabled=false` (mount present,
cm absent).

**Fix:** `clustermesh.config.enabled: true` in fixtures for BOTH stacks.
Empty cluster list renders a valid empty `users:` list; phase-3/4 upgrades
populate remote entries. (Map-style `config.clusters.cluster-N.address` is
supported — `kindIs "map"` branch in the chart's `_helpers.tpl`.)

---

## 12. terraform apply hangs on helm_release; helm shows `pending-upgrade`

**Symptom**
```
terraform apply: "helm_release.cilium: Modifying..." (hangs)
helm history:  revision N  pending-upgrade  "Preparing upgrade"
```
Also seen before it: `Upgrade "cilium" failed: context deadline exceeded`.

**Cause:** Phase-1 upgrade added the `clustermesh-apiserver` Service
(`type: LoadBalancer` → internal NLB). Helm `wait=true` (provider default)
blocks the upgrade until the NLB gets an EXTERNAL-IP — AWS takes minutes.
Provider default `timeout` is 300s → upgrade killed mid-wait → release stuck
in `pending-upgrade`. Next apply hangs behind the stuck release.

**Fix (recovery)**
```bash
kill -9 <terraform-pid> <helm-provider-pid>
helm rollback cilium <last-deployed-rev> -n cilium --wait --timeout 8m
```

**Fix (root cause)** — on `helm_release`:
```hcl
timeout = 900   # NLB provisioning > provider's 300s default
```

---

## 13. NLB never created — LoadBalancer Service with nobody handling it

**Symptom:** `service/clustermesh-apiserver` EXTERNAL-IP `<pending>` forever;
no NLB in AWS; `aws-load-balancer-controller` logs show zero reconciles of it.

**Cause:** annotation `aws-load-balancer-type: external` makes the EKS
in-tree service controller SKIP the Service, but the LB controller only
claims Services with `spec.loadBalancerClass: service.k8s.aws/nlb`.
No `loadBalancerClass` was set → nobody owned the Service.

**Fix** (cilium values, clustermesh.apiserver.service):
```yaml
loadBalancerClass: service.k8s.aws/nlb
annotations:
  service.beta.kubernetes.io/aws-load-balancer-scheme: internal
  # cluster-pool pod IPs are overlay (not ENIs) -> NLB must target nodes
  service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
```
NOTE `target-type: instance`, not `ip` — pod IPs are overlay, unreachable
by the NLB otherwise.

---

## 14. apiserver → webhook: `Address is not allowed` (EKS + Cilium overlay)

**Symptom**
```
FailedDeployModel: failed calling webhook "mtargetgroupbinding.elbv2.k8s.aws":
Post "https://aws-load-balancer-webhook-service.kube-system.svc:443/...":
Address is not allowed
```
(from the service / TGB reconcile, not from any pod)

**Cause:** Admission webhooks are called by **kube-apiserver** (EKS control
plane, outside the cluster network). With Cilium overlay (cluster-pool +
VXLAN) ClusterIPs are not VPC-routable and the control-plane egress path
(`AWS_MANAGED` mode) rejects non-VPC-routable destinations. Known EKS+Cilium
overlay issue (kubernetes-sigs/aws-load-balancer-controller #2711/#1591,
cilium #30111, otel-operator #2260). Evidence: pods CAN reach the webhook
VIP fine; `cilium monitor --type=drop` shows zero drops (packets never reach
a node); no VPC route for the service CIDR.

**Fix:** the Terraform-managed Helm release applies a checked-in post-renderer
(`scripts/albc-webhook-postrender.sh`). It changes only
`mtargetgroupbinding.elbv2.k8s.aws` and
`vtargetgroupbinding.elbv2.k8s.aws` to `failurePolicy: Ignore` in the rendered
chart. The controller builds complete TGB specs; the mutations are defaulting
only. Because this happens before Helm applies a release, it survives every
Terraform-driven controller install and upgrade without a manual `kubectl
patch`.

If a TGB was already backed off before the controller became usable, a one-off
service annotation can still nudge reconciliation; it is not a normal apply
step.

**Long-term alternatives:** Cilium ENI mode (pods VPC-routable) or
hostNetwork for webhook-serving components — bigger architectural changes,
not taken.

---

## 15. TGB: `expected exactly one securityGroup tagged with kubernetes.io/cluster/...`

**Symptom**
```
FailedReconcile ... expected exactly one securityGroup tagged with
kubernetes.io/cluster/cluster-1 for eni eni-xxx, got:
[sg-06ad... sg-0e2c...]
```
Target group has ZERO targets.

**Cause:** terraform-aws-modules/eks `~> 21.0` HARDCODES
`kubernetes.io/cluster/<name> = owned` on the node SG (node_groups.tf:193),
while EKS also tags the cluster primary SG (attached to node ENIs) the same
way. Two tagged SGs per node ENI → LB controller's SG lookup fails.

**Fix:**
1. Remove the tag from the node SG:
   `aws ec2 delete-tags --resources <node-sg-id> --tags Key=kubernetes.io/cluster/cluster-1`
2. Prevent terraform from re-adding it (module hardcodes it; merge can't
   remove keys) — provider-level ignore in `provider.tf`:
   ```hcl
   provider "aws" {
     ignore_tags {
       keys = ["kubernetes.io/cluster/${var.cluster_name}"]
     }
   }
   ```
   (cluster SG keeps its tag — AWS-managed, unaffected by TF)

After both: TGB `Successfully reconciled`, both nodes `healthy` in the TG.

---

## 16. kubernetes provider: data source reads hang forever

**Symptom:** `terraform apply` stuck at
`data.kubernetes_service.clustermesh_apiserver: Still reading... [05m+]`
(kubectl CLI against the same API responds in <1s; helm provider works
fine in the same run). Same hang class seen in state refresh of
kubernetes/kubectl resources.

**Cause:** hashicorp/kubernetes 2.38 data-source read hang (exec auth
plugin path). kubectl CLI via the same exec plugin is reliable.

**Current fix:** the one-click bootstrap script queries the Service with
`kubectl` only after its Cilium apply has completed and passes each NLB
hostname directly to the subsequent Terraform applies. No Kubernetes provider
data source, hostname file, second apply, or manual copy/paste is involved.

---

## 17. Stale terraform state lock after killed applies

**Symptom:** `terraform apply` waits forever acquiring lock (no error, no
progress); `terraform force-unlock <id>` refuses: "Local state cannot be
unlocked by another process".

**Cause:** kill -9 on terraform leaves `.terraform.tfstate.lock.info`
behind. Local state has no remote lock id — force-unlock doesn't apply.

**Fix:** `rm .terraform.tfstate.lock.info` in the stack directory.
Also `pkill -9 -f terraform-provider` — killed applies orphan their provider
plugin processes.

---

## Reference — current mesh design

| Stack | VPC | Pod CIDR | Service CIDR | Cluster ID |
|-------|-----|----------|--------------|------------|
| cluster-1 | 10.0.0.0/16 | 10.2.0.0/16 | 172.20.0.0/16 (EKS default) | 1 |
| cluster-2 | 10.1.0.0/16 | 10.3.0.0/16 | 172.21.0.0/16 (set at creation) | 2 |

- Shared CA (`mesh-ca` stack) → Helm-managed `cilium-ca` secret in the `cilium` namespace on both clusters
- clustermesh-apiserver: internal NLB per cluster, mesh traffic via VPC peering
- SG on node SGs: 8472/udp VXLAN, 51871/udp WireGuard, 2379/tcp mesh apiserver
- Demo: `nginx.test-mesh` global ClusterIP service both clusters — endpoint
  merging, no MCSAPI/ServiceExport, zero LoadBalancers in app path
- Runbook: `CLUSTERMESH-APPLY.md`

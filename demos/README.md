# Cilium feature demos

These examples run on the two EKS clusters created by the root Terraform
configuration. They use the existing `test-mesh` namespace and `mesh-client`
pod, so deploy the lab first. Apply each file only to the cluster shown below;
the Cilium policy objects are local to the cluster where they are created.
The demos do not modify Terraform's `nginx` Deployment or Service.

| Demo | Apply to | What it shows |
| --- | --- | --- |
| [01](01-network-policies.yaml) | cluster-2 | Allow a pod in cluster-1 by identity and source cluster |
| [02](02-l7-http-policies.yaml) | cluster-2 | Allow only one HTTP method and path across clusters |
| [03](03-fqdn-policies.yaml) | cluster-1 | Restrict one pod's internet egress by DNS name |
| [04](04-aws-internal-nlb.yaml) | cluster-1 | Expose a local Service through an AWS internal NLB |
| [05](05-ingress-controller.yaml) + [remote Service](05-ingress-remote-cluster-2.yaml) | both | Route HTTP by host to a local or cluster-2 backend |
| [06](06-bandwidth-limiting.yaml) | cluster-1 | Compare pod egress with and without a bandwidth limit |
| [07](07-global-service-cluster-1.yaml) + [07](07-global-service-cluster-2.yaml) | both | Share Service backends and change local/remote affinity |

## Before starting

Run `terraform -chdir=terraform apply` from the repository root, then
configure the two contexts:

```sh
aws eks update-kubeconfig --region ap-south-1 --name cluster-1 --alias cluster-1
aws eks update-kubeconfig --region ap-south-1 --name cluster-2 --alias cluster-2
kubectl --context cluster-1 -n cilium exec ds/cilium -- cilium-dbg clustermesh status --wait
kubectl --context cluster-2 -n cilium exec ds/cilium -- cilium-dbg clustermesh status --wait
```

Check that `test-mesh` and `mesh-client` exist in both clusters:

```sh
kubectl --context cluster-1 -n test-mesh get pod mesh-client
kubectl --context cluster-2 -n test-mesh get pod mesh-client
```

The namespace is marked global by Terraform, allowing its pod identities
and endpoints to be exchanged by ClusterMesh. These demos can create AWS
load balancers: 04 creates an NLB, and 05 creates another NLB through
Cilium Ingress. Delete them when finished to stop those resources.
The custom node security group permits the Kubernetes NodePort range from
its own VPC so these instance-target NLBs can reach their backends.
After applying a cross-cluster manifest, allow a few seconds for endpoint
state to reach the peer before judging a first failed request.

## 01 — Cross-cluster network policy

Apply the server and policy to **cluster-2**:

```sh
kubectl --context cluster-2 apply -f demos/01-network-policies.yaml
kubectl --context cluster-2 -n test-mesh rollout status deployment/policy-server
POLICY_IP=$(kubectl --context cluster-2 -n test-mesh get pod -l app=policy-server -o jsonpath='{.items[0].status.podIP}')
```

Connect directly to that pod IP from the `mesh-client` in each cluster:

```sh
kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS --max-time 5 "http://$POLICY_IP"
# policy-server=cluster-2

kubectl --context cluster-2 -n test-mesh exec mesh-client -- curl -v --max-time 5 "http://$POLICY_IP"
# Expected: timeout / policy drop
```

The destination policy permits `app=mesh-client` **from cluster-1** on
TCP/80. A client with the same app label in cluster-2 is denied. This
demonstrates that the source cluster can be part of Cilium's policy
decision. Test the **pod IP**, because this Service is local to cluster-2;
it is not annotated as a global Service.

## 02 — HTTP method and path policy

Apply to **cluster-2**:

```sh
kubectl --context cluster-2 apply -f demos/02-l7-http-policies.yaml
kubectl --context cluster-2 -n test-mesh rollout status deployment/http-api
API_IP=$(kubectl --context cluster-2 -n test-mesh get pod -l app=http-api -o jsonpath='{.items[0].status.podIP}')

kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS -i --max-time 5 "http://$API_IP/health"
# HTTP 200 and "healthy"

kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS -i --max-time 5 -X POST "http://$API_IP/health"
# HTTP 403 from the Cilium L7 proxy

kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS -i --max-time 5 "http://$API_IP/"
# HTTP 403
```

Cilium's Envoy proxy inspects HTTP only because this policy contains L7
rules. Normal ClusterMesh pod traffic does not require an Envoy hop.

## 03 — DNS-aware internet egress

Apply to **cluster-1**:

```sh
kubectl --context cluster-1 apply -f demos/03-fqdn-policies.yaml
kubectl --context cluster-1 -n test-mesh wait --for=condition=Ready pod/fqdn-client --timeout=120s

kubectl --context cluster-1 -n test-mesh exec fqdn-client -- curl -I --max-time 10 https://api.github.com
# HTTP response received

kubectl --context cluster-1 -n test-mesh exec fqdn-client -- curl -v --max-time 5 https://example.com
# Expected: DNS denial or connection failure
```

This policy affects only `fqdn-client`. Its allowed DNS response is used to
authorize HTTPS egress to `api.github.com`. It does not affect the
ClusterMesh private DNS name or the `mesh-client` pod.

## 04 — AWS internal NLB

Apply to **cluster-1**:

```sh
kubectl --context cluster-1 apply -f demos/04-aws-internal-nlb.yaml
kubectl --context cluster-1 -n test-mesh rollout status deployment/nlb-web
kubectl --context cluster-1 -n test-mesh get svc nlb-web -w
```

Once `EXTERNAL-IP` shows a hostname, stop the watch and test from inside
cluster-1:

```sh
NLB_HOST=$(kubectl --context cluster-1 -n test-mesh get svc nlb-web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS "http://$NLB_HOST"
# nlb-web=cluster-1 pod=...
```

The original file was called an L2 load-balancer demo, but it defined no
Cilium L2 announcement policy or address pool. This version uses the AWS
Load Balancer Controller already installed by Terraform. The NLB is
**internal** and fronts a local Service. It is separate from the NLB used
by ClusterMesh on TCP/2379.

## 05 — Cilium Ingress: local and remote backends

Terraform enables the Cilium Ingress controller. First create a second
global Service in **cluster-2** that selects its existing `nginx` pods.
Then create the same Service name in **cluster-1**, with no local pods, and
the Ingress that routes to it:

```sh
kubectl --context cluster-2 apply -f demos/05-ingress-remote-cluster-2.yaml
kubectl --context cluster-1 apply -f demos/05-ingress-controller.yaml
kubectl --context cluster-1 -n test-mesh rollout status deployment/ingress-local
kubectl --context cluster-1 -n test-mesh get ingress demo
kubectl --context cluster-1 -n test-mesh get svc cilium-ingress-demo -w
```

After the generated Service receives an NLB hostname, stop the watch:

```sh
INGRESS_HOST=$(kubectl --context cluster-1 -n test-mesh get svc cilium-ingress-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS -H 'Host: local.demo.test' "http://$INGRESS_HOST/"
# ingress-backend=cluster-1

kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS -H 'Host: remote.demo.test' "http://$INGRESS_HOST/"
# served-by=cluster-2
```

The path for the second request is:

```text
client -> cluster-1 internal Ingress NLB -> Cilium Envoy Ingress
       -> ingress-remote global Service -> cluster-2 nginx pod
```

**Ingress is an HTTP entry point, not the link that forms ClusterMesh.**
ClusterMesh shares the endpoints of the `ingress-remote` Service. Because
cluster-1's copy has no local endpoints, its backend is necessarily a
cluster-2 pod. The existing Terraform-managed `nginx` Service and its
affinity remain untouched. Cilium's [Global Services documentation](https://docs.cilium.io/en/stable/network/clustermesh/global-services/)
confirms that Cilium Ingress can use global backends without Kubernetes
EndpointSlice synchronization.

`local.demo.test` and `remote.demo.test` are HTTP Host rules; the manifest
does **not** create DNS records. The commands send those Host headers
explicitly. The generated AWS NLB resolves to private VPC addresses, so
access requires a network route and security-group permission to its VPC.
Kubernetes Service DNS names such as `ingress-remote.test-mesh.svc.cluster.local`
are resolved by cluster DNS for workloads, not published by this Ingress.
With an internet-facing NLB and public DNS, this same kind of Ingress could
be externally reachable. Its reachability is a separate choice from
whether the backend is local or in another cluster.

## 06 — Bandwidth Manager over the mesh

Apply to **cluster-1** and fetch each pod's 8 MiB file from
`mesh-client` in **cluster-2**:

```sh
kubectl --context cluster-1 apply -f demos/06-bandwidth-limiting.yaml
kubectl --context cluster-1 -n test-mesh wait --for=condition=Ready pod -l app=bandwidth-web --timeout=120s
LIMITED_IP=$(kubectl --context cluster-1 -n test-mesh get pod bandwidth-limited -o jsonpath='{.status.podIP}')
UNLIMITED_IP=$(kubectl --context cluster-1 -n test-mesh get pod bandwidth-unlimited -o jsonpath='{.status.podIP}')

kubectl --context cluster-2 -n test-mesh exec mesh-client -- curl -sS -o /dev/null -w 'limited: %{time_total}s, %{speed_download} bytes/s\n' "http://$LIMITED_IP/large.bin"
kubectl --context cluster-2 -n test-mesh exec mesh-client -- curl -sS -o /dev/null -w 'baseline: %{time_total}s, %{speed_download} bytes/s\n' "http://$UNLIMITED_IP/large.bin"
```

The `10M` annotation limits **egress from the serving pod** to about
10 Mbit/s. Compare several runs; network load and cache effects mean the
measurements will vary. The cross-cluster client ensures traffic leaves the
serving node.

## 07 — Global Service and affinity

Apply the cluster-specific manifests to **both** clusters:

```sh
kubectl --context cluster-1 apply -f demos/07-global-service-cluster-1.yaml
kubectl --context cluster-2 apply -f demos/07-global-service-cluster-2.yaml
kubectl --context cluster-1 -n test-mesh rollout status deployment/global-echo
kubectl --context cluster-2 -n test-mesh rollout status deployment/global-echo

for i in $(seq 1 10); do
  kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS http://global-echo.test-mesh.svc.cluster.local
done
# With affinity=none, responses can come from both clusters.
```

Prefer remote backends in cluster-1, then test again:

```sh
kubectl --context cluster-1 -n test-mesh annotate service global-echo service.cilium.io/affinity=remote --overwrite
for i in $(seq 1 5); do
  kubectl --context cluster-1 -n test-mesh exec mesh-client -- curl -sS http://global-echo.test-mesh.svc.cluster.local
done
# served-by=cluster-2 while remote backends are healthy
```

Try `local` as well. Affinity is a **preference**: Cilium can fall back to
other healthy backends if the preferred set is unavailable. Each cluster
can set its own preference without changing the other cluster's Service.

## Observe the flows

Hubble is enabled in each cluster. Open its UI while running demos 01, 02,
or 07 to inspect forwarded and dropped flows:

```sh
kubectl --context cluster-1 -n cilium port-forward svc/hubble-ui 12000:80
```

Open `http://localhost:12000` in a browser. Repeat with
`--context cluster-2` and another local port to see the other cluster's
view. The UI and relay belong to each cluster; this is not a single
cross-cluster Hubble deployment.

## Clean up

Delete only the manifests that were applied. For all seven demos:

```sh
kubectl --context cluster-1 delete -f demos/07-global-service-cluster-1.yaml
kubectl --context cluster-2 delete -f demos/07-global-service-cluster-2.yaml
kubectl --context cluster-1 delete -f demos/06-bandwidth-limiting.yaml
kubectl --context cluster-1 delete -f demos/05-ingress-controller.yaml
kubectl --context cluster-2 delete -f demos/05-ingress-remote-cluster-2.yaml
kubectl --context cluster-1 delete -f demos/04-aws-internal-nlb.yaml
kubectl --context cluster-1 delete -f demos/03-fqdn-policies.yaml
kubectl --context cluster-2 delete -f demos/02-l7-http-policies.yaml
kubectl --context cluster-2 delete -f demos/01-network-policies.yaml
```

Deleting 04 and 05 also requests deletion of their AWS NLBs. The
Terraform-owned `test-mesh` namespace, `nginx` Service, and
`mesh-client` pod remain in place.

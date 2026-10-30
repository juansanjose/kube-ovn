# Proposal 0003 — Advertise other IP addresses (API VIP, Service VIPs, arbitrary prefixes)

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/bgp-advertise-other-ips` |
| Depends on | 0002 (iBGP/RR), 0004 (node subset) for HA |
| Lab status | Baseline BGP verified; `--announce-cluster-ip` path understood |

## 1. Motivation

The speaker announces pod IPs, subnet CIDRs, EIPs and — only with
`--announce-cluster-ip` — Service ClusterIPs whose Service carries
`ovn.kubernetes.io/bgp=true` (`pkg/speaker/subnet.go` in 1.16). Everything else
(API server VIP, OVN DB VIP, ingress addresses that are not Kube-OVN EIPs,
operator-chosen prefixes) has to be injected by another BGP tool outside
Kube-OVN. A routed fabric wants one owner of "what this cluster announces", and
Kube-OVN already owns the pod/subnet prefixes and the session.

## 2. Current state in master

* `pkg/speaker/eip.go` — announces `IptablesEIP` addresses.
* `pkg/speaker/subnet.go` — subnet CIDRs + per-pod `/32`s; **announcement is
  opt-in via the `ovn.kubernetes.io/bgp` annotation** (`true`/`cluster` = every
  speaker, `local` = only the hosting node). Verified in the lab: without the
  annotation the speaker announces nothing.
* `AnnounceClusterIP` — annotated ClusterIP Services only.
* No arbitrary prefix support, and no health gating (a dead API server keeps
  being advertised — anycast blackhole).

## 3. Goals

1. A declarative `BgpAdvertisement` for extra prefixes with an optional health
   gate.
2. Built-in sources: `apiServer` (derived from the `kubernetes` Service), a
   configured `controlPlaneVIP`, and `raw` CIDRs.
3. Health-gated announcement (announce only while a local probe succeeds) so
   two sites can anycast the same VIP with automatic failover.
4. Optional communities / local-preference / MED so the fabric can steer.

Non-goals: ARP-based L2 VIP announcement (MetalLB scope), DNS steering.

## 4. Design

### 4.1 API

```yaml
apiVersion: kubeovn.io/v1
kind: BgpAdvertisement
metadata: {name: api-vip}
spec:
  prefixes: ["10.255.0.10/32"]
  source: controlPlaneVIP        # raw | apiServer | controlPlaneVIP
  nodeSelector: {matchLabels: {kube-ovn/role: bgp-border}}
  healthCheck:
    type: httpsProbe             # none | httpsProbe | tcpProbe | httpGet | exec
    endpoint: https://127.0.0.1:6443/livez
    intervalSeconds: 3
    failureThreshold: 3
    successThreshold: 1
  attributes: {communities: ["65001:100"], localPreference: 200, med: 0}
```

### 4.2 Speaker changes

`pkg/speaker/advertisement.go`: informers for `BgpAdvertisement`, `Service`
(default ns), `EndpointSlice`; a prober goroutine per advertisement; results
merged into the existing `prefixMap` so `reconcileRoutes()` stays the single
code path (that path is what the lab exercised). Attributes → GoBGP path
attributes. `exec` probes behind `--allow-exec-probes` (default off).

Status: per-prefix `Advertised` condition + `lastProbeTime`; metric
`kube_ovn_bgp_advertisement_up{name,prefix}`.

### 4.3 Anycast semantics

Two sites announcing the same `/32` split traffic by fabric ECMP. Health gate +
higher LP/MED on the preferred site gives active/passive or active/active.
Document both recipes; do not hardcode a policy.

### 4.4 Failure modes

Probe flaps ⇒ hysteresis (`failureThreshold`/`successThreshold`) plus a 5s
minimum dwell. Speaker crash ⇒ session down ⇒ implicit withdraw (no stale
anycast). Node drain ⇒ advertisement moves with the DaemonSet pod; convergence
equals BGP hold time — document the BFD 3s/9s option.

## 5. Security

Only the speaker advertises (no pod can inject a prefix), but `exec` probes run
in the speaker container — gate and default off. `BgpAdvertisement` is
cluster-scoped: admin-only ClusterRole, not the namespaced role.

## 6. Test plan

* **Unit** — prefix merge (subnet ∪ EIP ∪ advertisement), hysteresis state
  machine, attribute rendering.
* **e2e** — create the advertisement for `10.255.0.10/32`, assert
  `show bgp ipv4 unicast 10.255.0.10/32` on the lab ToR with community
  `65001:100`; kill the probe endpoint and assert withdraw within
  `interval*failureThreshold + dwell`.
* **Dual stack** — same with `fd00:255::10/128`.
* **Lab** — two clusters sharing a VIP on the FRR ToR, fail one, verify
  failover < 6s.

## 7. Milestones

1. CRD + raw prefixes (no health).
2. Health-gated announcement + metrics/conditions.
3. `apiServer`/`controlPlaneVIP` sources + dual stack.
4. Attributes + anycast recipes.

## 8. Open questions

* Separate CRD vs `BgpConf.spec.advertise`? Multiple teams owning different VIPs
  argues for a separate object with RBAC.
* Does advertising the API VIP break the kube-proxy path for pods (asymmetric
  return)? Needs a `hostNetwork` lab test.
* Avoid double advertisement when 0004 restricts the advertiser set and the
  selected node is not Ready.

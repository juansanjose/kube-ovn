# Proposal 0004 — Advertise BGP from a subset of nodes

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/bgp-node-subset` |
| Depends on | 0002 (iBGP/RR) recommended |
| Lab status | **Measured**: 3 nodes ⇒ 3 sessions on the ToR, 9 prefixes each |

## 1. Motivation

The speaker is a DaemonSet on every node, so every node opens its own session to
the fabric neighbours. In the lab that is 3 sessions/3 nodes; a 200-node cluster
presents 200 sessions to a ToR pair, each carrying a slice of the pod space. ToRs
cap sessions and prefixes per peer, and fabric designers expect two designated
border nodes to own the cluster's routes — the way an RR/border-leaf pair owns a
DC's routes. Operators need "announce from *these* nodes only", without
blackholing when one of them dies.

## 2. Current state in master

* Speaker DaemonSet (`charts/kube-ovn-v2/templates/speaker/`) — one GoBGP per
  node; `--node-ips` lets a node advertise a next hop that is not its pod IP.
* `pkg/speaker/subnet.go` builds the expected prefix set per node
  (`collectPodExpectedPrefixes(..., nodeName, ...)`) for `local` policy, and
  cluster-wide for `cluster` policy — verified in the lab: with
  `ovn.kubernetes.io/bgp=true` every speaker announces the same 9 prefixes with
  its own next hop, producing 27 ECMP paths on the ToR.
* No selector, taint or label influences speaker behaviour; the chart exposes
  `bgpSpeaker.nodeSelector` but that only *schedules* the pod.

## 3. Goals

1. `BgpConf.spec.advertiserSelector` (or a dedicated node set) chooses which
   nodes peer with the fabric. Non-selected nodes keep running the speaker for
   local metrics but never establish fabric sessions.
2. Selected nodes can announce **remote** prefixes (pod on node B reachable via
   node B's underlay IP), via in-cluster iBGP reflection (preferred, 0002) or by
   interior route lookup (needs an IGP, 0005).
3. Failover: if a selected node dies its prefixes move within a documented
   budget; if no advertiser remains, withdraw rather than advertise a black hole.
4. Optional anycast next hop: all prefixes announced with one shared VIP so the
   fabric ECMPs to any selected node.

Non-goals: replacing the DaemonSet with a Deployment (separate decision);
per-tenant advertiser sets (future `BgpAdvertisement.nodeSelector`, 0003).

## 4. Design

### 4.1 API

```yaml
apiVersion: kubeovn.io/v1
kind: BgpConf
metadata: {name: default}
spec:
  localASN: 65001
  peerASN: 65100
  neighbours: ["192.168.1.113"]
  advertiserSelector: {matchLabels: {kube-ovn/role: bgp-border}}   # NEW
  advertiserMode: borderPair        # allNodes (default) | borderPair | single
  nextHopPolicy: nodeIP             # nodeIP | sharedVIP
```

Webhook: warn when `advertiserMode: borderPair` selects an odd number of nodes
or zero. Anti-affinity must stay explicit (labels), not magic.

### 4.2 Speaker changes

`--advertiser-selector`, `--advertiser-mode`, `--next-hop-policy`. Split prefix
collection into `collectLocalPrefixes(nodeName)` (today's behaviour) and
`collectClusterPrefixes()` (union across nodes, used when this node is an
advertiser). For remote prefixes:

* **with 0002** — in-cluster iBGP mesh among speakers; reflection delivers the
  remote prefix with the owner's next hop. No route lookup.
* **without 0002** — resolve pod IP → node underlay IP from `Node`/IPAM state and
  announce that next hop (`addRoute`/`getNextHopAttribute` already take an
  explicit next hop; the lab log shows the node IP being used verbatim).

Guardrail: refuse to install an advertisement whose owner node's underlay
address is not reachable from this advertiser (`ip route get` check every 30s).
A withdrawn route beats a black hole.

### 4.3 Failover

Detection via `Node` readiness + BFD/BGP state; the survivor re-collects the
cluster prefix set (already a union) and re-announces. Convergence = watch
latency + BGP update. With `nextHopPolicy: sharedVIP` the VIP must move between
advertisers (kube-vip or "advertise VIP/32 from the survivor") — trade ECMP
optimality for simplicity, documented.

### 4.4 Observability

`kube_ovn_bgp_advertiser{node}` gauge, `kube_ovn_bgp_prefixes_announced{node}`,
event on advertiser-set change, `kubectl-ko bgp advertisers`.

## 5. Test plan

* **Unit** — selector evaluation, prefix-union diffing, webhook warnings,
  next-hop policy table.
* **e2e (lab, 3 nodes)** — label only `kovn-w1` as `bgp-border`; assert the ToR
  shows one session and all 9 prefixes with `kovn-w1`'s next hop; then cordon
  the advertiser, assert prefixes move to the partner and are never advertised
  with an unreachable next hop (poll every 500ms).
* **Scale** — 100 fake nodes (kwok) to confirm the union set is computed without
  a full-mesh session storm.

## 6. Milestones

1. `advertiserSelector` gating (local prefixes only) — no routing change.
2. Cluster-wide prefix collection + next-hop override + reachability guard.
3. Failover + metrics/events.
4. `sharedVIP` next-hop policy (needs a kube-vip decision).

## 7. Risks / open questions

* Announcing remote prefixes duplicates OVN knowledge; stale prefixes after node
  removal — add a full resync comparison every 5 minutes.
* `advertiserMode` in `BgpConf` (one answer per cluster) vs per-neighbour (a
  fabric with two ToR pairs may want different answers)? Prefer
  `neighbours[].advertiserSelector` override.
* Single survivor ⇒ silent ECMP loss: emit a `Warning` event + alert.
* Consider a second DaemonSet scoped by `nodeSelector` instead of gating inside
  the process, to avoid an idle BGP stack on every node.

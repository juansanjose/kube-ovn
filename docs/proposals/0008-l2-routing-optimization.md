# Proposal 0008 — Optimize Layer 2 network routing

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/l2-routing-optimization` |
| Depends on | independent; complements 0006 and 0007 |
| Lab status | baseline measurable (pod MTU 1400, 3-node geneve) |

## 1. Motivation

"Layer 2 network routing" is everything between an L2 segment (VLAN/localnet
subnet, KubeVirt L2 domain, EVPN MAC-VRF) and the routed world. Today several
choices are correct-but-slow:

1. **Same-subnet cross-node traffic hairpins** through the OVN logical router —
   `docs/routed-subnet.md` documents the `/32` + gateway-only ACL machinery that
   forces it.
2. **Every subnet is its own flood domain**: ARP/ND for a large segment reaches
   every chassis.
3. **Gateway MAC is per-node** on overlay subnets, so a pod/VM that moves
   (KubeVirt migration, static-IP reschedule) re-ARPs and may see a different MAC.
4. **`localnet` VLAN subnets** flood blindly along the physical topology (no
   EVPN, no MLAG awareness).
5. QoS/ACL evaluation happens twice on hairpin paths.

This proposal is the "make L2 fast and boring" bundle.

## 2. Current state in master

| Symptom | Code |
|---|---|
| Per-node gateway MAC on overlay subnets | `pkg/daemon`, `docs/routed-subnet.md` |
| Hairpin on routed subnets | ACL allow-list matching `eth.dst`/gateway MAC |
| No ARP/ND suppression | not implemented; only `enableMulticastSnoop` per subnet |
| Flood domain = logical switch | OVN default |
| VLAN/localnet provider path | `NetworkTypeVlan` + provider networks in the chart |
| Flow shortcuts | OVS flows from `pkg/daemon/ovs_linux.go` |

## 3. Goals

1. **ARP/ND suppression** on overlay and EVPN subnets: answer ARP/ND locally for
   known peers so broadcasts don't leave the node.
2. **Anycast gateway MAC** per subnet, so L2 mobility doesn't invalidate
   neighbour caches (overlay first).
3. **Local switching fast path**: same-node, same-subnet pod↔pod traffic should
   not traverse the logical router where ACL semantics permit.
4. **Flood-domain control**: per-subnet BUM scope (`chassis|subnet|fabric`),
   `enableMulticastSnoop` defaulting on for large subnets.
5. **Published benchmark matrix** (p50/p99 latency, pps, broadcast rate) per
   optimization, before/after, on the Proxmox lab.

Non-goals: DPDK/vhost-user datapath tuning, OVN's own localnet learning
behaviour, Service load balancing changes.

## 4. Design

### 4.1 ARP/ND suppression

Node-local responder: OVS flows answer ARP for `10.x.x.y` only if the IP→MAC
pair is known locally (pod on this node) or from the EVPN type-2 cache (0007);
otherwise forward. Source of truth: `pkg/ipam` allocations plus the pod
annotations `{provider}.kubernetes.io/ip_address` / `.../mac_address` that
`pkg/speaker/subnet.go` already reads.
API: `Subnet.spec.arpSuppression: auto|always|never` (default `auto` = on for
subnets > 64 pods and for EVPN MAC-VRFs). Stale entries expire on pod deletion
plus a 5-minute full resync; `never` disables.

### 4.2 Anycast gateway MAC

One MAC per subnet (`02:00:00:<hash of subnet>`), same gateway IP on every
chassis (`gateway_mac` on the distributed gateway port). Behaviour change to
document: `kubectl get subnet -o wide` shows a shared MAC; anything keyed off
per-node MACs (some CNI-chaining setups) must adapt.

### 4.3 Local switching fast path

The hairpin is specifically a `routed`-subnet property (`/32` + gateway-only
ACLs). Optimisation: detect "two pods, same node, same subnet" and shortcut in
OVS with a high-priority flow pair, invalidated on pod delete; for
`routed: false` subnets, assert (e2e) that nothing forces the hairpin in the
first place.

### 4.4 Flood-domain control

`bumScope: chassis` (default for big subnets) keeps BUM local until a peer is
unknown; `subnet` = today's behaviour; `fabric` is required for KubeVirt/L2
stretch (EVPN/VLAN). Implement as subnet policy setting
`mcast_snoop`/`mcast_querier` and localnet flood options, plus 0007's IMET
handling.

## 5. Observability

`kube_ovn_arp_suppressed_total{subnet}`, `kube_ovn_hairpin_packets_total{node,subnet}`
(from OVS flow counters), `kube_ovn_flood_bytes_total{subnet}`, and a
`kubectl-ko l2 stats <subnet>` verb (per `docs/kubectl-ko.md`) so the win is
visible instead of theoretical.

## 6. Test plan

* **Unit** — ARP responder flow generation, anycast MAC determinism, `bumScope`
  rendering, shortcut invalidation.
* **e2e single-node** — same-node pod↔pod on a `routed` subnet: counters on the
  shortcut, zero on the router path; delete a pod, shortcut gone, traffic fine.
* **e2e multi-node** — 200-pod subnet, `arpSuppression: never` vs `auto`;
  capture on the tunnel and assert >90% broadcast reduction.
* **KubeVirt** — migration with anycast gateway: neighbour cache stays valid, no
  ARP re-resolution, packet loss only during the migration pause.
* **Benchmark** — 3-node Proxmox lab, `iperf3` + `netperf` TCP_RR, p50/p99 with
  each optimization on/off.

## 7. Milestones

1. Metrics + `kubectl-ko l2 stats` (baseline, no behaviour change).
2. `bumScope` + snooping defaults for large subnets.
3. ARP/ND suppression (overlay).
4. Anycast gateway MAC (overlay, then EVPN).
5. Same-node hairpin shortcut.
6. Public benchmark note in `docs/`.

## 8. Risks / open questions

* Anycast gateway MAC via per-chassis override behaves differently across OVN
  versions — needs a version matrix in CI or a per-node-MAC fallback.
* ARP suppression + `private: true` subnets: does the responder leak knowledge of
  pods a tenant shouldn't see? Must respect subnet isolation.
* The shortcut bypasses conntrack; if QoS/NetworkPolicy depends on conntrack it
  must be disabled for that subnet — needs a precedence table.
* Maybe "L2 routing" in the roadmap means host routing inside a VLAN subnet
  (localnet + node as router) rather than OVN internals — confirm with the
  roadmap owner before building §4.3.

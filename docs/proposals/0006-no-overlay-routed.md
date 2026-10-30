# Proposal 0006 — Disable Geneve: pure routed, no-overlay datapath

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/no-overlay-routed` |
| Depends on | 0002 (BGP/RR), 0004 (node subset), 0005 (optional) |
| Lab status | Geneve path measured: pod MTU **1400** on a 1500 underlay |

## 1. Motivation

Geneve costs MTU (1500 → 1400 in the lab), adds per-packet CPU, and hides the pod
address space from the fabric: every cross-node flow is a tunnel and the fabric
only ever sees node IPs. AI/HPC and telco clusters want the opposite — pods as
first-class routed endpoints, no encapsulation, hardware ECMP in the ToRs, clean
observability.

Kube-OVN has the pieces (underlay/VLAN provider networks, `Subnet.spec.routed`,
a speaker that can announce subnets and pod IPs) but no mode that says "this
network has **no** Geneve at all" — `loopTunnelCheck` still creates the tunnel.

## 2. Current state in master

* `pkg/util/const.go` — `NetworkTypeGeneve` default, `NetworkTypeVlan`,
  `GeneveNic = "genev_sys_6081"`, `VxlanNic = "vxlan_sys_4789"`.
* `pkg/daemon/ovs_linux.go:loopTunnelCheck` — creates/validates the Geneve
  tunnel unconditionally; `pkg/daemon/config.go` subtracts the tunnel header from
  the pod MTU (1400 observed in the lab on a 1500 underlay).
* `docs/routed-subnet.md` — `spec.routed: true` gives `/32` + gateway-only ACLs,
  still over the overlay logical router.
* `NetworkTypeVlan` + `localnet` ports are the closest thing to no-overlay today,
  but each VLAN subnet is isolated; there is no cluster-wide routed pod plan.
* Speaker already announces per-node prefixes once the subnet carries
  `ovn.kubernetes.io/bgp=true` (verified: 9 prefixes with node-IP next hops).

## 3. Goals

1. `Network.spec.mode=routed` (or a cluster default) where **no** Geneve device
   exists on any node (`genev_sys_6081` absent — asserted by the daemon).
2. Each node owns pod CIDR blocks from a global plan, routed natively with the
   node address as next hop and advertised by BGP/OSPF.
3. Pod addressing `/32`(`/128`) with the node as gateway, extending
   `spec.routed` cluster-wide.
4. Fabric reaches any pod via ECMP over node addresses — no tunnel, full 1500
   MTU (jumbo if configured).
5. A clean migration path and a hard precondition check that the fabric really
   routes the blocks.

Non-goals: multi-tenant VPC isolation in routed mode (overlay subnets can coexist
on other networks), Service handling (unchanged).

## 4. Design

### 4.1 Addressing plan

```yaml
apiVersion: kubeovn.io/v1
kind: NodeSubnet               # NEW, cluster-scoped
metadata: {name: routed-pods}
spec:
  cidrBlock: 10.16.0.0/16
  blockSizePerNode: 26         # 64 pods/node
  nodeSelector: {}
  advertise: {protocol: bgp, aggregation: perNodeBlock}
  gatewayMode: nodeAddress     # nodeAddress | sharedVIP
```

Controller allocates a slice per node (deterministic hash + persisted lease, the
`pkg/ipam` pattern). Daemon configures:

```
ip link add br-pods type bridge
ip addr add 10.16.0.1/26 dev br-pods
ip route add 10.16.0.0/16 via <fabric>
```

### 4.2 Daemon changes

* `ensureTunnel()` conditional on mode: don't create; **delete** a stale
  `genev_sys_6081`; fail fast if OVN still has a geneve remote
  (`ovn-sb` encap check).
* New `pkg/daemon/routed.go`: per-node bridge, `/32` veth plumbing reused from
  the CNI ADD path, gateway ARP/ND proxy, `rp_filter` handling.
* MTU: report 1500 (underlay MTU) instead of the geneve subtraction in
  `pkg/daemon/config.go`.
* NAT/egress: routed pods egress by plain routing; scope `IptablesEIP`/
  `VpcNatGateway` as unsupported in v1.

### 4.3 Advertisement

Per node announce `10.16.X.0/26` with the node underlay IP as next hop (or the
shared VIP per 0003/0004). Aggregation modes: `perNodeBlock` (default, ECMP),
`perNode` (`/32` granularity), `aggregate` (one /16 from border nodes).

### 4.4 Preflight (`kubectl-ko routed preflight`)

1. Underlay MTU ≥ 1500 on every node.
2. Fabric routes the pod block to node addresses (probe from a lab peer).
3. No overlap between `NodeSubnet` blocks, services and the underlay.
4. `rp_filter` 0 or 2 where asymmetric ECMP paths exist.
5. OVN has no remaining geneve encap for the chassis.

## 5. Security / multi-tenancy

Without encapsulation there is no datapath tenant boundary. Two options, and
this is the biggest decision in the proposal: (a) keep the logical switch and
only remove tunnel encap (per-node `localnet`) — preserves OVN ACLs, recommended;
(b) pods on a plain bridge — no ACLs, must be documented.

## 6. Migration

New clusters: mode at install. Existing: overlay subnets keep working,
`NodeSubnet` blocks are additional subnets. Moving a live subnet requires pod
recreation (as with `spec.routed` today, per `docs/routed-subnet.md`). Documented
two-phase path: parallel routed subnet → migrate → delete overlay subnet →
remove tunnels.

## 7. Test plan

* **Unit** — block allocation determinism/leases, MTU per mode, preflight checks.
* **e2e** — one routed subnet, pods on 2 nodes; `ovs-vsctl show` must have **no**
  geneve port; `ping -M do -s 1472` must pass (MTU 1500 end-to-end, vs 1400
  measured today); FRR sees the `/26`.
* **Scale/perf** — 1000 pods, cross-node throughput/CPU vs the geneve baseline
  (record as a benchmark note in `docs/`).
* **Failure** — kill a node; the block is withdrawn, no 5-tuple blackhole
  (conntrack flush).

## 8. Milestones

1. `networkMode` + tunnel gating + preflight (no datapath change).
2. `NodeSubnet` CRD + IPAM block leases.
3. Routed pod datapath + ACL decision.
4. Advertisement integration + aggregation modes.
5. Benchmarks, docs, upgrade guide.

## 9. Open questions

* Cluster-wide mode vs per-`Network` (`Network.spec.mode: geneve|vlan|routed`)?
  Per-network is more flexible and probably right.
* Routed mode loses KubeVirt live migration (needs an L2 domain) — must remain
  combinable with EVPN L2 domains (0007).
* `rp_filter` + OVN `ovn0` policy routing is a known footgun — needs an
  integration test, not just docs.
* Do EIP/NAT gateways work in routed mode? Assume no for v1.

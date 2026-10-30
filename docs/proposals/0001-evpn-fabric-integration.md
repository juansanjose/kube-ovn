# Proposal 0001 — EVPN integration with the DC fabric (MAC-VRFs and IP-VRFs)

| | |
|---|---|
| Status | Draft (design only, not implemented) |
| Branch | `proposals/evpn-fabric-integration` |
| Depends on | 0002 (iBGP/RR), 0007 (EVPN VXLAN overlay) |
| Baseline verified in lab | kube-ovn v1.16.15, BGP speaker ↔ FRR, 9 prefixes / 27 paths |

## 1. Motivation

Kube-OVN already carries a minimal EVPN surface: the cluster-scoped `EvpnConf`
CRD (`pkg/apis/kubeovn/v1/evpn_conf.go`, fields `VNI`, `RouteTargets`) plus EVPN
L3VPN for `VpcEgressGateway`, where FRR runs inside the egress-gateway Pod
(`NEXT.md`, PR #6224). That is a per-gateway point solution. It does not let an
operator hand tenant networks to an existing DC fabric as EVPN **MAC-VRF** (L2,
type-2) or **IP-VRF** (L3, type-5) instances, and it does not stitch a Kube-OVN
VPC into a fabric VRF — so tenants still need NAT/EIP hairpins to reach the
fabric.

## 2. Current state in master

| Area | Where | Today |
|---|---|---|
| EVPN CRD | `pkg/apis/kubeovn/v1/evpn_conf.go` | `VNI` + `RouteTargets` only; no RD, VRF, ESI, no VPC binding |
| EVPN consumer | `VpcEgressGateway` pod template | FRR in-Pod, L3VPN, one VPC, tied to gateway replicas |
| BGP speaker | `pkg/speaker/{config,bgp,subnet,eip}.go` | Announces pod IPs / subnet CIDR / EIPs; eBGP only; requires `ovn.kubernetes.io/bgp` on the subnet |
| Tunnel | `pkg/daemon/ovs_linux.go`, `pkg/util/const.go` | Geneve default; `vxlan`/`stt` legacy constants only |
| VPC | `pkg/apis/kubeovn/v1/vpc.go` | OVN logical router per VPC, no fabric-visible identity |

## 3. Goals / non-goals

Goals: (1) a cluster object describing the fabric session (ASN, RRs, VTEP
source, VXLAN port, default RD/RT policy); (2) per-VPC **IP-VRF** binding (L3
VNI, RD, import/export RTs); (3) per-Subnet **MAC-VRF** binding (L2 VNI, RD,
RTs, ESI for multihoming); (4) type-2 and type-5 advertisement with
auto-derived RD/RT conventions; (5) idempotent compare-then-apply reconcile like
`pkg/speaker/bgp.go:reconcileRoutes`.

Non-goals: the overlay datapath itself (0007), replacing `BgpConf`, full
all-active ESI DF election (phase 3).

## 4. Design

### 4.1 API

```yaml
apiVersion: kubeovn.io/v1
kind: EvpnFabric
metadata: {name: dc1}
spec:
  bgpConfRef: default          # reuse peer/ASN settings
  vtepSource: nodeIP           # nodeIP | subnetRef | explicit
  vxlanPort: 4789
  advertise: {macVRF: true, ipVRF: true, includePodIPs: false}
  defaults: {routeDistinguisher: auto, importRT: auto, exportRT: auto}
---
apiVersion: kubeovn.io/v1
kind: EvpnVRF                    # one per tenant VPC
metadata: {name: vrf-tenant-a}
spec:
  fabricRef: dc1
  vpc: tenant-a
  l3VNI: 50100
  routeDistinguisher: "65001:50100"
  importRouteTargets: ["65001:50100"]
  exportRouteTargets: ["65001:50100"]
---
apiVersion: kubeovn.io/v1
kind: EvpnL2Domain              # MAC-VRF backing an L2 subnet
metadata: {name: macvrf-kubevirt}
spec:
  fabricRef: dc1
  subnetRef: kubevirt-prod
  l2VNI: 10100
  routeDistinguisher: "65001:10100"
  importRouteTargets: ["65001:10100"]
  exportRouteTargets: ["65001:10100"]
  esi: {mode: auto, lagId: 1}
```

New `Subnet.spec.evpn.l2DomainRef` / `Vpc.spec.evpn.vrfRef`, validated in
`pkg/webhook` (reject a subnet whose MAC-VRF belongs to another fabric/VPC).
`EvpnConf` becomes a compatibility façade over
`EvpnFabric`+`EvpnVRF` so existing egress-gateway manifests keep working.

### 4.2 Control plane

New `pkg/controller/evpn_fabric.go`: watch the three EVPN types plus `BgpConf`,
`Vpc`, `Subnet`; compute desired EVPN state; push to an agent. Agent options:

* **FRR sidecar (phase 1, recommended)** — reuse the egress-gateway pattern: one
  `frr` container in the speaker DaemonSet, config rendered into a ConfigMap and
  applied via `vtysh -f`. Matches what the lab already runs (FRR 9.1 on the ToR).
* **GoBGP EVPN (phase 2)** — extends `pkg/speaker` instead of adding a second
  routing stack; GoBGP v4 carries EVPN path types but not MAC-VRF state.

Auto-derivation: RD `auto` → `<routerID>:<VNI>`; empty RTs → `<localASN>:<VNI>`.
Status per VRF: `Ready`, `SessionUp`, `RoutesAdvertised`, mirroring the
`ConditionType` helpers used across `pkg/apis/kubeovn/v1`.

### 4.3 Data plane

VTEP = node underlay IP, port 4789, one VTEP per node (`vxlan_sys_4789` is
already a constant). MAC-VRF ↔ logical-switch wiring is 0007's job; this doc
only requires that a MAC-VRF is nameable and that the agent knows the local
interface. IP-VRF = the VPC's OVN logical router, with type-5 routes leaked into
OVN via static routes to the VRF device (no BGP into OVN). MTU inherits the
existing tunnel arithmetic in `pkg/daemon/config.go` — lab measured 1400 with a
1500 underlay.

### 4.4 Failure behaviour

Agent restart ⇒ full re-render from CRDs. Session down ⇒ VRFs `Ready=Unknown`,
advertised count 0, east-west overlay traffic unaffected. Deleting an
`EvpnVRF` withdraws type-5 routes **before** removing the VRF.

## 5. Test plan

**Unit** — RD/RT derivation, prefix-set diffing (reuse `prefixMap` compare),
webhook rejections.

**e2e (containerlab)** — `yamls/clab-evpn.yaml.j2`: FRR spine + 2 leaves, one
kind cluster, two VPCs; assert `show bgp l2vpn evpn route type 2` / `type 5`
carry the tenant prefixes with the expected RT/RD. Note from the lab: FRR 9.1
needs `no bgp ebgp-requires-policy` or inbound updates are silently discarded
(`Inbound updates discarded due to missing policy`) — every new test must set
it.

**Lab (real)** — `docs/proposals/lab/pve-kubeovn-lab.md`; add
`address-family l2vpn evpn` + `advertise-all-vni` to the ToR config.

## 6. Milestones

1. CRD + webhook + controller skeleton (no agent).
2. FRR sidecar, L3 IP-VRF cluster-wide (parity with egress gateway).
3. MAC-VRF / type-2 + ESI auto.
4. Metrics `kube_ovn_evpn_routes_advertised{vrf}` + `kubectl-ko evpn`.
5. Retire the egress-gateway-specific FRR path once parity is proven.

## 7. Risks / open questions

* Two routing stacks (GoBGP + FRR) is operationally ugly — decide FRR-only vs
  GoBGP EVPN before implementing.
* OVN's own EVPN/VTEP support is limited; a host-level VXLAN device means pod
  overlay and EVPN overlay are separate datapaths — validate asymmetric paths.
* ESI `lagId` without an explicit field: derive from subnet name hash, with
  manual override?
* Does stretching an L2 domain for KubeVirt migration conflict with
  `docs/routed-subnet.md` semantics?

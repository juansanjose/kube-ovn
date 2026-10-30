# Proposal 0007 — EVPN VXLAN as an overlay transport (replacing Geneve)

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/evpn-vxlan-overlay` |
| Depends on | 0001 (EVPN objects), 0002 (iBGP/RR) |
| Lab status | Geneve overlay verified; VXLAN not yet exercised |

## 1. Motivation

Geneve (`genev_sys_6081`) is a fine datapath but not a fabric protocol. When the
surrounding DC already runs **EVPN-VXLAN** (the enterprise/telco norm), a
Kube-OVN cluster is either a BGP island with a translation layer or a second
overlay glued on with a gateway Pod. Goal: the cluster's own overlay runs as
VXLAN with an EVPN control plane, so a pod subnet is an L2/L3 EVPN instance the
fabric understands natively — the constructs from 0001, applied to the cluster
overlay instead of only to egress.

## 2. Current state in master

* `pkg/util/const.go` — `NetworkTypeVxlan` and `VxlanNic = "vxlan_sys_4789"`
  exist (legacy), but `NetworkTypeGeneve` is the effective default and
  `loopTunnelCheck` only handles geneve.
* OVN tunnels are Geneve/STT/VXLAN; VXLAN has no TLV metadata, so OVN loses
  `options:remote_ip`/`csum` semantics — any VXLAN design must decide **who owns
  the encapsulation**.
* `EvpnConf` (VNI + RTs) exists and is consumed only by `VpcEgressGateway`
  (FRR in-Pod, L3VPN).
* Behaviours to preserve: `docs/routed-subnet.md`, `docs/network-policy-api.md`,
  static IP/MAC, VPC routing, KubeVirt live migration.

## 3. Goals

1. `Network.spec.transport: geneve | vxlan-evpn` (cluster default via Helm).
2. One VXLAN VTEP per node (`vxlan_sys_4789`), EVPN agent in the speaker
   DaemonSet providing type-2/3/5 and BUM handling.
3. Pods keep NetworkPolicy (OVN ACLs), VPC routing, static IP/MAC, KubeVirt
   migration, and MTU parity (VXLAN 50 B header — same 1400 observed with
   geneve in the lab).
4. Coexistence: geneve and vxlan-evpn networks in one cluster, cross-network
   traffic routed by OVN logical routers.

Non-goals: hardware VTEP integration (phase 2), multicast replication tuning
beyond a baseline flood list.

## 4. Design

### 4.1 Ownership decision (the crux)

| Option | Control plane | Data path | ACLs | Effort |
|---|---|---|---|---|
| A: OVN-native VXLAN encap | OVN SB `encap=vxlan` | OVN tunnel | yes | low, no EVPN integration |
| B: host VXLAN + FRR EVPN, OVN bridged via `localnet` | FRR | kernel VXLAN ↔ OVS bridge | yes if the LS keeps `localnet` ports | medium |
| C: host VXLAN + FRR, pods on a plain bridge | FRR | kernel VXLAN | no (or eBPF/Cilium) | low, loses Kube-OVN features |

**Recommended: B.** Each node's logical switch gets a `localnet` port into
`br-vxlan-<id>` carrying the VXLAN device; pods keep their OVN logical ports, so
ACLs, QoS, static IP and the VPC router keep working. The device is
`nolearning` with an EVPN-managed FDB — exactly the pattern the repo's
containerlab topology already uses for the egress VTEP
(`yamls/clab-bgp.yaml.j2`: `ip link add vxlan1016 type vxlan id 1016 ... nolearning`).

### 4.2 API

```yaml
apiVersion: kubeovn.io/v1
kind: Network
metadata: {name: tenants-l2}
spec:
  transport: vxlan-evpn
  evpn:
    fabricRef: dc1
    l2VNI: 10100
    routeTargets: ["65001:10100"]
    bumMode: headEndReplication
---
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: tenant-a-db}
spec:
  network: tenants-l2
  cidrBlock: 10.20.0.0/24
  evpn: {advertise: both, anycastGateway: true}
```

Anycast gateway (same IP+MAC on every node) keeps KubeVirt VMs' default gateway
valid after live migration.

### 4.3 Datapath per node

```
ip link add vxlan10100 type vxlan id 10100 local <nodeIP> dstport 4789 nolearning
ip link set vxlan10100 master br-vxlan-10100
ovn-nbctl lsp-add <ls> ln-10100 -- lsp-set-type ln-10100 localnet \
  -- lsp-set-addresses ln-10100 unknown -- lsp-set-options ln-10100 network_name=br-vxlan-10100
```

FDB is **not** learned from traffic; the agent programs
`bridge fdb append <mac> dev vxlan10100 dst <remoteVTEP>` from type-2 routes.
BUM: head-end replication built from type-3 IMET routes, or multicast to a
configured group. ARP/ND suppression optional (cuts broadcast in large L2
domains). MTU: `underlay - 50`, and the per-type arithmetic in
`pkg/daemon/config.go` must be extended and unit-tested rather than reusing the
geneve branch.

### 4.4 Reconcile / failure

`loopTunnelCheck` becomes `loopTransportCheck` with per-transport
verify/create/delete; a wrong tunnel on a `vxlan-evpn` node is repaired and
reported. If the EVPN session drops, the VXLAN device keeps the last FDB
(stale-but-working) until GR expiry, then BUM only — "L2 partition, not
blackhole".

## 5. Test plan

* **Unit** — MTU arithmetic per transport, FDB diffing, BUM rendering, anycast
  MAC assignment.
* **e2e** — `yamls/clab-evpn-vxlan.yaml.j2` (FRR already creates `vxlan1016`
  there): pod↔pod across nodes; `bridge fdb show` contains only EVPN entries;
  `show bgp l2vpn evpn route type 2` lists both MACs; `ping -M do -s 1422`
  passes on a 1450 path.
* **KubeVirt** — migrate a VM across nodes without dropping a long-lived TCP
  flow (the acceptance test that motivates EVPN).
* **Policy** — NetworkPolicy still blocks traffic on a `vxlan-evpn` subnet
  (proves ACL ownership stayed in OVN).
* **Lab** — 3-node cluster + FRR ToR with `address-family l2vpn evpn` and
  `advertise-all-vni`; remember `no bgp ebgp-requires-policy`.

## 6. Milestones

1. `transport` field + `loopTransportCheck` refactor.
2. Per-node VXLAN device + localnet bridging + static FDB (intra-cluster L2).
3. FRR EVPN agent: type-3 first, then type-2 with learning off.
4. Type-5 + anycast gateway + ARP suppression.
5. KubeVirt validation, docs, geneve→vxlan migration guide.

## 7. Risks / open questions

* **`localnet` + ACLs**: does OVN apply ACLs to traffic entering a localnet port
  in `from-lport`? Must be verified in the lab before committing — otherwise
  ACLs only apply pod-egress, a regression vs geneve.
* VXLAN without learning requires an EVPN agent on **every** node (FRR sidecar
  cost, one more process to monitor).
* Anycast gateway + OVN router = two sources of truth for the gateway MAC; decide
  who owns it.
* Head-end replication is `N²` flows; document the limits or default to
  multicast for large L2 domains.
* Does conntrack-based QoS/NetworkPolicy survive on the localnet path?

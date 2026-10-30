# Proposal 0002 — iBGP with route reflectors

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/bgp-route-reflectors` |
| Depends on | — (foundation for 0001, 0004, 0006) |
| Lab status | **Baseline verified**: 3 speakers ↔ 1 FRR, eBGP AS 65001/65100 |

## 1. Motivation

Every node runs a GoBGP speaker (`pkg/speaker`, DaemonSet `kube-ovn-speaker`)
peering with a fixed list of `BgpConf.spec.neighbours`. In a real fabric that
means either a full mesh node→leaf session set (a ToR sees one peer per node —
expensive and a scaling cap) or a hand-maintained neighbour list that must change
whenever a node joins. The standard answer is iBGP with the fabric's route
reflectors: the cluster behaves as one speaker group inside the fabric AS.

Measured in the lab today: 3 nodes → 3 sessions on the ToR, each announcing 9
prefixes (subnet `/16` + per-pod `/32`), 27 paths total. At 100 nodes that is
100 sessions per ToR.

## 2. Current state in master

`BgpConfSpec{LocalASN, PeerASN, RouterID, Neighbours, Password, HoldTime,
KeepaliveTime, ConnectTime, EbgpMultiHop, GracefulRestart}`
(`pkg/apis/kubeovn/v1/bgp_conf.go`). Speaker flags in `pkg/speaker/config.go`:
`--cluster-as`, `--neighbor-as`, `--neighbor-address`, `--ebgp-multihop`,
`--passivemode`, `--graceful-restart*`, BFD knobs, `--extended-nexthop`,
`--announce-cluster-ip`. There is **no** peer "type", RR-client flag,
`cluster-id`, next-hop-unchanged, ADD-PATH or peer-group. `AfiSafis` are only
populated when graceful restart or extended-nexthop is set (lab log:
`AfiSafis=[]` is normal — GoBGP defaults to IPv4 unicast).

## 3. Goals / non-goals

Goals: (1) `peerType: external|internal` plus `routeReflector`/`clusterId`/per
neighbour `client`; (2) reflect when this speaker is the RR, accept reflected
routes with NEXT_HOP unchanged; (3) a speaker may be a client of the fabric RRs
(default) **or** an in-cluster RR (`spec.role: reflector`) for fabrics we cannot
touch; (4) declarative peer groups with compare-then-apply reconcile that does
not bounce healthy sessions; (5) BFD per group and GR that does not create
reflection loops.

Non-goals: confederation, BGPsec/RPKI, anycast VIPs (0003).

## 4. Design

### 4.1 API (additive)

```yaml
apiVersion: kubeovn.io/v1
kind: BgpConf
metadata: {name: default}
spec:
  localASN: 65001
  peerASN: 65001          # iBGP => same AS
  routerId: 10.0.0.11
  peerType: internal
  clusterId: 10.0.0.1     # required when role=reflector
  advertiseNextHopSelf: false
  addPathReceive: true
  neighbours: ["10.0.0.1", "10.0.0.2"]
  neighbourGroup:
    bfd: true
    holdTime: 30s
    keepaliveTime: 10s
    passwordSecretRef: {name: bgp-md5, key: password}
```

Speaker flags to add: `--peer-type`, `--cluster-id`, `--route-reflector-client`,
`--next-hop-unchanged`, `--add-path-receive`.

### 4.2 GoBGP wiring (`pkg/speaker/bgp.go` peer add path)

* `AddPeer` with `PeerConf.{PeerAs, LocalAs, RouteReflectorClient,
  RouteReflectorClusterId}`, both `ipv4-unicast`/`ipv6-unicast` AFI/SAFI
  explicitly (do not rely on the GR-gated block).
* Next-hop: for iBGP to a fabric RR, do **not** rewrite to self; for
  locally-originated prefixes (pod/subnet on this node) keep `NextHopSelf`.
  Today `getNextHopAttribute` derives the next hop from `NodeIPs`/`PodIPs` env —
  the lab confirms `POD_IPS` is set per pod (e.g. `192.168.1.112`) and is used
  verbatim.

### 4.3 Reconciliation

Keep `reconcileRoutes → reconcileIPFamily → announceAndWithdraw`; add
`reconcilePeers(desired []Peer)`: list → diff by `(address, AS, vrf)` → update
timers/password in place where GoBGP allows, otherwise bounce only that one
session. Emit `SpeakerPeerReconciled` events and
`kube_ovn_bgp_session_up{peer,type}`.

## 5. Test plan

* **Unit** — desired-peer diffing, cluster-id validation, next-hop decision
  table (style of `pkg/speaker/bgp_test.go`).
* **e2e** — extend the lab topology: FRR node as RR in AS 65001 for two
  speakers; assert the second speaker's routes appear on the first with the
  originating node as next hop (not the RR).
* **Chaos** — kill the RR session for 60s; GR keeps the RIB and the dataplane
  keeps forwarding (verify with `test/e2e/bgp/frr.go`-style assertions).
* **Lab** — the running cluster: change the ToR to `remote-as 65001` with
  `route-reflector-client` for the 3 nodes and re-check the RIB.

## 6. Milestones

1. `peerType`/`clusterId` CRD fields + webhook validation.
2. Peer reconcile without RR (standalone value).
3. In-cluster RR role + next-hop rules.
4. ADD-PATH receive, BFD per group, metrics/events.
5. Docs + chart example.

## 7. Risks / open questions

* In-cluster reflection needs a stable node-to-node underlay; on overlay-only
  clusters the RR loop blackholes during node loss. Require underlay (or 0006)?
* `RouterID` falls back to the pod IP in `ParseFlags` and changes on restart — a
  bouncing RID breaks reflection. Default to the node IP.
* Interaction with `graceful-restart-deferral-time` (360s default) and
  already-withdrawn reflected routes — needs a stale-route age check.
* Per-node RR (DaemonSet) vs a 2-replica Deployment?

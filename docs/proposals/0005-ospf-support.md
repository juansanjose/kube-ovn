# Proposal 0005 — OSPF (and OSPFv3) as an underlay routing protocol

| | |
|---|---|
| Status | Draft (design only) |
| Branch | `proposals/ospf-support` |
| Depends on | 0002 (prefix exchange), 0006 (routed no-overlay) for the payoff |
| Lab status | FRR VMs available; only BGP configured so far |

## 1. Motivation

BGP is the only routing protocol Kube-OVN speaks today. Many enterprise DCs
route leaf-spine with **OSPF**, so plugging a cluster in means static routes on
every leaf or a BGP island. OSPF also unlocks a cleaner 0006 story: inject the
node `/32` or the node's pod block into OSPF with no BGP session at all.

## 2. Current state in master

`pkg/speaker` is GoBGP v4 only (`api`, `apiutil`, `server`); flags are
`--cluster-as`, `--neighbor-as`, `--ebgp-multihop`, `--graceful-restart`, BFD
knobs. No IGP surface anywhere in `pkg/speaker/config.go`. FRR is already used
by the project for EVPN (`VpcEgressGateway`) and by the e2e harness
(`test/e2e/bgp/frr.go`), and the lab ToR is FRR 9.1 — so an FRR-based
implementation is consistent with what already ships.

## 3. Goals

1. Enable OSPFv2/OSPFv3 on the node underlay (or a dedicated interface) so the
   fabric learns node addresses and, optionally, pod subnet prefixes.
2. Coexistence, not replacement: redistribution rules decide what enters OSPF
   (`nodeAddress`, `subnetCIDRs`, `podIPs`, `none`).
3. Declarative area/interface config (`OspfConf`), node-selectable (reuse 0004's
   `advertiserSelector`).
4. MD5/SHA auth and passive interfaces (enterprise requirement).
5. BFD fast failover at parity with the existing BGP BFD support.

Non-goals: IS-IS; OSPF inside OVN; redistributing OVN's whole RIB into OSPF.

## 4. Design

### 4.1 Two options

**A — FRR sidecar in the speaker DaemonSet (recommended).** Reuses the shipped
FRR pattern and the image already in `test/e2e/bgp`. `ospfd`/`ospf6d` per
selected node, config rendered from the CRD, applied via `vtysh -f`, `zebra`
installs routes. Cost: a second routing daemon per node (~40 MB RSS) and a new
failure domain.

**B — pure Go OSPF** (e.g. `bio-rd`). Single binary, no sidecar, but a large
implementation surface (LSA flooding, SPF, areas) and a new dependency to audit.

Ship **A**; keep the CRD protocol-agnostic so B can land later without an API
change.

### 4.2 API

```yaml
apiVersion: kubeovn.io/v1
kind: OspfConf
metadata: {name: dc1-ospf}
spec:
  instance: 1
  routerId: 10.0.0.11
  addressFamily: ipv4            # ipv4 | ipv6
  areas:
    - id: 0.0.0.0
      interfaces:
        - name: eth0
          cost: 10
          networkType: pointToPoint
          helloInterval: 10s
          deadInterval: 40s
          passive: false
          auth: {type: md5, secretRef: {name: ospf-md5, key: password}}
  redistribute: {nodeAddress: true, subnetCIDRs: ["10.16.0.0/16"], podIPs: false}
  bfd: {enabled: true, minTxMs: 300, minRxMs: 300, multiplier: 3}
  nodeSelector: {matchLabels: {kube-ovn/role: ospf-speaker}}
```

### 4.3 Wiring

* `pkg/controller/ospf_conf.go` — validation, node coverage, per-node adjacency
  status.
* `pkg/speaker/ospf.go` — render → compare → atomic write → `vtysh -f`, mirroring
  the speaker's existing config file handling.
* Health: `show ip ospf neighbor json` every 10s →
  `kube_ovn_ospf_adjacency_full{node,area,neighbor}`; redistribution is gated on
  adjacency (no adjacency ⇒ no announce ⇒ no blackhole).
* Coexistence: same prefix set to both protocols; `preferProtocol` decides the
  kernel metric (default BGP wins, OSPF cost as tiebreak).

### 4.4 Timing

Default `deadInterval: 40s` + BFD 300ms gives sub-second detection. Document the
interaction with OVN's own tunnel liveness (`loopTunnelCheck`).

## 5. Security

Secrets from Kubernetes Secrets by reference, never inline — this needs a
scoped Role in the speaker namespace (today the BGP password comes from
`BgpConf`, so no Secret read exists). Reject `auth.type: none` when
`redistribute.subnetCIDRs` is non-empty.

## 6. Test plan

* **Unit** — golden-file config rendering per area/auth combination,
  redistribution allow-list, adjacency gating.
* **e2e** — `yamls/clab-ospf.yaml.j2`, three FRR nodes in area 0 + one kind
  node; assert Full adjacencies, the redistributed pod CIDR present on FRR, and
  withdraw on adjacency loss.
* **Coexistence** — BGP + OSPF up, kill BGP, assert OSPF takes over with <1s
  traffic loss (iperf).
* **Lab** — `kovn-tor` (10.99/192.168.1.113) already runs FRR; add
  `router ospf` with `redistribute connected`.

## 7. Milestones

1. CRD + webhook + renderer (no apply).
2. FRR sidecar apply/reconcile + adjacency metrics on selected nodes.
3. Redistribution of node address + explicit subnets.
4. OSPFv3 + BFD + BGP coexistence policy.

## 8. Risks / open questions

* FRR **and** GoBGP announcing the same prefix is a classic loop source; the
  allow-list may be too weak — consider "OSPF carries only node addresses,
  never pod prefixes" as a hard v1 rule.
* `zebra` installing routes into the same table as OVN/OVS policy routing can
  conflict with `pkg/daemon`'s `ovn0` routes — needs a lab `ip rule` test.
* FRR in the speaker image adds ~50 MB.
* Is the goal "speak OSPF instead of BGP" (small shim) or "full OSPF on every
  node" (this doc)? Clarify with the roadmap owner before building.

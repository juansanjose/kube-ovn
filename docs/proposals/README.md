# Kube-OVN fabric roadmap — proposal series

Design proposals for the Kube-OVN fabric/underlay roadmap goals, one branch per
topic, plus the lab that was actually built to validate them.

Base: `master` @ `f74e284`. Lab validated on kube-ovn **v1.16.15** (see
`lab/pve-kubeovn-lab.md` for why not v1.17.0 from master).

## Goals → proposals

| Roadmap goal | Proposal | Branch |
|---|---|---|
| EVPN with the DC fabric, MAC-VRFs and IP-VRFs | `0001` | `proposals/evpn-fabric-integration` |
| iBGP with route reflectors | `0002` | `proposals/bgp-route-reflectors` |
| Advertise other IPs incl. the Kubernetes API VIP | `0003` | `proposals/bgp-advertise-other-ips` |
| Advertise BGP from a subset of nodes | `0004` | `proposals/bgp-node-subset` |
| Other routing protocols (OSPF) | `0005` | `proposals/ospf-support` |
| Disable Geneve → pure routed, no-overlay | `0006` | `proposals/no-overlay-routed` |
| Disable Geneve → EVPN VXLAN overlay | `0007` | `proposals/evpn-vxlan-overlay` |
| Optimize Layer 2 network routing | `0008` | `proposals/l2-routing-optimization` |
| Lab (Proxmox + FRR), verified | lab | `proposals/fabric-roadmap` |

## Dependency spine

```
0002 iBGP/RR ──┬──> 0004 node subset ──> 0003 advertise other IPs
               ├──> 0001 EVPN fabric ──> 0007 EVPN VXLAN overlay
               └──> 0006 routed (with 0005 OSPF as the no-BGP path)
0008 L2 optimization: independent, benefits from 0007
```

Suggested order: **0002 → 0004 → 0003 → 0006 → 0001 → 0007 → 0005 → 0008**.

## Verified baseline (what the lab proves today)

On 3 k3s v1.31.4 nodes running kube-ovn v1.16.15, geneve overlay, one FRR "ToR":

* nodes Ready, `ovs-ovn`/`ovn-central`/`controller`/`cni` all healthy
* pod-to-pod across nodes: 0% loss, pod MTU 1400
* speaker DaemonSet (GoBGP, AS 65001) ↔ FRR (AS 65100), 3 sessions Established
* per-node announcement of `10.16.0.0/16` + every pod `/32` with the node IP as
  next hop; FRR RIB holds 9 prefixes × 3 paths (eBGP multipath)
* requires `ovn.kubernetes.io/bgp=true` on the Subnet — the speaker announces
  nothing without that annotation (`pkg/speaker/subnet.go`, 1.16)

That is the concrete starting point every proposal builds on.

## Not attempted here

* Any CRD/code from the proposals — these branches are design documents plus the
  lab scripts that were actually executed.
* Touching the pre-existing calico cluster on VMs 100-102 (`k8s-cp1`, `k8s-w1`,
  `k8s-w2`): 120 days old, GPU operator, left alone deliberately.

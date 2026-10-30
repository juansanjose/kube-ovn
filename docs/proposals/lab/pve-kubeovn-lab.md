# Lab: a Kube-OVN test cluster on Proxmox VE — **verified, running**

This is the lab that was actually built and validated on 2026-10-27, not a
runbook. Everything below was executed; the results quoted are measured.

Host: Proxmox VE 9.2.3, kernel 7.0.12-1-pve, node `servidor` (192.168.1.36),
56 cores / 125 GB RAM, storage `lab-ssd` (zfspool, 1.6 TB free).
Bridge `vmbr0`, cloud image `/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img`
(Ubuntu 24.04.5, kernel 6.8.0-124-generic).

## 1. Topology as built

| VMID | name | role | vCPU/RAM/disk | IP |
|---|---|---|---|---|
| 110 | `kovn-cp1` | k3s server, kube-ovn control plane | 4 / 8 G / 30 G | 192.168.1.110 |
| 111 | `kovn-w1` | k3s agent | 4 / 8 G / 30 G | 192.168.1.111 |
| 112 | `kovn-w2` | k3s agent | 4 / 8 G / 30 G | 192.168.1.112 |
| 113 | `kovn-tor` | FRR 8.4.4 "ToR" (AS 65100) | 2 / 2 G / 10 G | 192.168.1.113 |

Deliberately untouched: VMs 100-102 (`k8s-cp1`, `k8s-w1`, `k8s-w2`) — a 120-day
old **calico** cluster with GPU passthrough and `gpu-operator`. Do not install
kube-ovn there without a stated plan to replace calico.

## 2. Why VMs and not a container

The first attempt ran inside an LXC container (user namespace, `uid_map
0→100000`). Result:

```
+ /usr/share/openvswitch/scripts/ovs-ctl load-kmod
modprobe: FATAL: Module openvswitch not found in directory /lib/modules/7.0.12-1-pve
```

`insmod` of the extracted kernel module fails with `Operation not permitted`
(`CAP_SYS_MODULE` is namespaced away), and `mknod /dev/kmsg` is denied, so even a
kind cluster only started after setting `KubeletInUserNamespace: true` — and then
`ovs-ovn` crashloops because there is no OVS datapath. Kube-OVN cannot run
without the kernel module. VMs have a real kernel; `modprobe openvswitch`
succeeds there (`lsmod | grep -c openvswitch` → 6).

## 3. Create the VMs

`hack/lab/pve-create-vms.sh` (runs on the PVE host, idempotent per VMID):

```bash
SRC=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img
for spec in "110 kovn-cp1 4 8192 30 192.168.1.110" \
            "111 kovn-w1  4 8192 30 192.168.1.111" \
            "112 kovn-w2  4 8192 30 192.168.1.112" \
            "113 kovn-tor 2 2048 10 192.168.1.113"; do
  set -- $spec; id=$1; name=$2; cores=$3; mem=$4; disk=$5; ip=$6
  qm create $id --name $name --cores $cores --memory $mem --cpu host \
    --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 \
    --serial0 socket --vga serial0 --agent enabled=1 --citype nocloud \
    --ide2 lab-ssd:cloudinit --boot order=scsi0
  qm importdisk $id $SRC lab-ssd
  qm set $id --scsi0 lab-ssd:vm-$id-disk-0,discard=on,iothread=1,ssd=1
  qm resize $id scsi0 ${disk}G
  qm set $id --ciuser ubuntu --sshkeys /root/labkeys.pub \
    --ipconfig0 ip=${ip}/24,gw=192.168.1.1 --nameserver 1.1.1.1
  qm start $id
done
```

Notes: `--agent enabled=1` needs `qemu-guest-agent` installed in the image
(the stock noble cloud image does not ship it, so `qm guest exec` is unavailable
— use SSH). VMs on `vmbr0` (LAN) so the agent host can reach them; an
internal-only bridge would isolate the fabric but also lock out the operator.

## 4. k3s

`hack/lab/bootstrap-k3s.sh`: server on `.110` with

```
--flannel-backend=none --disable-network-policy --disable=traefik,servicelb
--cluster-cidr=10.16.0.0/16 --service-cidr=10.96.0.0/12
--node-ip=<node ip> --tls-san=<cp ip> --write-kubeconfig-mode 600
```

agents join with `K3S_TOKEN` from `/var/lib/rancher/k3s/server/node-token`.
Result: 3 nodes, all `Ready` once kube-ovn is installed.

## 5. Install kube-ovn — the version trap

Installing **master's** chart (`charts/kube-ovn-v2`, `VERSION=v1.17.0`) with the
published `kubeovn/kube-ovn:v1.17.0` image fails:

```
unknown flag: --cert-manager-issuer-name
```

master's chart is ahead of the last released image (there is no `v1.17.0` git
tag; only `release-1.16` exists upstream). Use the **release-1.16 chart** with
the **v1.16.15 image**:

```bash
git clone --depth 1 -b release-1.16 https://github.com/kubeovn/kube-ovn /root/kovn-116
kubectl label node --overwrite -l node-role.kubernetes.io/control-plane kube-ovn/role=master
helm install kubeovn /root/kovn-116/charts/kube-ovn-v2 -n kube-system \
  --set global.images.kubeovn.tag=v1.16.15
```

Verify: `kubectl get nodes` → 3× Ready; `ovs-ovn`, `ovn-central`,
`kube-ovn-controller`, `kube-ovn-cni` Running.

If you build your own image from master (`make build`), the master chart is
fine — that is the supported pairing.

## 6. Enable the BGP speaker

```bash
helm upgrade kubeovn /root/kovn-116/charts/kube-ovn-v2 -n kube-system --reuse-values \
  --set bgpSpeaker.enabled=true \
  --set-json 'bgpSpeaker.args=["--neighbor-address=192.168.1.113","--neighbor-as=65100","--cluster-as=65001","-v=5"]'
```

**The speaker announces nothing until the Subnet is annotated** — this cost the
most time in the lab:

```bash
kubectl annotate subnet ovn-default ovn.kubernetes.io/bgp=true --overwrite
```

(`pkg/speaker/subnet.go` skips subnets without `util.BgpAnnotation`;
`true`/`cluster` = announce from every speaker, `local` = only the hosting node.)

## 7. FRR ToR

```
router bgp 65100
 bgp router-id 192.168.1.113
 no bgp ebgp-requires-policy          # <-- REQUIRED, see below
 no bgp default ipv4-unicast
 neighbor 192.168.1.110 remote-as 65001
 neighbor 192.168.1.111 remote-as 65001
 neighbor 192.168.1.112 remote-as 65001
 address-family ipv4 unicast
  neighbor 192.168.1.110 activate
  neighbor 192.168.1.111 activate
  neighbor 192.168.1.112 activate
```

**Gotcha**: FRR ≥ 7.4 defaults to `ebgp-requires-policy`. Without that line the
sessions establish but every update is dropped and the RIB stays empty;
`show bgp neighbor <ip>` says `Inbound updates discarded due to missing policy`,
and `show bgp summary` shows `(Policy)` in the PfxRcd column. Sessions look
healthy — this is a silent failure, and any e2e that only checks "Established"
will pass while carrying zero routes.

## 8. Measured results

```
$ kubectl get nodes
kovn-cp1   Ready   control-plane,master   v1.31.4+k3s1   192.168.1.110
kovn-w1    Ready   <none>                 v1.31.4+k3s1   192.168.1.111
kovn-w2    Ready   <none>                 v1.31.4+k3s1   192.168.1.112

$ kubectl exec nettest-a -- ping -c2 10.16.0.9      # pods on w1 / w2
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max = 2.242/3.507/4.773 ms
$ kubectl exec nettest-a -- cat /sys/class/net/eth0/mtu
1400

$ sudo vtysh -c "show bgp ipv4 unicast" | tail -3        # on kovn-tor
Displayed  9 routes and 27 total paths
```

9 routes = subnet `10.16.0.0/16` + 8 pod `/32`s; 27 paths = 3 speakers × 9,
i.e. eBGP multipath to all three nodes. Per-node next hop is the node IP
(`announcing route with prefix 10.16.0.0/16 and nexthop: 192.168.1.112`).

## 9. What each proposal can now be tested against

| Proposal | Lab prep | Acceptance |
|---|---|---|
| 0001 EVPN fabric | `address-family l2vpn evpn` + `advertise-all-vni` on the ToR | type-2/5 routes with expected RT/RD |
| 0002 iBGP/RR | set `remote-as 65001` + `route-reflector-client` on the ToR | reflected routes keep the origin node as next hop |
| 0003 other IPs | `--announce-cluster-ip`, annotated Services | ClusterIP/VIP in the ToR RIB, withdraw on probe failure |
| 0004 node subset | annotate subnet `local` vs `cluster`; label one node | session count and next-hop distribution |
| 0005 OSPF | `router ospf` + `redistribute connected` on the ToR | Full adjacency, node block in the RIB |
| 0006 routed | `Network.spec.mode=routed` (not implemented) | no `genev_sys_6081`, MTU 1500, `ping -M do -s 1472` |
| 0007 EVPN VXLAN | `Network.spec.transport=vxlan-evpn` (not implemented) | EVPN-only FDB, KubeVirt migration |
| 0008 L2 optimize | default cluster | broadcast counters, `kubectl-ko l2 stats` |

## 10. Teardown

```bash
for id in 110 111 112 113; do qm stop $id; qm destroy $id --purge 1; done
```

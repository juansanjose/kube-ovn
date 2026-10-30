#!/usr/bin/env bash
# Create the Kube-OVN lab VMs on Proxmox VE. RUN ON THE PVE HOST as root.
# Verified on PVE 9.2.3 / Ubuntu 24.04 noble cloud image, 2026-10-27.
#
#   SSH_PUBKEY_FILE=/root/labkeys.pub ./pve-create-vms.sh
#
# Env:
#   IMG        cloud image path          (default /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img)
#   STORAGE    PVE storage               (default lab-ssd)
#   BRIDGE     bridge                    (default vmbr0)
#   GW / DNS   guest gateway / resolver  (default 192.168.1.1 / 1.1.1.1)
#   NET        /24 prefix for guest IPs  (default 192.168.1)
set -euo pipefail

IMG=${IMG:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}
STORAGE=${STORAGE:-lab-ssd}
BRIDGE=${BRIDGE:-vmbr0}
GW=${GW:-192.168.1.1}
DNS=${DNS:-1.1.1.1}
NET=${NET:-192.168.1}
KEY=${SSH_PUBKEY_FILE:?set SSH_PUBKEY_FILE to a public key file}

[[ -f $IMG ]] || { echo "missing cloud image $IMG" >&2; exit 1; }
[[ -f $KEY ]] || { echo "missing ssh key $KEY" >&2; exit 1; }
command -v qm >/dev/null || { echo "not a PVE host (no qm)" >&2; exit 1; }

# vmid|name|cores|mem_mb|disk_gb|last_octet
VMS=(
  "110|kovn-cp1|4|8192|30|110"
  "111|kovn-w1|4|8192|30|111"
  "112|kovn-w2|4|8192|30|112"
  "113|kovn-tor|2|2048|10|113"
)

for spec in "${VMS[@]}"; do
  IFS='|' read -r id name cores mem disk last <<<"$spec"
  ip="${NET}.${last}"
  if qm status "$id" >/dev/null 2>&1; then
    echo "[$id] $name exists — skipping"
    continue
  fi
  echo "[$id] creating $name (${cores}c/${mem}M/${disk}G, $ip)"
  qm create "$id" --name "$name" --cores "$cores" --memory "$mem" --cpu host \
    --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single --ostype l26 \
    --serial0 socket --vga serial0 --agent enabled=1 --citype nocloud \
    --ide2 "${STORAGE}:cloudinit" --boot order=scsi0
  qm importdisk "$id" "$IMG" "$STORAGE" >/dev/null
  qm set "$id" --scsi0 "${STORAGE}:vm-${id}-disk-0,discard=on,iothread=1,ssd=1"
  qm resize "$id" scsi0 "${disk}G" >/dev/null
  qm set "$id" --ciuser ubuntu --sshkeys "$KEY" \
    --ipconfig0 "ip=${ip}/24,gw=${GW}" --nameserver "$DNS" --searchdomain lan
  qm start "$id" >/dev/null
done

qm list
echo "done — wait ~60s for cloud-init, then run bootstrap-k3s.sh"

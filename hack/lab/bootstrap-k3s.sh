#!/usr/bin/env bash
# Bootstrap k3s for the Kube-OVN lab (server on 192.168.1.110, agents .111/.112).
# RUN FROM A HOST THAT CAN SSH TO ALL THREE VMs as ubuntu with KEY.
# Verified 2026-10-27 with k3s v1.31.4+k3s1.
#
# Why these flags: flannel would fight kube-ovn for the CNI; kube-ovn implements
# NetworkPolicy itself; traefik/servicelb are unused in a lab.
set -euo pipefail

KEY=${SSH_KEY:-/root/.ssh/kubeovn_lab}
CP=${CP:-192.168.1.110}
AGENTS=${AGENTS:-"192.168.1.111 192.168.1.112"}
K3S_VERSION=${K3S_VERSION:-v1.31.4+k3s1}
POD_CIDR=${POD_CIDR:-10.16.0.0/16}
SVC_CIDR=${SVC_CIDR:-10.96.0.0/12}

rssh() { local ip=$1; shift; ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "ubuntu@$ip" "$@"; }

common_setup() {
  cat <<'EOF'
set -e
swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true
modprobe br_netfilter || true
echo br_netfilter >/etc/modules-load.d/kube-ovn.conf
printf 'net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\n' >/etc/sysctl.d/90-kube-ovn.conf
sysctl --system >/dev/null
EOF
}

echo "== server $CP"
{ common_setup; cat <<EOF
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server \\
  --node-ip ${CP} --tls-san ${CP} \\
  --flannel-backend=none --disable-network-policy --disable=traefik,servicelb \\
  --cluster-cidr=${POD_CIDR} --service-cidr=${SVC_CIDR} --write-kubeconfig-mode 600
for i in \$(seq 1 90); do k3s kubectl get --raw=/readyz >/dev/null 2>&1 && break; sleep 2; done
k3s kubectl get --raw=/readyz >/dev/null && echo "server ready"
EOF
} | rssh "$CP" "sudo bash -s"

mkdir -p /root/.kube
rssh "$CP" "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${CP}/" > /root/.kube/kovn-lab.yaml
chmod 600 /root/.kube/kovn-lab.yaml
TOKEN=$(rssh "$CP" "sudo cat /var/lib/rancher/k3s/server/node-token")

for ip in $AGENTS; do
  echo "== agent $ip"
  { common_setup; cat <<EOF
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} \\
  K3S_URL=https://${CP}:6443 K3S_TOKEN=${TOKEN} sh -s - agent --node-ip ${ip}
EOF
  } | rssh "$ip" "sudo bash -s"
done

export KUBECONFIG=/root/.kube/kovn-lab.yaml
kubectl get nodes -o wide   # NotReady until kube-ovn is installed — expected

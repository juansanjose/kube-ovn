#!/usr/bin/env bash
# Install kube-ovn into the lab cluster with a chart/image pair that matches.
#
# TRAP (verified): master's chart (charts/kube-ovn-v2, VERSION v1.17.0) does not
# work with the published v1.17.0 image — the controller dies with
# "unknown flag: --cert-manager-issuer-name". There is no v1.17.0 git tag; the
# newest release branch is release-1.16. Use the release-1.16 chart with the
# v1.16.15 image, or build your own image from master with `make build`.
#
#   ./install-kubeovn.sh                 # release-1.16 chart + v1.16.15 image
#   ./install-kubeovn.sh --with-speaker  # also enable the BGP speaker
set -euo pipefail

KUBECONFIG=${KUBECONFIG:-/root/.kube/kovn-lab.yaml}
export KUBECONFIG
CHART_DIR=${CHART_DIR:-/root/kovn-116}
TAG=${TAG:-v1.16.15}
NEIGHBOR=${NEIGHBOR:-192.168.1.113}
NEIGHBOR_AS=${NEIGHBOR_AS:-65100}
CLUSTER_AS=${CLUSTER_AS:-65001}
SUBNET=${SUBNET:-ovn-default}
WITH_SPEAKER=false
[[ "${1:-}" == "--with-speaker" ]] && WITH_SPEAKER=true

[[ -f "$CHART_DIR/charts/kube-ovn-v2/Chart.yaml" ]] || {
  git clone --depth 1 -b release-1.16 https://github.com/kubeovn/kube-ovn "$CHART_DIR"
}

kubectl label node --overwrite -l node-role.kubernetes.io/control-plane kube-ovn/role=master

if helm status kubeovn -n kube-system >/dev/null 2>&1; then
  helm upgrade kubeovn "$CHART_DIR/charts/kube-ovn-v2" -n kube-system --reuse-values \
    --set "global.images.kubeovn.tag=$TAG"
else
  helm install kubeovn "$CHART_DIR/charts/kube-ovn-v2" -n kube-system \
    --set "global.images.kubeovn.tag=$TAG"
fi

echo "waiting for nodes to become Ready"
kubectl wait --for=condition=Ready node --all --timeout=300s

if $WITH_SPEAKER; then
  helm upgrade kubeovn "$CHART_DIR/charts/kube-ovn-v2" -n kube-system --reuse-values \
    --set bgpSpeaker.enabled=true \
    --set-json "bgpSpeaker.args=[\"--neighbor-address=${NEIGHBOR}\",\"--neighbor-as=${NEIGHBOR_AS}\",\"--cluster-as=${CLUSTER_AS}\"]"
  # Without this annotation the speaker announces NOTHING (pkg/speaker/subnet.go).
  kubectl annotate subnet "$SUBNET" ovn.kubernetes.io/bgp=true --overwrite
  echo "speaker enabled; verify on the router: show bgp summary / show bgp ipv4 unicast"
fi

kubectl get nodes
kubectl -n kube-system get pods | grep -E 'ovs-ovn|ovn-central|kube-ovn'

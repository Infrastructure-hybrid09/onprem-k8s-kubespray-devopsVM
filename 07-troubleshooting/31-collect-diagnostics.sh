#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
INVENTORY="$PROJECT_ROOT/03-kubespray/inventory/mycluster/hosts.yaml"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$PROJECT_ROOT/03-kubespray/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
OUTPUT_DIR="$PROJECT_ROOT/logs/diagnostics-$(date +%Y%m%d-%H%M%S)"

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"
install -d -m 0750 "$OUTPUT_DIR"

kubectl get nodes -o wide >"$OUTPUT_DIR/nodes.txt" 2>&1 || true
kubectl get pods -A -o wide >"$OUTPUT_DIR/pods.txt" 2>&1 || true
kubectl get events -A --sort-by=.lastTimestamp >"$OUTPUT_DIR/events.txt" 2>&1 || true
kubectl get gatewayclass,gateway,httproute -A -o yaml >"$OUTPUT_DIR/gateway-api.yaml" 2>&1 || true
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml >"$OUTPUT_DIR/metrics-api.yaml" 2>&1 || true
kubectl -n kube-system logs deployment/coredns --tail=200 >"$OUTPUT_DIR/coredns.log" 2>&1 || true
kubectl -n kube-system logs deployment/metrics-server --tail=200 >"$OUTPUT_DIR/metrics-server.log" 2>&1 || true
kubectl -n nginx-gateway logs deployment/ngf-nginx-gateway-fabric --all-containers --tail=200 \
  >"$OUTPUT_DIR/ngf.log" 2>&1 || true

"$VENV_DIR/bin/ansible" -i "$INVENTORY" all --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell \
  -a 'echo ===HOST===; hostnamectl --static; ip -br -4 address; ip -4 route; echo ===SERVICES===; systemctl --no-pager --full status kubelet containerd || true; echo ===JOURNAL===; journalctl -u kubelet -u containerd -b -n 150 --no-pager' \
  >"$OUTPUT_DIR/node-runtime.txt" 2>&1 || true

echo "diagnostics saved to $OUTPUT_DIR"
echo "Secret data, private keys and kubeconfig were intentionally not collected"

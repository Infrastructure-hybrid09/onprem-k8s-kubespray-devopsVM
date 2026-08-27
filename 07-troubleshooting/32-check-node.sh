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
NODE="${1:-}"

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"

[[ -x "$VENV_DIR/bin/ansible" ]] || { echo "Ansible venv is missing: $VENV_DIR" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "SSH key is missing: $SSH_KEY" >&2; exit 1; }

case "$NODE" in
  cp1|cp2|cp3|worker1|worker2|worker3) ;;
  *) echo "usage: $0 {cp1|cp2|cp3|worker1|worker2|worker3}" >&2; exit 2 ;;
esac

kubectl get node "$NODE" -o wide || true
kubectl describe node "$NODE" || true
"$VENV_DIR/bin/ansible" -i "$INVENTORY" "$NODE" --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell \
  -a 'set -o pipefail; hostnamectl --static; ip -br -4 address; ip -4 route; ip -d link show vxlan.calico || true; crictl info; crictl ps -a; crictl images; systemctl --no-pager --full status kubelet containerd; journalctl -u kubelet -u containerd -b -n 200 --no-pager; if test -f /etc/kubernetes/admin.conf; then kubeadm certs check-expiration || true; fi'

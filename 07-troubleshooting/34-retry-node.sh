#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$PROJECT_ROOT/03-kubespray/vendor/kubespray}"
INVENTORY="$PROJECT_ROOT/03-kubespray/inventory/mycluster/hosts.yaml"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
NODE="${1:-}"
LOG_DIR="$PROJECT_ROOT/logs"

case "$NODE" in
  worker1|worker2|worker3) LIMIT_ARGS=(--limit "$NODE") ;;
  cp1|cp2|cp3)
    echo "Control Plane/etcd retry uses the full inventory to preserve quorum dependencies"
    LIMIT_ARGS=()
    ;;
  *) echo "usage: $0 {cp1|cp2|cp3|worker1|worker2|worker3}" >&2; exit 2 ;;
esac

install -d -m 0750 "$LOG_DIR"
export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"
"$VENV_DIR/bin/ansible-playbook" \
  -i "$INVENTORY" "$KUBESPRAY_DIR/cluster.yml" \
  -b -vv --private-key "$SSH_KEY" \
  "${LIMIT_ARGS[@]}" 2>&1 | tee "$LOG_DIR/34-retry-$NODE-$(date +%Y%m%d-%H%M%S).log"

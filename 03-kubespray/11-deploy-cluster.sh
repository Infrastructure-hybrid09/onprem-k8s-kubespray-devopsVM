#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
INVENTORY="$SCRIPT_DIR/inventory/mycluster/hosts.yaml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-1}"
case "$ANSIBLE_VERBOSITY" in
  0) VERBOSITY_ARGS=() ;;
  1) VERBOSITY_ARGS=(-v) ;;
  2) VERBOSITY_ARGS=(-vv) ;;
  3) VERBOSITY_ARGS=(-vvv) ;;
  *) echo "ANSIBLE_VERBOSITY must be 0, 1, 2 or 3" >&2; exit 2 ;;
esac

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg"
"$SCRIPT_DIR/10-preflight.sh"
install -d -m 0750 "$LOG_DIR"
LOG_FILE="$LOG_DIR/11-cluster-$(date +%Y%m%d-%H%M%S).log"

"$VENV_DIR/bin/ansible-playbook" \
  -i "$INVENTORY" "$KUBESPRAY_DIR/cluster.yml" \
  -b "${VERBOSITY_ARGS[@]}" --private-key "$SSH_KEY" 2>&1 | tee "$LOG_FILE"

echo "cluster deployment completed"
echo "log: $LOG_FILE"

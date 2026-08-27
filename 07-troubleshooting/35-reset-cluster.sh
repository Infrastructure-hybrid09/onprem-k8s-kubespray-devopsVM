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

if [[ "${CONFIRM_RESET:-}" != "neuroplan-destroy" ]]; then
  echo "This removes the Kubernetes cluster from all six nodes." >&2
  echo "Take VMware snapshots and an etcd snapshot, then run:" >&2
  echo "CONFIRM_RESET=neuroplan-destroy $0" >&2
  exit 2
fi

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"
"$VENV_DIR/bin/ansible-playbook" \
  -i "$INVENTORY" "$KUBESPRAY_DIR/reset.yml" \
  -b -v --private-key "$SSH_KEY"

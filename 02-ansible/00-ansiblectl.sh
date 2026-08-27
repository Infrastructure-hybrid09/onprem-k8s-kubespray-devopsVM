#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
VENV_DIR="${VENV_DIR:-${PROJECT_ROOT}/.venv}"
INVENTORY="${SCRIPT_DIR}/inventory/hosts.yaml"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/neuroplan_k8s}"
ANSIBLE_CONFIG_FILE="${SCRIPT_DIR}/ansible.cfg"
CONTROL_GATE="${PROJECT_ROOT}/01-bootstrap/05-verify-devops-control.sh"

usage() {
  cat <<'EOF'
Usage: ./02-ansible/00-ansiblectl.sh ACTION

Run only on the PC2 DevOps VM as the devops user.

Actions:
  inventory   Show the fixed central inventory graph
  ping        Verify k8sadmin SSH and passwordless sudo on CP/Worker
  preflight   Run the read-only network/OS preflight playbook
  baseline    Apply the non-Kubernetes OS baseline, then validate it
  validate    Validate the existing OS baseline without changing it
  registry    Install/update the Registry on the local DevOps VM
EOF
}

if [[ ${EUID} -eq 0 ]]; then
  echo "run on the PC2 DevOps VM as devops, not root" >&2
  exit 1
fi

if [[ "$(id -un)" != "devops" ]]; then
  echo "expected local operator 'devops'; current user is '$(id -un)'" >&2
  exit 1
fi

action="${1:-}"
if [[ -z "${action}" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

for executable in ansible ansible-inventory ansible-playbook; do
  if [[ ! -x "${VENV_DIR}/bin/${executable}" ]]; then
    echo "missing ${VENV_DIR}/bin/${executable}; run 03-kubespray/02-install-kubespray.sh first" >&2
    exit 2
  fi
done

[[ -f "${INVENTORY}" ]] || { echo "inventory not found: ${INVENTORY}" >&2; exit 2; }
[[ -f "${SSH_KEY}" ]] || { echo "SSH key not found: ${SSH_KEY}" >&2; exit 2; }
[[ -f "${CONTROL_GATE}" ]] || { echo "central-control gate not found: ${CONTROL_GATE}" >&2; exit 2; }

export ANSIBLE_CONFIG="${ANSIBLE_CONFIG_FILE}"
COMMON_OPTIONS=(-i "${INVENTORY}" --private-key "${SSH_KEY}")

require_local_sudo() {
  echo "Refreshing the local devops sudo credential for localhost playbook tasks"
  sudo -v
}

require_managed_control() {
  echo "Running the mandatory six-node central-control gate"
  bash "${CONTROL_GATE}"
}

run_network_preflight() {
  "${VENV_DIR}/bin/ansible-playbook" "${COMMON_OPTIONS[@]}" \
    "${SCRIPT_DIR}/playbooks/04-preflight.yml"
}

case "${action}" in
  inventory)
    "${VENV_DIR}/bin/ansible-inventory" -i "${INVENTORY}" --graph
    ;;
  ping)
    require_managed_control
    "${VENV_DIR}/bin/ansible" "${COMMON_OPTIONS[@]}" kubernetes_nodes \
      -m ansible.builtin.ping
    "${VENV_DIR}/bin/ansible" "${COMMON_OPTIONS[@]}" kubernetes_nodes \
      --become -m ansible.builtin.command -a 'id -u'
    ;;
  preflight)
    require_managed_control
    require_local_sudo
    run_network_preflight
    ;;
  baseline)
    require_managed_control
    require_local_sudo
    run_network_preflight
    "${VENV_DIR}/bin/ansible-playbook" "${COMMON_OPTIONS[@]}" \
      "${SCRIPT_DIR}/playbooks/05-os-baseline.yml"
    "${VENV_DIR}/bin/ansible-playbook" "${COMMON_OPTIONS[@]}" \
      "${SCRIPT_DIR}/playbooks/06-validate-baseline.yml"
    ;;
  validate)
    require_managed_control
    require_local_sudo
    "${VENV_DIR}/bin/ansible-playbook" "${COMMON_OPTIONS[@]}" \
      "${SCRIPT_DIR}/playbooks/06-validate-baseline.yml"
    ;;
  registry)
    require_local_sudo
    "${VENV_DIR}/bin/ansible-playbook" "${COMMON_OPTIONS[@]}" \
      "${PROJECT_ROOT}/04-registry/07-install-registry.yml"
    ;;
  *)
    echo "unknown action: ${action}" >&2
    usage >&2
    exit 2
    ;;
esac

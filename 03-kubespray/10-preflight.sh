#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
INVENTORY="$SCRIPT_DIR/inventory/mycluster/hosts.yaml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
CONTROL_GATE="$PROJECT_ROOT/01-bootstrap/05-verify-devops-control.sh"
API_VIP="192.168.34.100"

[[ -x "$VENV_DIR/bin/ansible" ]] || { echo "run 02-install-kubespray.sh first" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "SSH key not found: $SSH_KEY" >&2; exit 1; }
[[ -x "$CONTROL_GATE" ]] || { echo "control gate is not executable: $CONTROL_GATE" >&2; exit 1; }

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg"
"$CONTROL_GATE"
"$SCRIPT_DIR/03-verify-release.sh"

if grep -Eq '^[[:space:]]*apiserver_loadbalancer_domain_name:' \
     "$SCRIPT_DIR/inventory/mycluster/group_vars/all/all.yml"; then
  echo "remove apiserver_loadbalancer_domain_name; the canonical endpoint is the API VIP" >&2
  exit 1
fi
EFFECTIVE_CP1="$("$VENV_DIR/bin/ansible-inventory" -i "$INVENTORY" --host cp1)"
[[ "$(jq -r '.loadbalancer_apiserver.address // empty' <<<"$EFFECTIVE_CP1")" == "$API_VIP" ]] || {
  echo "loadbalancer_apiserver.address must be $API_VIP" >&2
  exit 1
}
echo "[PASS] Kubespray desired endpoint is the fixed API VIP $API_VIP"

"$VENV_DIR/bin/ansible-inventory" -i "$INVENTORY" --graph
"$VENV_DIR/bin/ansible" -i "$INVENTORY" all \
  --private-key "$SSH_KEY" -m ping
"$VENV_DIR/bin/ansible" -i "$INVENTORY" all \
  --private-key "$SSH_KEY" -b -m ansible.builtin.shell \
  -a 'set -eu; ip -o -4 address show | grep -Fq " {{ ip }}/"; test "$(ip -4 route show default | wc -l)" -eq 1'

echo "Checking existing external API VIP path"
set +e
API_VIP_RESULT="$(nc -zvw3 "$API_VIP" 6443 2>&1)"
API_VIP_RC=$?
set -e
if (( API_VIP_RC != 0 )); then
  if grep -Eqi 'refused|reset' <<<"$API_VIP_RESULT"; then
    echo "[WARN] API VIP is reachable but no API backend is listening yet"
  else
    echo "$API_VIP_RESULT" >&2
    echo "API VIP timed out or has no route; stop for Network/LB investigation" >&2
    exit 1
  fi
fi

echo "Checking DevOps private Registry path"
curl -fsS --connect-timeout 5 http://192.168.34.21:5000/v2/ >/dev/null || {
  echo "Registry is not ready; complete steps 07-09 before cluster deployment" >&2
  exit 1
}

echo "Kubespray preflight completed"

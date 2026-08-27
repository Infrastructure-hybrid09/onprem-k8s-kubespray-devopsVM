#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
INVENTORY="$PROJECT_ROOT/03-kubespray/inventory/mycluster/hosts.yaml"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$PROJECT_ROOT/03-kubespray/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"

for attempt in {1..20}; do
  kubectl --server=https://192.168.34.100:6443 \
    --request-timeout=5s get --raw='/readyz' >/dev/null
  curl -ksS --connect-timeout 5 --max-time 10 \
    --resolve app.nplan.local:443:192.168.24.100 \
    https://app.nplan.local/validation | grep -Fq validation-ok
done
echo "[PASS] API and Service VIP repeated checks"

ETCD_OBSERVER=""
for node in cp1 cp2 cp3; do
  if "$VENV_DIR/bin/ansible" -i "$INVENTORY" "$node" \
       --private-key "$SSH_KEY" -m ping >/dev/null 2>&1; then
    ETCD_OBSERVER="$node"
    break
  fi
done
[[ -n "$ETCD_OBSERVER" ]] || { echo "no Control Plane observer is reachable" >&2; exit 1; }

ETCD_COMMAND="set -eu; endpoints='192.168.34.31 192.168.34.32 192.168.34.33'; cert='/etc/ssl/etcd/ssl/node-${ETCD_OBSERVER}.pem'; key='/etc/ssl/etcd/ssl/node-${ETCD_OBSERVER}-key.pem'; member_json=\$(/usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=\"\$cert\" --key=\"\$key\" member list --write-out=json); printf '%s\\n' \"\$member_json\" | jq -e '.members | length == 3' >/dev/null; healthy=0; for endpoint in \$endpoints; do if timeout 8 /usr/local/bin/etcdctl --endpoints=\"https://\$endpoint:2379\" --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=\"\$cert\" --key=\"\$key\" endpoint health; then healthy=\$((healthy + 1)); fi; done; echo \"healthy etcd endpoints=\$healthy/3 observer=${ETCD_OBSERVER}\"; test \"\$healthy\" -ge 2"
"$VENV_DIR/bin/ansible" -i "$INVENTORY" "$ETCD_OBSERVER" \
  --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell -a "$ETCD_COMMAND"
echo "[PASS] etcd retains three members and at least quorum 2/3 health"

cat <<'EOF'
[PASS] Non-destructive HA baseline is healthy.
Physical failure is intentionally manual:
  1. Take an etcd snapshot and record current evidence.
  2. Network owner confirms the peer LB is MASTER-capable.
  3. Power off PC1 or PC3, never PC2 for this scenario.
  4. Re-run this script from the DevOps VM.
  5. Expect API VIP, Service VIP and etcd quorum 2/3 to remain available.
This script never powers off a VM or stops etcd/HAProxy.
EOF

#!/usr/bin/env bash
set -Eeuo pipefail

API_VIP="192.168.34.100"
API_PORT="6443"
OLD_API_FQDN="api.k8s.neuroplan.local"
ABANDONED_API_FQDN="api.k8s.nplan.local"
CLUSTER_DOMAIN="neuroplan.local"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
INVENTORY="$SCRIPT_DIR/inventory/mycluster/hosts.yaml"
ALL_VARS="$SCRIPT_DIR/inventory/mycluster/group_vars/all/all.yml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
STATE_ROOT="${STATE_ROOT:-$HOME/.local/state/neuroplan/api-vip-endpoint}"
ANSIBLE="$VENV_DIR/bin/ansible"
ANSIBLE_INVENTORY="$VENV_DIR/bin/ansible-inventory"
LOCK_FILE="$STATE_ROOT/operation.lock"

NODES=(cp1 cp2 cp3 worker1 worker2 worker3)
CONTROL_PLANES=(cp1 cp2 cp3)
BACKUP_STAMP=""

export KUBESPRAY_DIR
export KUBECONFIG
export ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg"

pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./03-kubespray/14-pin-api-vip-endpoint.sh ACTION

  status    Read-only desired/live endpoint and health report
  apply     Back up and converge kubeadm/kubeconfigs to 192.168.34.100:6443
  verify    Read-only full verification
  rollback  Restore the most recent pre-apply files and kubeadm ConfigMap

Required confirmations:
  CONFIRM_API_VIP_ENDPOINT=apply    ... apply
  CONFIRM_API_VIP_ENDPOINT=rollback ... rollback

This tool never changes clusterDomain, CoreDNS, NodeLocal DNS, certificates,
HAProxy, Keepalived, etcd data, Pod/Service CIDRs or API VIP ownership.
EOF
}

require_base() {
  [[ ${EUID} -ne 0 && "$(id -un)" == "devops" ]] ||
    fail "run on the PC2 DevOps VM as the devops user"

  for command in kubectl jq openssl flock grep sed; do
    command -v "$command" >/dev/null || fail "required command not found: $command"
  done
  [[ -x "$ANSIBLE" ]] || fail "Ansible venv is missing: $ANSIBLE"
  [[ -x "$ANSIBLE_INVENTORY" ]] || fail "ansible-inventory is missing"
  [[ -f "$SSH_KEY" ]] || fail "SSH key is missing: $SSH_KEY"
  [[ -r "$KUBECONFIG" ]] || fail "kubeconfig is missing: $KUBECONFIG"
  [[ -f "$INVENTORY" && -f "$ALL_VARS" ]] || fail "Kubespray inventory is incomplete"

  install -d -m 0700 "$STATE_ROOT"
}

require_desired_source() {
  local cp1_vars

  if grep -Eq '^[[:space:]]*apiserver_loadbalancer_domain_name:' "$ALL_VARS"; then
    fail "remove apiserver_loadbalancer_domain_name from $ALL_VARS first"
  fi

  cp1_vars="$("$ANSIBLE_INVENTORY" -i "$INVENTORY" --host cp1)"
  [[ "$(jq -r '.loadbalancer_apiserver.address // empty' <<<"$cp1_vars")" == "$API_VIP" ]] ||
    fail "loadbalancer_apiserver.address must be $API_VIP"
  [[ "$(jq -r '.loadbalancer_apiserver.port // empty' <<<"$cp1_vars")" == "$API_PORT" ]] ||
    fail "loadbalancer_apiserver.port must be $API_PORT"
  [[ "$(jq -r '.loadbalancer_apiserver_localhost | tostring' <<<"$cp1_vars")" == "false" ]] ||
    fail "loadbalancer_apiserver_localhost must be false"
  grep -Fq -- '- 192.168.34.100' "$ALL_VARS" ||
    fail "supplementary_addresses_in_ssl_keys must explicitly document $API_VIP"

  pass "desired Kubespray source uses the fixed API VIP"
}

ensure_no_playbook() {
  if pgrep -u "$(id -u)" -af '[a]nsible-playbook' >/dev/null; then
    pgrep -u "$(id -u)" -af '[a]nsible-playbook' >&2 || true
    fail "another ansible-playbook process is running"
  fi
}

lock_mutation() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "another API endpoint operation is running"
}

require_confirmation() {
  local expected="$1"
  [[ "${CONFIRM_API_VIP_ENDPOINT:-}" == "$expected" ]] ||
    fail "set CONFIRM_API_VIP_ENDPOINT=$expected for this action"
}

check_etcd() {
  local command_text
  command_text='set -o pipefail; /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem member list --write-out=json | jq -e ".members | length == 3" >/dev/null && /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem endpoint health --cluster'

  "$ANSIBLE" -i "$INVENTORY" cp1 --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$command_text" >/dev/null
  pass "etcd has three members and all endpoints are healthy"
}

health_gate() {
  local node_json pod_json total_nodes ready_nodes api_pods ready_api_pods

  kubectl --server="https://$API_VIP:$API_PORT" \
    --request-timeout=10s get --raw='/readyz' >/dev/null

  node_json="$(kubectl get nodes -o json)"
  total_nodes="$(jq '.items | length' <<<"$node_json")"
  ready_nodes="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$node_json")"
  [[ "$total_nodes" -eq 6 && "$ready_nodes" -eq 6 ]] ||
    fail "expected six Ready nodes; total=$total_nodes ready=$ready_nodes"

  pod_json="$(kubectl -n kube-system get pods -l component=kube-apiserver -o json)"
  api_pods="$(jq '.items | length' <<<"$pod_json")"
  ready_api_pods="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$pod_json")"
  [[ "$api_pods" -eq 3 && "$ready_api_pods" -eq 3 ]] ||
    fail "expected three Ready kube-apiserver Pods; total=$api_pods ready=$ready_api_pods"

  check_etcd
  pass "API VIP, six nodes and three API Servers are healthy"
}

show_endpoints() {
  echo "===== DESIRED SOURCE ====="
  grep -nE '^(apiserver_loadbalancer_domain_name|loadbalancer_apiserver|loadbalancer_apiserver_localhost|supplementary_addresses_in_ssl_keys):|^[[:space:]]+(address|port):|^[[:space:]]+- 192\.168\.34\.100' \
    "$ALL_VARS" || true

  echo "===== LIVE KUBEADM CONFIGMAP ====="
  kubectl -n kube-system get cm kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}' |
    grep -E 'clusterName:|controlPlaneEndpoint:|dnsDomain:' || true

  echo "===== CP LOCAL KUBEADM CONFIG ====="
  "$ANSIBLE" -i "$INVENTORY" kube_control_plane --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a "grep -E '^[[:space:]]*controlPlaneEndpoint:' /etc/kubernetes/kubeadm-config.yaml" || true

  echo "===== NODE KUBECONFIG ENDPOINTS ====="
  "$ANSIBLE" -i "$INVENTORY" all --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a 'grep -HnE "^[[:space:]]*server:" /etc/kubernetes/*.conf /var/lib/kubelet/kubeconfig 2>/dev/null || true' || true

  echo "===== DEVOPS KUBECONFIG ====="
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
}

status_action() {
  require_base
  show_endpoints
  echo "===== HEALTH ====="
  health_gate
}

take_backup() {
  local local_backup remote_backup cluster_uid backup_command

  BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
  local_backup="$STATE_ROOT/$BACKUP_STAMP"
  remote_backup="/var/backups/neuroplan/api-vip-endpoint-$BACKUP_STAMP"
  install -d -m 0700 "$local_backup"

  cluster_uid="$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')"
  printf '%s\n' "$cluster_uid" >"$local_backup/cluster-uid"
  kubectl -n kube-system get cm kubeadm-config -o yaml \
    >"$local_backup/kubeadm-config.configmap.yaml"
  kubectl -n kube-system get cm kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}' \
    >"$local_backup/ClusterConfiguration.yaml"
  install -m 0600 "$KUBECONFIG" "$local_backup/devops-kubeconfig"

  if [[ -f "$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf" ]]; then
    install -m 0600 "$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf" \
      "$local_backup/artifact-admin.conf"
  fi

  find "$local_backup" -type f ! -name SHA256SUMS \
    -exec sha256sum {} + >"$local_backup/SHA256SUMS"

  backup_command="set -Eeuo pipefail; backup='$remote_backup'; install -d -m 0700 \"\$backup\"; for file in /etc/kubernetes/kubeadm-config.yaml /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/kubeadm-client.conf /var/lib/kubelet/kubeconfig; do test -f \"\$file\" || continue; cp -a --parents \"\$file\" \"\$backup\"; done; find \"\$backup\" -type f ! -name SHA256SUMS -exec sha256sum {} + >\"\$backup/SHA256SUMS\"; test -s \"\$backup/SHA256SUMS\""
  "$ANSIBLE" -i "$INVENTORY" all --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$backup_command" >/dev/null

  printf '%s\n' "$BACKUP_STAMP" >"$STATE_ROOT/LATEST"
  chmod 0600 "$STATE_ROOT/LATEST"
  pass "backup completed: local=$local_backup remote=$remote_backup"
}

install_rollback_alias() {
  "$ANSIBLE" -i "$INVENTORY" all --private-key "$SSH_KEY" -b \
    -m ansible.builtin.blockinfile \
    -a "{\"path\":\"/etc/hosts\",\"marker\":\"# {mark} NEUROPLAN API ENDPOINT ROLLBACK\",\"block\":\"$API_VIP $OLD_API_FQDN\",\"state\":\"present\",\"create\":false,\"backup\":true}" >/dev/null
  pass "temporary rollback name is pinned on all six nodes"
}

render_cp_kubeadm_configs() {
  local command_text
  command_text="set -Eeuo pipefail; file=/etc/kubernetes/kubeadm-config.yaml; sed -i -e 's#$OLD_API_FQDN:$API_PORT#$API_VIP:$API_PORT#g' -e 's#$ABANDONED_API_FQDN:$API_PORT#$API_VIP:$API_PORT#g' \"\$file\"; grep -Eq '^[[:space:]]*controlPlaneEndpoint:[[:space:]]+\"?$API_VIP:$API_PORT\"?[[:space:]]*$' \"\$file\"; /usr/local/bin/kubeadm config validate --config \"\$file\""

  "$ANSIBLE" -i "$INVENTORY" kube_control_plane \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$command_text" >/dev/null
  pass "all CP kubeadm configuration files validate with the VIP endpoint"
}

upload_cluster_configuration() {
  local command_text
  command_text="set -Eeuo pipefail; /usr/local/bin/kubeadm config validate --config /etc/kubernetes/kubeadm-config.yaml; /usr/local/bin/kubeadm init phase upload-config kubeadm --config=/etc/kubernetes/kubeadm-config.yaml"
  "$ANSIBLE" -i "$INVENTORY" cp1 --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$command_text" >/dev/null
  pass "CP1 uploaded the validated ClusterConfiguration"
}

wait_for_node_recovery() {
  local node="$1" before_lease="$2" attempt after_lease ready

  for attempt in {1..90}; do
    after_lease="$(kubectl -n kube-node-lease get lease "$node" \
      -o jsonpath='{.spec.renewTime}' 2>/dev/null || true)"
    ready="$(kubectl get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ -n "$after_lease" && "$after_lease" != "$before_lease" && "$ready" == "True" ]]; then
      pass "$node renewed its Lease and is Ready"
      return 0
    fi
    sleep 2
  done
  fail "$node did not recover after kubelet endpoint reconciliation"
}

reconcile_node_kubeconfigs() {
  local node before_lease result command_text

  command_text="set -Eeuo pipefail; restart=0; changed=0; for file in /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/kubeadm-client.conf /var/lib/kubelet/kubeconfig; do test -f \"\$file\" || continue; if grep -Eq 'https://($OLD_API_FQDN|$ABANDONED_API_FQDN):$API_PORT' \"\$file\"; then sed -i -e 's#https://$OLD_API_FQDN:$API_PORT#https://$API_VIP:$API_PORT#g' -e 's#https://$ABANDONED_API_FQDN:$API_PORT#https://$API_VIP:$API_PORT#g' \"\$file\"; changed=1; case \"\$file\" in /etc/kubernetes/kubelet.conf|/var/lib/kubelet/kubeconfig) restart=1 ;; esac; fi; done; if test \"\$restart\" -eq 1; then systemctl restart kubelet; fi; printf 'CHANGED=%s RESTART=%s\\n' \"\$changed\" \"\$restart\""

  for node in "${NODES[@]}"; do
    before_lease="$(kubectl -n kube-node-lease get lease "$node" \
      -o jsonpath='{.spec.renewTime}')"
    result="$("$ANSIBLE" -i "$INVENTORY" "$node" \
      --private-key "$SSH_KEY" -b \
      -m ansible.builtin.shell -a "$command_text")"
    if grep -Fq 'RESTART=1' <<<"$result"; then
      wait_for_node_recovery "$node" "$before_lease"
    else
      [[ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] ||
        fail "$node is not Ready"
      info "$node kubelet endpoint did not require a restart"
    fi
  done
}

set_local_kubeconfig_endpoint() {
  local file="$1" cluster_name
  [[ -f "$file" ]] || return 0
  cluster_name="$(KUBECONFIG="$file" kubectl config view --minify \
    -o jsonpath='{.contexts[0].context.cluster}')"
  [[ -n "$cluster_name" ]] || fail "cannot determine cluster name in $file"
  KUBECONFIG="$file" kubectl config set-cluster "$cluster_name" \
    --server="https://$API_VIP:$API_PORT" >/dev/null
}

verify_action() {
  local cluster_configuration cert kubeconfig_check
  require_base
  require_desired_source
  health_gate

  cluster_configuration="$(kubectl -n kube-system get cm kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}')"
  grep -Eq "controlPlaneEndpoint:[[:space:]]+\"?$API_VIP:$API_PORT\"?" \
    <<<"$cluster_configuration" || fail "kubeadm ConfigMap does not use the VIP endpoint"
  grep -Fq "clusterName: $CLUSTER_DOMAIN" <<<"$cluster_configuration" ||
    fail "clusterName changed unexpectedly"
  grep -Fq "dnsDomain: $CLUSTER_DOMAIN" <<<"$cluster_configuration" ||
    fail "dnsDomain changed unexpectedly"

  "$ANSIBLE" -i "$INVENTORY" kube_control_plane --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a "grep -Eq '^[[:space:]]*controlPlaneEndpoint:[[:space:]]+\"?$API_VIP:$API_PORT\"?[[:space:]]*\$' /etc/kubernetes/kubeadm-config.yaml" >/dev/null

  kubeconfig_check="set -Eeuo pipefail; found=0; for file in /etc/kubernetes/*.conf /var/lib/kubelet/kubeconfig; do test -f \"\$file\" || continue; found=1; if grep -Eq 'server:[[:space:]]+https://($OLD_API_FQDN|$ABANDONED_API_FQDN):$API_PORT' \"\$file\"; then echo \"forbidden endpoint remains: \$file\" >&2; exit 1; fi; done; test \"\$found\" -eq 1; grep -Eq 'server:[[:space:]]+https://$API_VIP:$API_PORT' /etc/kubernetes/kubelet.conf"
  "$ANSIBLE" -i "$INVENTORY" all --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$kubeconfig_check" >/dev/null

  [[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == \
      "https://$API_VIP:$API_PORT" ]] || fail "DevOps kubeconfig does not use the VIP"

  if [[ -f "$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf" ]]; then
    [[ "$(KUBECONFIG="$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf" \
      kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == \
      "https://$API_VIP:$API_PORT" ]] || fail "artifact admin.conf does not use the VIP"
  fi

  cert="$(openssl s_client -connect "$API_VIP:$API_PORT" </dev/null 2>/dev/null | openssl x509)"
  openssl x509 -noout -checkip "$API_VIP" <<<"$cert" >/dev/null ||
    fail "API certificate does not contain the VIP SAN"

  pass "ConfigMap, CP files, kubeconfigs, certificate and cluster health use the API VIP"
}

apply_action() {
  local artifact
  require_base
  require_confirmation apply
  lock_mutation
  ensure_no_playbook
  require_desired_source
  health_gate
  take_backup
  install_rollback_alias
  render_cp_kubeadm_configs
  upload_cluster_configuration
  reconcile_node_kubeconfigs
  set_local_kubeconfig_endpoint "$KUBECONFIG"
  artifact="$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf"
  set_local_kubeconfig_endpoint "$artifact"
  verify_action
  pass "canonical API endpoint converged to https://$API_VIP:$API_PORT"
  info "backup stamp: $BACKUP_STAMP"
}

restore_remote_files() {
  local stamp="$1" remote_backup command_text node before_lease
  remote_backup="/var/backups/neuroplan/api-vip-endpoint-$stamp"
  command_text="set -Eeuo pipefail; backup='$remote_backup'; test -s \"\$backup/SHA256SUMS\"; sha256sum -c \"\$backup/SHA256SUMS\" >/dev/null; for file in /etc/kubernetes/kubeadm-config.yaml /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/kubeadm-client.conf /var/lib/kubelet/kubeconfig; do source=\"\$backup\$file\"; test -f \"\$source\" || continue; cp -a \"\$source\" \"\$file\"; done; systemctl restart kubelet"

  for node in "${NODES[@]}"; do
    before_lease="$(kubectl -n kube-node-lease get lease "$node" \
      -o jsonpath='{.spec.renewTime}')"
    "$ANSIBLE" -i "$INVENTORY" "$node" --private-key "$SSH_KEY" -b \
      -m ansible.builtin.shell -a "$command_text" >/dev/null
    wait_for_node_recovery "$node" "$before_lease"
  done
}

rollback_action() {
  local stamp local_backup current_uid saved_uid artifact
  require_base
  require_confirmation rollback
  lock_mutation
  ensure_no_playbook
  [[ -s "$STATE_ROOT/LATEST" ]] || fail "no backup marker exists"
  stamp="$(<"$STATE_ROOT/LATEST")"
  local_backup="$STATE_ROOT/$stamp"
  [[ -d "$local_backup" ]] || fail "local backup is missing: $local_backup"

  current_uid="$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')"
  saved_uid="$(<"$local_backup/cluster-uid")"
  [[ "$current_uid" == "$saved_uid" ]] || fail "backup belongs to a different cluster"

  install_rollback_alias
  restore_remote_files "$stamp"
  upload_cluster_configuration
  install -m 0600 "$local_backup/devops-kubeconfig" "$KUBECONFIG"
  artifact="$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf"
  if [[ -f "$local_backup/artifact-admin.conf" ]]; then
    install -m 0600 "$local_backup/artifact-admin.conf" "$artifact"
  fi
  health_gate
  pass "latest endpoint backup restored: $stamp"
  info "desired inventory still targets the VIP; use apply to converge again"
}

case "${1:-}" in
  status) status_action ;;
  apply) apply_action ;;
  verify) verify_action ;;
  rollback) rollback_action ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac

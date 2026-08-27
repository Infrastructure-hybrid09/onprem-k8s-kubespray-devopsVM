#!/usr/bin/env bash
set -Eeuo pipefail

OLD_API_FQDN="api.k8s.neuroplan.local"
NEW_API_FQDN="api.k8s.nplan.local"
API_VIP="192.168.34.100"
DNS_SERVER="192.168.14.62"
CLUSTER_DOMAIN="neuroplan.local"
SERVICE_ACCOUNT_ISSUER="https://kubernetes.default.svc.neuroplan.local"

if [[ "${ENABLE_API_FQDN_MIGRATION:-}" != "PROJECT_CHANGE_APPROVED" ]]; then
  printf '%s\n' \
    '[BLOCKED] API FQDN migration is retired by the project operating decision.' \
    'Canonical endpoint : https://192.168.34.100:6443' \
    'Use 14-pin-api-vip-endpoint.sh to converge legacy endpoint references.' \
    'Cluster DNS domain  : neuroplan.local' \
    '' \
    'Use 10-preflight.sh and 23-verify-cluster.sh for normal validation.' \
    'Do not enable this tool without a newly approved maintenance and rollback plan.' >&2
  exit 64
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
KUBE_INVENTORY="$SCRIPT_DIR/inventory/mycluster/hosts.yaml"
BASELINE_INVENTORY="$PROJECT_ROOT/02-ansible/inventory/hosts.yaml"
ALL_VARS="$SCRIPT_DIR/inventory/mycluster/group_vars/all/all.yml"
CLUSTER_VARS="$SCRIPT_DIR/inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
LOG_ROOT="${LOG_ROOT:-$PROJECT_ROOT/logs/api-fqdn-migration}"
STATE_ROOT="${STATE_ROOT:-$HOME/.local/state/neuroplan/api-fqdn-migration}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ANSIBLE="$VENV_DIR/bin/ansible"
ANSIBLE_INVENTORY="$VENV_DIR/bin/ansible-inventory"
PLAYBOOK="$VENV_DIR/bin/ansible-playbook"

declare -A CONTROL_PLANE_IPS=(
  [cp1]="192.168.34.31"
  [cp2]="192.168.34.32"
  [cp3]="192.168.34.33"
)
NODES=(cp1 cp2 cp3 worker1 worker2 worker3)
TEMP_PATHS=()

cleanup() {
  local temporary
  for temporary in "${TEMP_PATHS[@]}"; do
    [[ -e "$temporary" ]] && rm -f -- "$temporary"
  done
}
trap cleanup EXIT

export KUBESPRAY_DIR
export KUBECONFIG
export ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg"

pass() { printf '[PASS] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./03-kubespray/13-migrate-api-fqdn.sh ACTION

Read-only actions:
  status       Show BIND, hosts, kubeconfig, cluster-domain and certificate state.
  precheck     Require new DNS, dual-name bridge, healthy cluster/etcd and invariants.
  verify       Require the completed new endpoint while preserving rollback invariants.

Mutating actions (run only in the documented order):
  bridge       Add a marked dual-name VIP block to DevOps and all six node hosts files.
  backup       Take etcd, root-only node configuration and DevOps kubeconfig backups.
  roll-certs   Regenerate/verify API certificates one CP at a time with both FQDN SANs.
  converge     Run full Kubespray convergence and switch active kubeconfig endpoints.
  rollback     Emergency endpoint rollback to the legacy FQDN; certificates stay dual-SAN.

Required confirmations:
  CONFIRM_API_FQDN=bridge      ... bridge
  CONFIRM_API_FQDN=backup      ... backup
  CONFIRM_API_FQDN=roll-certs  ... roll-certs
  CONFIRM_API_FQDN=converge    ... converge
  CONFIRM_API_FQDN=rollback    ... rollback

This script NEVER changes cluster_name, dnsDomain, CoreDNS, NodeLocal DNS, the
ServiceAccount issuer, etcd data, HAProxy backends or either VIP address.
EOF
}

require_devops() {
  [[ ${EUID} -ne 0 && "$(id -un)" == "devops" ]] ||
    fail "run on the PC2 DevOps VM as the devops user"
}

require_tools() {
  local command_name
  for command_name in kubectl jq dig openssl curl grep sed awk timeout flock \
      pgrep paste install tar sha256sum; do
    command -v "$command_name" >/dev/null ||
      fail "required command not found: $command_name"
  done

  [[ -x "$ANSIBLE" ]] || fail "Ansible is missing: $ANSIBLE"
  [[ -x "$ANSIBLE_INVENTORY" ]] ||
    fail "ansible-inventory is missing: $ANSIBLE_INVENTORY"
  [[ -x "$PLAYBOOK" ]] || fail "ansible-playbook is missing: $PLAYBOOK"
  [[ -f "$SSH_KEY" ]] || fail "SSH key is missing: $SSH_KEY"
  [[ -d "$KUBESPRAY_DIR/.git" ]] ||
    fail "Kubespray vendor is missing; run 03-kubespray/02-install-kubespray.sh"
  [[ -r "$KUBECONFIG" ]] || fail "kubeconfig is missing: $KUBECONFIG"
}

require_base() {
  require_devops
  require_tools
}

require_confirmation() {
  local expected="$1"
  [[ "${CONFIRM_API_FQDN:-}" == "$expected" ]] ||
    fail "set CONFIRM_API_FQDN=$expected for this mutating action"
}

lock_mutation() {
  install -d -m 0700 "$STATE_ROOT"
  exec 9>"$STATE_ROOT/migration.lock"
  flock -n 9 || fail "another API FQDN migration action is already running"
}

check_new_dns() {
  local -a answers=()
  mapfile -t answers < <(
    dig @"$DNS_SERVER" "$NEW_API_FQDN" A +short |
      sed '/^[[:space:]]*$/d'
  )

  if [[ ${#answers[@]} -ne 1 || "${answers[0]}" != "$API_VIP" ]]; then
    printf 'Infra DNS answer for %s: %s\n' \
      "$NEW_API_FQDN" "${answers[*]:-no answer}" >&2
    fail "$NEW_API_FQDN must resolve only to $API_VIP from $DNS_SERVER"
  fi
  pass "Infra DNS $NEW_API_FQDN -> $API_VIP"
}

check_source_invariants() {
  local effective_inventory effective_cluster_domain effective_dns_domain
  local effective_issuer

  grep -Fxq "apiserver_loadbalancer_domain_name: $NEW_API_FQDN" "$ALL_VARS" ||
    fail "inventory endpoint must be $NEW_API_FQDN"
  grep -Fxq "  - $NEW_API_FQDN" "$ALL_VARS" ||
    fail "new API FQDN is missing from certificate SAN source"
  grep -Fxq "  - $OLD_API_FQDN" "$ALL_VARS" ||
    fail "legacy API FQDN must remain in certificate SAN source"
  grep -Fxq "  - $API_VIP" "$ALL_VARS" ||
    fail "API VIP is missing from certificate SAN source"
  grep -Fxq "cluster_name: $CLUSTER_DOMAIN" "$CLUSTER_VARS" ||
    fail "cluster_name must remain $CLUSTER_DOMAIN"

  effective_inventory="$("$ANSIBLE_INVENTORY" \
    -i "$KUBE_INVENTORY" --host cp1)"
  effective_cluster_domain="$(jq -r '.cluster_name // empty' \
    <<<"$effective_inventory")"
  effective_dns_domain="$(jq -r '.dns_domain // .cluster_name // empty' \
    <<<"$effective_inventory")"
  effective_issuer="$(jq -r '.kube_service_account_issuer // empty' \
    <<<"$effective_inventory")"
  [[ "$effective_cluster_domain" == "$CLUSTER_DOMAIN" ]] ||
    fail "effective cluster_name=$effective_cluster_domain; expected $CLUSTER_DOMAIN"
  [[ "$effective_dns_domain" == "$CLUSTER_DOMAIN" ]] ||
    fail "effective dns_domain=$effective_dns_domain; expected $CLUSTER_DOMAIN"
  if [[ -n "$effective_issuer" &&
        "$effective_issuer" != "$SERVICE_ACCOUNT_ISSUER" ]]; then
    fail "effective ServiceAccount issuer changed to $effective_issuer"
  fi
  pass "desired source keeps cluster DNS separate and both API SANs"
}

verify_dual_hosts() {
  local remote_check
  remote_check="set -eu; new=\$(getent ahostsv4 $NEW_API_FQDN | awk 'NR == 1 {print \$1}'); old=\$(getent ahostsv4 $OLD_API_FQDN | awk 'NR == 1 {print \$1}'); test \"\$new\" = '$API_VIP'; test \"\$old\" = '$API_VIP'"

  [[ "$(getent ahostsv4 "$NEW_API_FQDN" | awk 'NR == 1 {print $1}')" == "$API_VIP" ]] ||
    fail "DevOps does not resolve $NEW_API_FQDN to $API_VIP"
  [[ "$(getent ahostsv4 "$OLD_API_FQDN" | awk 'NR == 1 {print $1}')" == "$API_VIP" ]] ||
    fail "DevOps does not resolve $OLD_API_FQDN to $API_VIP"

  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" \
    -m ansible.builtin.shell -a "$remote_check" >/dev/null
  pass "DevOps and all six nodes resolve both API names to $API_VIP"
}

verify_legacy_hosts() {
  local remote_check
  remote_check="set -eu; old=\$(getent ahostsv4 $OLD_API_FQDN | awk 'NR == 1 {print \$1}'); test \"\$old\" = '$API_VIP'"

  [[ "$(getent ahostsv4 "$OLD_API_FQDN" | awk 'NR == 1 {print $1}')" == "$API_VIP" ]] ||
    fail "DevOps does not resolve rollback name $OLD_API_FQDN to $API_VIP"

  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" \
    -m ansible.builtin.shell -a "$remote_check" >/dev/null
  pass "DevOps and all six nodes resolve rollback name $OLD_API_FQDN to $API_VIP"
}

check_cluster_ready() {
  local ready_count total_count
  kubectl --server="https://$API_VIP:6443" \
    --request-timeout=10s get --raw='/readyz' >/dev/null

  total_count="$(kubectl get nodes -o json | jq '.items | length')"
  ready_count="$(
    kubectl get nodes -o json |
      jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
  )"
  [[ "$total_count" -eq 6 && "$ready_count" -eq 6 ]] ||
    fail "expected six Ready nodes; total=$total_count ready=$ready_count"
  pass "API VIP and all six nodes are Ready"
}

check_api_backends() {
  local node ip
  for node in cp1 cp2 cp3; do
    ip="${CONTROL_PLANE_IPS[$node]}"
    kubectl --server="https://$ip:6443" \
      --request-timeout=10s get --raw='/readyz' >/dev/null ||
      fail "$node API backend $ip:6443 is not Ready"
  done
  pass "all three API backends are Ready"
}

check_etcd() {
  local etcd_command
  etcd_command='set -o pipefail; /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem member list --write-out=json | jq -e ".members | length == 3" >/dev/null && /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem endpoint health --cluster'

  "$ANSIBLE" -i "$KUBE_INVENTORY" cp1 \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$etcd_command" >/dev/null
  pass "etcd has three members and all endpoints are healthy"
}

check_live_invariants() {
  local kubelet_check issuer_check coredns_corefile nodelocal_corefile
  kubelet_check="grep -Fxq 'clusterDomain: $CLUSTER_DOMAIN' /var/lib/kubelet/config.yaml"
  issuer_check="grep -Fq -- '--service-account-issuer=$SERVICE_ACCOUNT_ISSUER' /etc/kubernetes/manifests/kube-apiserver.yaml"

  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$kubelet_check" >/dev/null
  "$ANSIBLE" -i "$KUBE_INVENTORY" kube_control_plane \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$issuer_check" >/dev/null

  coredns_corefile="$(
    kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
  )"
  nodelocal_corefile="$(
    kubectl -n kube-system get cm nodelocaldns -o jsonpath='{.data.Corefile}'
  )"
  grep -Fq "kubernetes $CLUSTER_DOMAIN " <<<"$coredns_corefile" ||
    fail "CoreDNS no longer owns the expected cluster domain"
  grep -Fq "$CLUSTER_DOMAIN:53" <<<"$nodelocal_corefile" ||
    fail "NodeLocal DNS no longer forwards the expected cluster domain"
  pass "clusterDomain, CoreDNS, NodeLocal DNS and ServiceAccount issuer are unchanged"
}

check_pki_material() {
  local pki_check
  pki_check='set -Eeuo pipefail
test -s /etc/kubernetes/ssl/ca.crt
test -s /etc/kubernetes/ssl/ca.key
test -s /etc/kubernetes/ssl/apiserver.crt
test -s /etc/kubernetes/ssl/apiserver.key
openssl pkey -in /etc/kubernetes/ssl/ca.key -check -noout >/dev/null
ca_key_hash="$(openssl pkey -in /etc/kubernetes/ssl/ca.key -pubout -outform DER 2>/dev/null | sha256sum | awk "{print \$1}")"
ca_crt_hash="$(openssl x509 -in /etc/kubernetes/ssl/ca.crt -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk "{print \$1}")"
test -n "$ca_key_hash"
test "$ca_key_hash" = "$ca_crt_hash"
openssl verify -CAfile /etc/kubernetes/ssl/ca.crt /etc/kubernetes/ssl/apiserver.crt >/dev/null'

  "$ANSIBLE" -i "$KUBE_INVENTORY" kube_control_plane \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$pki_check" >/dev/null
  pass "all three CPs have a valid CA key pair and signed API certificate"
}

current_cluster_uid() {
  kubectl get namespace kube-system -o jsonpath='{.metadata.uid}'
}

current_ca_sha256() {
  kubectl -n kube-system get configmap kube-root-ca.crt \
    -o jsonpath='{.data.ca\.crt}' |
    openssl x509 -outform DER |
    sha256sum |
    awk '{print $1}'
}

live_cert_has_host() {
  local ip="$1" hostname="$2"
  timeout 10 openssl s_client \
    -connect "$ip:6443" -servername "$hostname" </dev/null 2>/dev/null |
    openssl x509 -noout -checkhost "$hostname" >/dev/null 2>&1
}

live_cert_has_ip() {
  local ip="$1"
  timeout 10 openssl s_client \
    -connect "$ip:6443" -servername "$NEW_API_FQDN" </dev/null 2>/dev/null |
    openssl x509 -noout -checkip "$API_VIP" >/dev/null 2>&1
}

check_dual_cert_on_node() {
  local node="$1" ip="${CONTROL_PLANE_IPS[$1]}" cert_check
  cert_check="set -eu; openssl x509 -noout -in /etc/kubernetes/ssl/apiserver.crt -checkhost '$NEW_API_FQDN' >/dev/null; openssl x509 -noout -in /etc/kubernetes/ssl/apiserver.crt -checkhost '$OLD_API_FQDN' >/dev/null; openssl x509 -noout -in /etc/kubernetes/ssl/apiserver.crt -checkip '$API_VIP' >/dev/null"

  "$ANSIBLE" -i "$KUBE_INVENTORY" "$node" \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$cert_check" >/dev/null
  live_cert_has_host "$ip" "$NEW_API_FQDN" ||
    fail "$node live API certificate lacks $NEW_API_FQDN"
  live_cert_has_host "$ip" "$OLD_API_FQDN" ||
    fail "$node live API certificate lacks rollback SAN $OLD_API_FQDN"
  live_cert_has_ip "$ip" || fail "$node live API certificate lacks VIP SAN $API_VIP"
}

wait_for_new_live_cert() {
  local node="$1" ip="${CONTROL_PLANE_IPS[$1]}" attempt
  for attempt in {1..60}; do
    if live_cert_has_host "$ip" "$NEW_API_FQDN"; then
      return 0
    fi
    sleep 2
  done

  info "$node certificate file changed but the running API still serves the old certificate"
  info "rechecking all API backends, six nodes and etcd before a single-CP restart"
  check_api_backends
  check_cluster_ready
  check_etcd
  info "restarting only the $node kube-apiserver container; the other two APIs stay online"
  "$ANSIBLE" -i "$KUBE_INVENTORY" "$node" \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a 'set -eu; id=$(/usr/local/bin/crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name kube-apiserver -q | head -n 1); test -n "$id"; /usr/local/bin/crictl --runtime-endpoint unix:///run/containerd/containerd.sock stop "$id"' >/dev/null

  for attempt in {1..90}; do
    if kubectl --server="https://$ip:6443" \
         --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1 &&
       live_cert_has_host "$ip" "$NEW_API_FQDN"; then
      return 0
    fi
    sleep 2
  done
  fail "$node API did not recover with the new certificate; stop the migration"
}

ensure_no_playbook() {
  if pgrep -u "$(id -u)" -af '[a]nsible-playbook' >/dev/null; then
    pgrep -u "$(id -u)" -af '[a]nsible-playbook' >&2 || true
    fail "another ansible-playbook process is running"
  fi
}

status_action() {
  require_base
  echo "===== DESIRED SOURCE ====="
  grep -nE '^(apiserver_loadbalancer_domain_name|cluster_name|dns_domain):|^[[:space:]]+- api\.k8s\.' \
    "$ALL_VARS" "$CLUSTER_VARS" || true

  echo "===== INFRA BIND ====="
  printf '%s -> ' "$NEW_API_FQDN"
  dig @"$DNS_SERVER" "$NEW_API_FQDN" A +short | paste -sd, -
  printf '%s -> ' "$OLD_API_FQDN"
  dig @"$DNS_SERVER" "$OLD_API_FQDN" A +short | paste -sd, -

  echo "===== DEVOPS RESOLUTION / KUBECONFIG ====="
  getent ahostsv4 "$NEW_API_FQDN" | head -n 1 || true
  getent ahostsv4 "$OLD_API_FQDN" | head -n 1 || true
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'

  echo "===== NODE RESOLUTION ====="
  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a "printf 'new='; getent ahostsv4 $NEW_API_FQDN | awk 'NR == 1 {print \$1}'; printf 'old='; getent ahostsv4 $OLD_API_FQDN | awk 'NR == 1 {print \$1}'" || true

  echo "===== LIVE INVARIANTS ====="
  kubectl -n kube-system get cm kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null |
    grep -E 'clusterName:|controlPlaneEndpoint:|dnsDomain:' || true
  kubectl -n kube-system get cm coredns \
    -o jsonpath='{.data.Corefile}' 2>/dev/null |
    grep -E 'kubernetes (neuroplan|nplan)\.local' || true

  echo "===== API CERTIFICATE FILES ====="
  "$ANSIBLE" -i "$KUBE_INVENTORY" kube_control_plane \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell \
    -a 'openssl x509 -noout -subject -dates -ext subjectAltName -in /etc/kubernetes/ssl/apiserver.crt' || true
}

bridge_action() {
  require_base
  require_confirmation bridge
  lock_mutation
  ensure_no_playbook
  check_new_dns
  sudo -v

  "$ANSIBLE" -i "$BASELINE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.blockinfile \
    -a "{\"path\":\"/etc/hosts\",\"marker\":\"# {mark} NEUROPLAN API FQDN BRIDGE\",\"block\":\"$API_VIP $NEW_API_FQDN $OLD_API_FQDN\",\"state\":\"present\",\"create\":false,\"backup\":true}"
  verify_dual_hosts
  pass "dual API name bridge block installed with per-host Ansible backups"
}

precheck_action() {
  local node ip
  require_base
  ensure_no_playbook
  check_source_invariants
  check_new_dns
  verify_dual_hosts
  "$SCRIPT_DIR/03-verify-release.sh"
  check_cluster_ready
  check_api_backends
  check_etcd
  check_live_invariants
  check_pki_material
  for node in cp1 cp2 cp3; do
    ip="${CONTROL_PLANE_IPS[$node]}"
    live_cert_has_host "$ip" "$OLD_API_FQDN" ||
      fail "$node current certificate lacks rollback FQDN $OLD_API_FQDN"
    live_cert_has_ip "$ip" || fail "$node current certificate lacks VIP $API_VIP"
  done
  pass "current API certificates contain the VIP and legacy rollback FQDN"
  pass "API FQDN migration precheck completed"
}

backup_action() {
  local stamp local_dir remote_dir archive_command metadata_temp
  local cluster_uid ca_sha256
  require_base
  require_confirmation backup
  lock_mutation
  precheck_action

  stamp="$(date +%Y%m%d-%H%M%S)"
  local_dir="$STATE_ROOT/backups/$stamp"
  remote_dir="/var/backups/neuroplan/api-fqdn-$stamp"
  install -d -m 0700 "$local_dir" "$LOG_ROOT"

  install -m 0600 "$KUBECONFIG" "$local_dir/devops-kubeconfig.before"
  install -m 0600 "$ALL_VARS" "$local_dir/all.yml.before"
  install -m 0600 "$CLUSTER_VARS" "$local_dir/k8s-cluster.yml.before"
  kubectl -n kube-system get cm kubeadm-config -o yaml \
    >"$local_dir/kubeadm-configmap.before.yaml"
  kubectl -n kube-public get cm cluster-info -o yaml \
    >"$local_dir/cluster-info.before.yaml"
  kubectl get nodes -o yaml >"$local_dir/nodes.before.yaml"
  chmod 0600 "$local_dir"/*

  "$PROJECT_ROOT/07-troubleshooting/33-etcd-snapshot.sh"

  archive_command="set -eu; umask 077; install -d -m 0700 '$remote_dir'; tar --acls --xattrs --selinux -C / -czf '$remote_dir/etc-kubernetes-kubelet-hosts.tgz' etc/kubernetes var/lib/kubelet/config.yaml etc/hosts; sha256sum '$remote_dir/etc-kubernetes-kubelet-hosts.tgz' >'$remote_dir/etc-kubernetes-kubelet-hosts.tgz.sha256'; chmod 0600 '$remote_dir/etc-kubernetes-kubelet-hosts.tgz' '$remote_dir/etc-kubernetes-kubelet-hosts.tgz.sha256'"
  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$archive_command"

  cluster_uid="$(current_cluster_uid)"
  ca_sha256="$(current_ca_sha256)"
  [[ -n "$cluster_uid" && -n "$ca_sha256" ]] ||
    fail "could not record the cluster identity for this backup"
  metadata_temp="$(mktemp "$STATE_ROOT/.current-backup.XXXXXX")"
  TEMP_PATHS+=("$metadata_temp")
  jq -n \
    --arg backup_id "$stamp" \
    --arg cluster_uid "$cluster_uid" \
    --arg ca_sha256 "$ca_sha256" \
    '{backup_id:$backup_id,cluster_uid:$cluster_uid,ca_sha256:$ca_sha256}' \
    >"$metadata_temp"
  chmod 0600 "$metadata_temp"
  mv -f -- "$metadata_temp" "$STATE_ROOT/current-backup.json"

  printf '%s\n' "$stamp" >"$STATE_ROOT/current-backup-id"
  chmod 0600 "$STATE_ROOT/current-backup-id"
  pass "backup ID=$stamp"
  info "DevOps credential backup: $local_dir (mode 0700, outside the repository)"
  info "node credential archives: $remote_dir (root-only, not fetched)"
}

require_backup() {
  local metadata backup_id saved_cluster_uid saved_ca_sha256
  local remote_dir local_dir remote_check

  metadata="$STATE_ROOT/current-backup.json"
  [[ -s "$metadata" ]] ||
    fail "run the backup action successfully for this migration"
  jq -e '
    (.backup_id | type == "string" and length > 0) and
    (.cluster_uid | type == "string" and length > 0) and
    (.ca_sha256 | type == "string" and length == 64)
  ' "$metadata" >/dev/null || fail "backup metadata is invalid: $metadata"

  backup_id="$(jq -r '.backup_id' "$metadata")"
  saved_cluster_uid="$(jq -r '.cluster_uid' "$metadata")"
  saved_ca_sha256="$(jq -r '.ca_sha256' "$metadata")"
  [[ "$(current_cluster_uid)" == "$saved_cluster_uid" ]] ||
    fail "backup belongs to a different Kubernetes cluster UID"
  [[ "$(current_ca_sha256)" == "$saved_ca_sha256" ]] ||
    fail "backup CA fingerprint does not match the current cluster"

  local_dir="$STATE_ROOT/backups/$backup_id"
  [[ -s "$local_dir/devops-kubeconfig.before" &&
     -s "$local_dir/kubeadm-configmap.before.yaml" ]] ||
    fail "local backup files are incomplete: $local_dir"

  remote_dir="/var/backups/neuroplan/api-fqdn-$backup_id"
  remote_check="set -eu; cd '$remote_dir'; test -s etc-kubernetes-kubelet-hosts.tgz; test -s etc-kubernetes-kubelet-hosts.tgz.sha256; sha256sum -c etc-kubernetes-kubelet-hosts.tgz.sha256"
  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$remote_check" >/dev/null ||
    fail "one or more node backup archives are missing or corrupt"
  info "using verified backup ID=$backup_id"
}

roll_certs_action() {
  local node ip log_file endpoint_check
  require_base
  require_confirmation roll-certs
  lock_mutation
  precheck_action
  require_backup
  install -d -m 0750 "$LOG_ROOT"

  # Limited Kubespray runs still render SANs from all CP facts. Refresh the
  # jsonfile fact cache first so a clean/stale /tmp cache cannot omit a CP.
  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" \
    -m ansible.builtin.setup >/dev/null
  pass "refreshed cached facts for all six nodes"

  for node in cp1 cp2 cp3; do
    ip="${CONTROL_PLANE_IPS[$node]}"
    log_file="$LOG_ROOT/roll-$node-$(date +%Y%m%d-%H%M%S).log"
    echo "===== ROLLING $node ($ip) ====="
    check_cluster_ready
    check_etcd

    "$PLAYBOOK" -i "$KUBE_INVENTORY" \
      "$KUBESPRAY_DIR/cluster.yml" \
      -b -v --private-key "$SSH_KEY" --limit "$node" \
      --extra-vars "apiserver_loadbalancer_domain_name=$OLD_API_FQDN" 2>&1 |
      tee "$log_file"

    endpoint_check="grep -Eq '^[[:space:]]*controlPlaneEndpoint:[[:space:]]+\"?$OLD_API_FQDN:6443\"?[[:space:]]*$' /etc/kubernetes/kubeadm-config.yaml"
    "$ANSIBLE" -i "$KUBE_INVENTORY" "$node" \
      --private-key "$SSH_KEY" -b \
      -m ansible.builtin.shell -a "$endpoint_check" >/dev/null ||
      fail "$node endpoint changed during the certificate-only stage"
    wait_for_new_live_cert "$node"
    check_dual_cert_on_node "$node"
    check_cluster_ready
    check_etcd
    pass "$node serves the VIP, new FQDN and legacy rollback SANs"
  done
  pass "all three API certificates were migrated serially"
}

rewrite_node_endpoints() {
  local from="$1" to="$2" node stamp endpoint_command
  local before_lease after_lease ready attempt recovered
  stamp="$(date +%Y%m%d-%H%M%S)"

  for node in "${NODES[@]}"; do
    info "reconciling active kubeconfigs on $node"
    before_lease="$(
      kubectl -n kube-node-lease get lease "$node" \
        -o jsonpath='{.spec.renewTime}'
    )"
    [[ -n "$before_lease" ]] || fail "cannot read the pre-change $node Lease"
    endpoint_command="set -Eeuo pipefail; restart=0; for file in /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/kubeadm-client.conf /var/lib/kubelet/kubeconfig; do test -f \"\$file\" || continue; if grep -Fq 'https://$from:6443' \"\$file\"; then cp -a -- \"\$file\" \"\$file.api-fqdn-$stamp.bak\"; sed -i 's#https://$from:6443#https://$to:6443#g' \"\$file\"; case \"\$file\" in /etc/kubernetes/kubelet.conf|/var/lib/kubelet/kubeconfig) restart=1 ;; esac; fi; done; if test \"\$restart\" -eq 1; then systemctl restart kubelet; fi; systemctl is-active --quiet kubelet"
    "$ANSIBLE" -i "$KUBE_INVENTORY" "$node" \
      --private-key "$SSH_KEY" -b \
      -m ansible.builtin.shell -a "$endpoint_command" >/dev/null

    recovered=false
    for attempt in {1..90}; do
      after_lease="$(
        kubectl -n kube-node-lease get lease "$node" \
          -o jsonpath='{.spec.renewTime}' 2>/dev/null || true
      )"
      ready="$(
        kubectl get node "$node" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
          2>/dev/null || true
      )"
      if [[ -n "$after_lease" && "$after_lease" != "$before_lease" &&
            "$ready" == "True" ]]; then
        recovered=true
        break
      fi
      sleep 2
    done
    [[ "$recovered" == true ]] ||
      fail "$node did not renew its Lease and return Ready after endpoint reconciliation"
    pass "$node kubelet renewed its Lease and is Ready"
  done
}

set_kubeconfig_server() {
  local file="$1" endpoint="$2" temporary cluster_name
  [[ -f "$file" ]] || return 0

  temporary="$(mktemp)"
  TEMP_PATHS+=("$temporary")
  install -m 0600 "$file" "$temporary"
  cluster_name="$(
    KUBECONFIG="$temporary" kubectl config view --minify \
      -o jsonpath='{.contexts[0].context.cluster}'
  )"
  [[ -n "$cluster_name" ]] || fail "cannot determine the current cluster in $file"
  KUBECONFIG="$temporary" kubectl config set-cluster "$cluster_name" \
    --server="https://$endpoint:6443" >/dev/null
  KUBECONFIG="$temporary" kubectl --request-timeout=10s \
    get --raw='/readyz' >/dev/null
  install -m 0600 "$temporary" "$file"
  rm -f -- "$temporary"
}

upload_kubeadm_config() {
  local endpoint="$1" command_text
  command_text="set -eu; (grep -Fq 'controlPlaneEndpoint: \"$endpoint:6443\"' /etc/kubernetes/kubeadm-config.yaml || grep -Fq 'controlPlaneEndpoint: $endpoint:6443' /etc/kubernetes/kubeadm-config.yaml); grep -Fq -- '--service-account-issuer=$SERVICE_ACCOUNT_ISSUER' /etc/kubernetes/manifests/kube-apiserver.yaml; /usr/local/bin/kubeadm init phase upload-config kubeadm --config=/etc/kubernetes/kubeadm-config.yaml"
  "$ANSIBLE" -i "$KUBE_INVENTORY" cp1 \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$command_text"
}

converge_action() {
  local artifact
  require_base
  require_confirmation converge
  lock_mutation
  precheck_action
  require_backup

  for node in cp1 cp2 cp3; do
    check_dual_cert_on_node "$node"
  done

  ALLOW_API_FQDN_MIGRATION_CONVERGE=1 \
    "$SCRIPT_DIR/11-deploy-cluster.sh"
  rewrite_node_endpoints "$OLD_API_FQDN" "$NEW_API_FQDN"
  upload_kubeadm_config "$NEW_API_FQDN"

  set_kubeconfig_server "$KUBECONFIG" "$NEW_API_FQDN"
  artifact="$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf"
  if [[ -f "$artifact" ]]; then
    set_kubeconfig_server "$artifact" "$NEW_API_FQDN"
  fi
  rm -f -- "$STATE_ROOT/ROLLBACK_ACTIVE"
  pass "full convergence and active endpoint switch completed"
  info "signed kube-public/cluster-info was intentionally not patched"
}

verify_active_endpoints() {
  local endpoint_check cluster_configuration
  endpoint_check="set -eu; for file in /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/kubeadm-client.conf /var/lib/kubelet/kubeconfig; do test -f \"\$file\" || continue; if grep -Fq 'https://$OLD_API_FQDN:6443' \"\$file\"; then echo \"legacy endpoint remains in \$file\" >&2; exit 1; fi; done"
  "$ANSIBLE" -i "$KUBE_INVENTORY" all \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$endpoint_check" >/dev/null

  [[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" == \
      "https://$NEW_API_FQDN:6443" ]] ||
    fail "DevOps kubeconfig does not use $NEW_API_FQDN"
  cluster_configuration="$(
    kubectl -n kube-system get cm kubeadm-config \
      -o jsonpath='{.data.ClusterConfiguration}'
  )"
  if ! grep -Fq "controlPlaneEndpoint: $NEW_API_FQDN:6443" \
       <<<"$cluster_configuration" &&
     ! grep -Fq "controlPlaneEndpoint: \"$NEW_API_FQDN:6443\"" \
       <<<"$cluster_configuration"; then
    fail "kubeadm ConfigMap does not use $NEW_API_FQDN"
  fi
  pass "active kubeconfig and kubeadm endpoints use $NEW_API_FQDN"
}

verify_action() {
  local node
  require_base
  check_source_invariants
  check_new_dns
  verify_dual_hosts
  check_cluster_ready
  check_api_backends
  check_etcd
  check_live_invariants
  verify_active_endpoints

  kubectl --server="https://$NEW_API_FQDN:6443" \
    --request-timeout=10s get --raw='/readyz' >/dev/null
  for node in cp1 cp2 cp3; do
    check_dual_cert_on_node "$node"
  done
  "$PROJECT_ROOT/06-validation/23-verify-cluster.sh"
  pass "API FQDN migration verified; legacy SAN/hosts rollback path remains"
}

rollback_action() {
  local rollback_config artifact rollback_entry_backup
  require_base
  require_confirmation rollback
  lock_mutation
  ensure_no_playbook
  install -m 0600 /dev/null "$STATE_ROOT/ROLLBACK_ACTIVE"

  # Use the IP first so the administrative client survives either DNS name change.
  rollback_entry_backup="$STATE_ROOT/kubeconfig.before-rollback.$(date +%Y%m%d-%H%M%S)"
  install -m 0600 "$KUBECONFIG" "$rollback_entry_backup"
  set_kubeconfig_server "$KUBECONFIG" "$API_VIP"
  require_backup
  verify_legacy_hosts
  rewrite_node_endpoints "$NEW_API_FQDN" "$OLD_API_FQDN"

  rollback_config="set -eu; cp -a /etc/kubernetes/kubeadm-config.yaml /etc/kubernetes/kubeadm-config.yaml.api-fqdn-rollback.bak; sed -i '/^[[:space:]]*controlPlaneEndpoint:/ s#$NEW_API_FQDN#$OLD_API_FQDN#' /etc/kubernetes/kubeadm-config.yaml"
  "$ANSIBLE" -i "$KUBE_INVENTORY" kube_control_plane \
    --private-key "$SSH_KEY" -b \
    -m ansible.builtin.shell -a "$rollback_config" >/dev/null
  upload_kubeadm_config "$OLD_API_FQDN"
  set_kubeconfig_server "$KUBECONFIG" "$OLD_API_FQDN"
  artifact="$SCRIPT_DIR/inventory/mycluster/artifacts/admin.conf"
  if [[ -f "$artifact" ]]; then
    set_kubeconfig_server "$artifact" "$OLD_API_FQDN"
  fi

  kubectl --request-timeout=10s get --raw='/readyz' >/dev/null
  check_cluster_ready
  check_etcd
  check_live_invariants
  pass "live endpoint rolled back to $OLD_API_FQDN; dual-SAN certificates were retained"
  info "repository desired state still targets $NEW_API_FQDN; do not run 11-deploy-cluster.sh"
  info "ROLLBACK_ACTIVE now blocks ordinary cluster deployment"
  info "signed kube-public/cluster-info was intentionally left unchanged"
  info "fix the DNS/certificate issue, then rerun converge and verify"
  info "do not restore the etcd snapshot for this metadata-only endpoint rollback"
}

case "${1:-}" in
  status) status_action ;;
  bridge) bridge_action ;;
  precheck) precheck_action ;;
  backup) backup_action ;;
  roll-certs) roll_certs_action ;;
  converge) converge_action ;;
  verify) verify_action ;;
  rollback) rollback_action ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-status}"

case "${ACTION}" in
  status|verify|restore-original|rollback-k8s|apply-k8s) ;;
  *)
    echo "usage: $0 {status|verify|restore-original|apply-k8s|rollback-k8s}" >&2
    exit 2
    ;;
esac

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/neuroplan_k8s}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
REMOTE_USER="k8sadmin"
LOG_DIR="${PROJECT_ROOT}/logs"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
ROLLBACK_UNIT="np-fw-rb-${RUN_ID}"

NODES=(
  'cp1|192.168.14.31'
  'cp2|192.168.14.32'
  'cp3|192.168.14.33'
  'worker1|192.168.14.41'
  'worker2|192.168.14.42'
  'worker3|192.168.14.43'
)

SSH_OPTIONS=(
  -o BatchMode=yes
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=10
  -i "${SSH_KEY}"
)

for required_file in "${SSH_KEY}" "${KNOWN_HOSTS}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "required file not found: ${required_file}" >&2
    exit 2
  fi
done

case "${ACTION}" in
  restore-original)
    EXPECTED_CONFIRMATION="restore-original"
    ;;
  rollback-k8s)
    EXPECTED_CONFIRMATION="rollback-k8s"
    ;;
  apply-k8s)
    EXPECTED_CONFIRMATION="apply-k8s"
    ;;
  *)
    EXPECTED_CONFIRMATION=""
    ;;
esac

if [[ -n "${EXPECTED_CONFIRMATION}" &&
      "${CONFIRM_FIREWALLD:-}" != "${EXPECTED_CONFIRMATION}" ]]; then
  echo "this action changes firewalld on CP1-3 and Worker1-3" >&2
  echo "run with: CONFIRM_FIREWALLD=${EXPECTED_CONFIRMATION} $0 ${ACTION}" >&2
  exit 2
fi

install -d -m 0750 "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/38-firewalld-${ACTION}-${RUN_ID}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -n "${EXPECTED_CONFIRMATION}" ]]; then
  command -v flock >/dev/null || {
    echo "flock is required for serialized firewalld changes" >&2
    exit 2
  }
  LOCK_FILE="${LOG_DIR}/.38-manage-k8s-firewalld.lock"
  exec {LOCK_FD}>"${LOCK_FILE}"
  flock -n "${LOCK_FD}" || {
    echo "another firewalld controller process is already running" >&2
    exit 2
  }
fi

echo "Kubernetes firewalld controller"
echo "  action          : ${ACTION}"
echo "  local operator  : $(id -un)@$(hostname -s)"
echo "  remote account  : ${REMOTE_USER}"
echo "  managed scope   : CP1-3 and Worker1-3 only"
echo "  log              : ${LOG_FILE}"

if [[ "${ACTION}" == "restore-original" ||
      "${ACTION}" == "rollback-k8s" ||
      "${ACTION}" == "apply-k8s" ]]; then
  "${PROJECT_ROOT}/01-bootstrap/05-verify-devops-control.sh"
fi

remote_action() {
  local node_name="$1"
  local management_ip="$2"
  local requested_action="$3"

  ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
    sudo -n /usr/bin/bash -s -- \
      "${requested_action}" "${node_name}" "${RUN_ID}" "${ROLLBACK_UNIT}" <<'REMOTE'
set -Eeuo pipefail

ACTION="$1"
NODE_NAME="$2"
RUN_ID="$3"
ROLLBACK_UNIT="$4"

POD_CIDR='10.244.0.0/16'
SERVICE_CIDR='10.96.0.0/12'
MANAGEMENT_CIDR='192.168.14.0/24'
POD_ZONE='k8s-pods'
VXLAN_POLICY='k8s-vxlan-in'
TO_PODS_POLICY='k8s-to-pods'
HOST_PODS_POLICY='k8s-host-pods'
POD_OUT_POLICY='k8s-pod-out'
POD_HOST_POLICY='k8s-pod-host'
STATE_DIR='/var/lib/neuroplan-firewalld'
STATE_FILE="${STATE_DIR}/managed-v1.state"
BACKUP_ROOT='/var/backups/neuroplan-firewalld'
SSH_RULE='rule family="ipv4" source address="192.168.14.0/24" port port="22" protocol="tcp" accept'

NODE_INTERNAL_IPS=(
  192.168.34.31
  192.168.34.32
  192.168.34.33
  192.168.34.41
  192.168.34.42
  192.168.34.43
)
POD_CLIENT_IPS=(
  192.168.34.11
  192.168.34.12
  "${NODE_INTERNAL_IPS[@]}"
)
BACKUP_DIR_RESULT=''

if [[ ! "${NODE_NAME}" =~ ^(cp[123]|worker[123])$ ||
      ! "${RUN_ID}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ||
      ! "${ROLLBACK_UNIT}" =~ ^np-fw-rb-[0-9]{8}-[0-9]{6}-[0-9]+$ ]]; then
  echo "invalid fixed argument received by ${NODE_NAME}" >&2
  exit 2
fi

offline_zone_exists() {
  firewall-offline-cmd --get-zones |
    tr ' ' '\n' |
    grep -Fqx -- "$1"
}

offline_policy_exists() {
  firewall-offline-cmd --get-policies |
    tr ' ' '\n' |
    grep -Fqx -- "$1"
}

query_permanent_rich_rule() {
  local zone="$1"
  local rule="$2"

  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --zone="${zone}" --query-rich-rule="${rule}" >/dev/null
  else
    firewall-offline-cmd --zone="${zone}" --query-rich-rule="${rule}" >/dev/null
  fi
}

require_base_configuration() {
  command -v firewall-cmd >/dev/null
  command -v firewall-offline-cmd >/dev/null
  command -v systemd-run >/dev/null

  firewall-offline-cmd --help | grep -q -- '--new-policy'

  if grep -Eiq \
    '^[[:space:]]*FirewallBackend[[:space:]]*=[[:space:]]*iptables[[:space:]]*$' \
    /etc/firewalld/firewalld.conf; then
    echo "[FAIL] ${NODE_NAME}: firewalld nftables backend is required" >&2
    exit 10
  fi

  if grep -Eiq \
    '^[[:space:]]*StrictForwardPorts[[:space:]]*=[[:space:]]*yes[[:space:]]*$' \
    /etc/firewalld/firewalld.conf; then
    echo "[FAIL] ${NODE_NAME}: StrictForwardPorts=yes conflicts with kube-proxy DNAT" >&2
    exit 10
  fi

  if grep -Eiq \
    '^[[:space:]]*CleanupOnExit[[:space:]]*=[[:space:]]*(no|false)[[:space:]]*$' \
    /etc/firewalld/firewalld.conf; then
    echo "[FAIL] ${NODE_NAME}: CleanupOnExit must not be disabled" >&2
    echo "       the automatic SSH recovery timer could leave blocking rules loaded" >&2
    exit 10
  fi

  local zone
  for zone in nw-mgmt nw-internal; do
    if systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --get-zones |
        tr ' ' '\n' |
        grep -Fqx -- "${zone}" || {
          echo "[FAIL] ${NODE_NAME}: permanent zone is missing: ${zone}" >&2
          exit 11
        }
    else
      offline_zone_exists "${zone}" || {
        echo "[FAIL] ${NODE_NAME}: permanent zone is missing: ${zone}" >&2
        exit 11
      }
    fi
  done

  if ! query_permanent_rich_rule nw-mgmt "${SSH_RULE}"; then
    echo "[FAIL] ${NODE_NAME}: approved Management SSH rule is missing" >&2
    echo "       expected source ${MANAGEMENT_CIDR} -> TCP/22 in nw-mgmt" >&2
    exit 12
  fi
}

cancel_stale_safety_timers() {
  local unit service_unit

  while read -r unit _; do
    [[ -n "${unit}" ]] || continue
    [[ "${unit}" =~ ^np-fw-rb-[0-9]{8}-[0-9]{6}-[0-9]+\.timer$ ]] || continue
    service_unit="${unit%.timer}.service"
    systemctl stop "${unit}" "${service_unit}"
    if systemctl is-active --quiet "${unit}" ||
       systemctl is-active --quiet "${service_unit}"; then
      echo "[FAIL] ${NODE_NAME}: could not stop stale safeguard ${unit}" >&2
      exit 9
    fi
    systemctl reset-failed "${unit}" "${service_unit}" >/dev/null 2>&1 || true
    echo "[SAFEGUARD] ${NODE_NAME}: cancelled stale timer/service ${unit}"
  done < <(
    systemctl list-units --all --type=timer --plain --no-legend \
      'np-fw-rb-*.timer' 2>/dev/null || true
  )
}

backup_configuration() {
  local reason="$1"
  BACKUP_DIR_RESULT="${BACKUP_ROOT}/${NODE_NAME}-${RUN_ID}-${reason}"

  install -d -m 0700 "${BACKUP_ROOT}" "${BACKUP_DIR_RESULT}"
  tar -C /etc -czf "${BACKUP_DIR_RESULT}/firewalld.tar.gz" firewalld
  systemctl is-enabled firewalld >"${BACKUP_DIR_RESULT}/service-enabled.txt" 2>&1 || true
  systemctl is-active firewalld >"${BACKUP_DIR_RESULT}/service-active.txt" 2>&1 || true

  if systemctl is-active --quiet firewalld; then
    firewall-cmd --list-all-zones >"${BACKUP_DIR_RESULT}/runtime-zones.txt"
    firewall-cmd --list-all-policies >"${BACKUP_DIR_RESULT}/runtime-policies.txt"
    firewall-cmd --permanent --list-all-zones >"${BACKUP_DIR_RESULT}/permanent-zones.txt"
    firewall-cmd --permanent --list-all-policies >"${BACKUP_DIR_RESULT}/permanent-policies.txt"
  else
    firewall-offline-cmd --list-all-zones >"${BACKUP_DIR_RESULT}/permanent-zones.txt"
    firewall-offline-cmd --list-all-policies >"${BACKUP_DIR_RESULT}/permanent-policies.txt"
  fi
  chmod -R go-rwx "${BACKUP_DIR_RESULT}"
}

validate_state_file() {
  [[ -f "${STATE_FILE}" ]] || return 1
  [[ ! -L "${STATE_FILE}" ]]
  [[ "$(stat -c '%u:%a' "${STATE_FILE}")" == '0:600' ]]
  grep -Fqx 'VERSION=1' "${STATE_FILE}"
  grep -Fqx 'CREATED_BY=38-manage-k8s-firewalld.sh' "${STATE_FILE}"
  grep -Eq '^BACKUP_DIR=/var/backups/neuroplan-firewalld/[A-Za-z0-9._-]+$' \
    "${STATE_FILE}"
}

write_state_file() {
  local backup_dir="$1"

  install -d -o root -g root -m 0700 "${STATE_DIR}"
  umask 077
  {
    echo 'VERSION=1'
    echo "CREATED_BY=38-manage-k8s-firewalld.sh"
    echo "BACKUP_DIR=${backup_dir}"
  } >"${STATE_FILE}.new"
  chmod 0600 "${STATE_FILE}.new"
  mv -f -- "${STATE_FILE}.new" "${STATE_FILE}"
}

assert_owned_or_unused_names() {
  local object

  if [[ -e "${STATE_FILE}" ]]; then
    validate_state_file || {
      echo "[FAIL] ${NODE_NAME}: invalid managed state file: ${STATE_FILE}" >&2
      exit 13
    }
    return 0
  fi

  if offline_zone_exists "${POD_ZONE}"; then
    echo "[FAIL] ${NODE_NAME}: unowned zone name already exists: ${POD_ZONE}" >&2
    exit 13
  fi
  for object in \
    "${VXLAN_POLICY}" \
    "${TO_PODS_POLICY}" \
    "${HOST_PODS_POLICY}" \
    "${POD_OUT_POLICY}" \
    "${POD_HOST_POLICY}"; do
    if offline_policy_exists "${object}"; then
      echo "[FAIL] ${NODE_NAME}: unowned policy name already exists: ${object}" >&2
      exit 13
    fi
  done
}

ensure_zone() {
  if ! offline_zone_exists "${POD_ZONE}"; then
    firewall-offline-cmd --new-zone="${POD_ZONE}"
  fi
  firewall-offline-cmd --zone="${POD_ZONE}" --set-short='Kubernetes Pods'
  firewall-offline-cmd --zone="${POD_ZONE}" \
    --set-description='Calico-managed Pod CIDR; filtering delegated to Calico'
  firewall-offline-cmd --zone="${POD_ZONE}" --set-target=DROP
  firewall-offline-cmd --zone="${POD_ZONE}" --query-source="${POD_CIDR}" >/dev/null ||
    firewall-offline-cmd --zone="${POD_ZONE}" --add-source="${POD_CIDR}"
}

ensure_policy_base() {
  local policy="$1"
  local ingress_zone="$2"
  local egress_zone="$3"
  local target="$4"
  local short_name="$5"
  local description="$6"

  if ! offline_policy_exists "${policy}"; then
    firewall-offline-cmd --new-policy="${policy}"
  fi
  firewall-offline-cmd --policy="${policy}" --set-short="${short_name}"
  firewall-offline-cmd --policy="${policy}" --set-description="${description}"
  firewall-offline-cmd --policy="${policy}" --set-target="${target}"
  firewall-offline-cmd --policy="${policy}" \
    --query-ingress-zone="${ingress_zone}" >/dev/null ||
    firewall-offline-cmd --policy="${policy}" --add-ingress-zone="${ingress_zone}"
  firewall-offline-cmd --policy="${policy}" \
    --query-egress-zone="${egress_zone}" >/dev/null ||
    firewall-offline-cmd --policy="${policy}" --add-egress-zone="${egress_zone}"
}

ensure_policy_rich_rule() {
  local policy="$1"
  local rule="$2"

  firewall-offline-cmd --policy="${policy}" --query-rich-rule="${rule}" >/dev/null ||
    firewall-offline-cmd --policy="${policy}" --add-rich-rule="${rule}"
}

apply_compatibility_objects() {
  local ip rule

  ensure_zone

  ensure_policy_base \
    "${VXLAN_POLICY}" nw-internal HOST CONTINUE \
    'Kubernetes VXLAN ingress' \
    'Allow UDP 4789 from the six Kubernetes node Internal addresses'
  for ip in "${NODE_INTERNAL_IPS[@]}"; do
    rule="rule family=\"ipv4\" source address=\"${ip}/32\" port port=\"4789\" protocol=\"udp\" accept"
    ensure_policy_rich_rule "${VXLAN_POLICY}" "${rule}"
  done

  ensure_policy_base \
    "${TO_PODS_POLICY}" nw-internal "${POD_ZONE}" CONTINUE \
    'Internal to Kubernetes Pods' \
    'Allow approved Kubernetes nodes and HAProxy nodes to reach Pod CIDR'
  for ip in "${POD_CLIENT_IPS[@]}"; do
    rule="rule family=\"ipv4\" source address=\"${ip}/32\" accept"
    ensure_policy_rich_rule "${TO_PODS_POLICY}" "${rule}"
  done

  ensure_policy_base \
    "${HOST_PODS_POLICY}" HOST "${POD_ZONE}" ACCEPT \
    'Host to Kubernetes Pods' \
    'Allow local kubelet probes and host control-plane traffic to Pod CIDR'

  ensure_policy_base \
    "${POD_OUT_POLICY}" "${POD_ZONE}" ANY ACCEPT \
    'Kubernetes Pod forwarding' \
    'Allow Pod forwarding while workload policy remains owned by Calico'

  ensure_policy_base \
    "${POD_HOST_POLICY}" "${POD_ZONE}" HOST CONTINUE \
    'Kubernetes Pods to host' \
    'Allow Service CIDR and approved node-host services from Pod CIDR'
  rule="rule family=\"ipv4\" destination address=\"${SERVICE_CIDR}\" accept"
  ensure_policy_rich_rule "${POD_HOST_POLICY}" "${rule}"
  for rule in \
    'rule family="ipv4" port port="53" protocol="udp" accept' \
    'rule family="ipv4" port port="53" protocol="tcp" accept' \
    'rule family="ipv4" port port="6443" protocol="tcp" accept' \
    'rule family="ipv4" port port="9100" protocol="tcp" accept' \
    'rule family="ipv4" port port="10250" protocol="tcp" accept'; do
    ensure_policy_rich_rule "${POD_HOST_POLICY}" "${rule}"
  done
}

remove_owned_objects() {
  local backup_dir archived_state object

  if [[ ! -e "${STATE_FILE}" ]]; then
    if offline_zone_exists "${POD_ZONE}"; then
      echo "[FAIL] ${NODE_NAME}: refusing to remove unowned zone ${POD_ZONE}" >&2
      exit 14
    fi
    for object in \
      "${VXLAN_POLICY}" \
      "${TO_PODS_POLICY}" \
      "${HOST_PODS_POLICY}" \
      "${POD_OUT_POLICY}" \
      "${POD_HOST_POLICY}"; do
      if offline_policy_exists "${object}"; then
        echo "[FAIL] ${NODE_NAME}: refusing to remove unowned policy ${object}" >&2
        exit 14
      fi
    done
    return 0
  fi

  validate_state_file || {
    echo "[FAIL] ${NODE_NAME}: invalid managed state file; nothing was removed" >&2
    exit 14
  }
  backup_dir="$(awk -F= '$1 == "BACKUP_DIR" { print substr($0, index($0, "=") + 1) }' \
    "${STATE_FILE}")"
  if [[ ! -d "${backup_dir}" ]]; then
    echo "[WARN] ${NODE_NAME}: recorded backup was removed: ${backup_dir}" >&2
    backup_dir="${BACKUP_ROOT}/${NODE_NAME}-${RUN_ID}-state-archive"
    install -d -o root -g root -m 0700 "${BACKUP_ROOT}" "${backup_dir}"
    echo "       ownership state will be archived in ${backup_dir}" >&2
  fi

  for object in \
    "${POD_HOST_POLICY}" \
    "${POD_OUT_POLICY}" \
    "${HOST_PODS_POLICY}" \
    "${TO_PODS_POLICY}" \
    "${VXLAN_POLICY}"; do
    if offline_policy_exists "${object}"; then
      firewall-offline-cmd --delete-policy="${object}"
    fi
  done
  if offline_zone_exists "${POD_ZONE}"; then
    firewall-offline-cmd --delete-zone="${POD_ZONE}"
  fi

  archived_state="${backup_dir}/managed-v1-restored-${RUN_ID}.state"
  mv -- "${STATE_FILE}" "${archived_state}"
  chmod 0600 "${archived_state}"
}

schedule_safety_rollback() {
  local seconds="$1"

  systemd-run --quiet --collect \
    --unit="${ROLLBACK_UNIT}" \
    --on-active="${seconds}s" \
    /usr/bin/systemctl disable --now firewalld
  echo "[SAFEGUARD] ${ROLLBACK_UNIT}.timer will disable firewalld in ${seconds}s"
}

show_status() {
  local object object_state

  echo "node=${NODE_NAME} enabled=$(systemctl is-enabled firewalld 2>/dev/null || true) active=$(systemctl is-active firewalld 2>/dev/null || true)"
  if [[ -f "${STATE_FILE}" ]]; then
    echo "managed_compatibility=present"
  else
    echo "managed_compatibility=absent"
  fi

  if systemctl is-active --quiet firewalld; then
    firewall-cmd --state
    firewall-cmd --get-active-zones
  else
    echo "firewalld runtime is not active"
  fi

  if command -v firewall-offline-cmd >/dev/null &&
     ! systemctl is-active --quiet firewalld; then
    if offline_zone_exists "${POD_ZONE}"; then
      echo "compatibility_zone_${POD_ZONE}=present"
    else
      echo "compatibility_zone_${POD_ZONE}=absent"
    fi
    for object in \
      "${VXLAN_POLICY}" \
      "${TO_PODS_POLICY}" \
      "${HOST_PODS_POLICY}" \
      "${POD_OUT_POLICY}" \
      "${POD_HOST_POLICY}"; do
      if offline_policy_exists "${object}"; then
        object_state=present
      else
        object_state=absent
      fi
      echo "compatibility_policy_${object}=${object_state}"
    done
  fi

  systemctl list-units --all --type=timer --plain --no-legend \
    'np-fw-rb-*.timer' 2>/dev/null || true
}

verify_runtime() {
  local ip rule url code rc

  systemctl is-enabled --quiet firewalld
  systemctl is-active --quiet firewalld
  firewall-cmd --state | grep -Fqx running
  firewall-cmd --zone="${POD_ZONE}" --query-source="${POD_CIDR}" >/dev/null
  [[ "$(firewall-cmd --zone="${POD_ZONE}" --list-sources)" == "${POD_CIDR}" ]]
  [[ "$(firewall-cmd --zone="${POD_ZONE}" --get-target)" == 'DROP' ]]

  firewall-cmd --policy="${VXLAN_POLICY}" --query-ingress-zone=nw-internal >/dev/null
  firewall-cmd --policy="${VXLAN_POLICY}" --query-egress-zone=HOST >/dev/null
  [[ "$(firewall-cmd --policy="${VXLAN_POLICY}" --list-ingress-zones)" == 'nw-internal' ]]
  [[ "$(firewall-cmd --policy="${VXLAN_POLICY}" --list-egress-zones)" == 'HOST' ]]
  [[ "$(firewall-cmd --policy="${VXLAN_POLICY}" --get-target)" == 'CONTINUE' ]]
  for ip in "${NODE_INTERNAL_IPS[@]}"; do
    rule="rule family=\"ipv4\" source address=\"${ip}/32\" port port=\"4789\" protocol=\"udp\" accept"
    firewall-cmd --policy="${VXLAN_POLICY}" --query-rich-rule="${rule}" >/dev/null
  done
  [[ "$(firewall-cmd --policy="${VXLAN_POLICY}" --list-rich-rules | awk 'NF { count++ } END { print count + 0 }')" -eq 6 ]]

  firewall-cmd --policy="${TO_PODS_POLICY}" --query-ingress-zone=nw-internal >/dev/null
  firewall-cmd --policy="${TO_PODS_POLICY}" --query-egress-zone="${POD_ZONE}" >/dev/null
  [[ "$(firewall-cmd --policy="${TO_PODS_POLICY}" --list-ingress-zones)" == 'nw-internal' ]]
  [[ "$(firewall-cmd --policy="${TO_PODS_POLICY}" --list-egress-zones)" == "${POD_ZONE}" ]]
  [[ "$(firewall-cmd --policy="${TO_PODS_POLICY}" --get-target)" == 'CONTINUE' ]]
  for ip in "${POD_CLIENT_IPS[@]}"; do
    rule="rule family=\"ipv4\" source address=\"${ip}/32\" accept"
    firewall-cmd --policy="${TO_PODS_POLICY}" --query-rich-rule="${rule}" >/dev/null
  done
  [[ "$(firewall-cmd --policy="${TO_PODS_POLICY}" --list-rich-rules | awk 'NF { count++ } END { print count + 0 }')" -eq 8 ]]

  firewall-cmd --policy="${HOST_PODS_POLICY}" --query-ingress-zone=HOST >/dev/null
  firewall-cmd --policy="${HOST_PODS_POLICY}" --query-egress-zone="${POD_ZONE}" >/dev/null
  [[ "$(firewall-cmd --policy="${HOST_PODS_POLICY}" --list-ingress-zones)" == 'HOST' ]]
  [[ "$(firewall-cmd --policy="${HOST_PODS_POLICY}" --list-egress-zones)" == "${POD_ZONE}" ]]
  [[ "$(firewall-cmd --policy="${HOST_PODS_POLICY}" --get-target)" == 'ACCEPT' ]]
  [[ "$(firewall-cmd --policy="${HOST_PODS_POLICY}" --list-rich-rules | awk 'NF { count++ } END { print count + 0 }')" -eq 0 ]]

  firewall-cmd --policy="${POD_OUT_POLICY}" --query-ingress-zone="${POD_ZONE}" >/dev/null
  firewall-cmd --policy="${POD_OUT_POLICY}" --query-egress-zone=ANY >/dev/null
  [[ "$(firewall-cmd --policy="${POD_OUT_POLICY}" --list-ingress-zones)" == "${POD_ZONE}" ]]
  [[ "$(firewall-cmd --policy="${POD_OUT_POLICY}" --list-egress-zones)" == 'ANY' ]]
  [[ "$(firewall-cmd --policy="${POD_OUT_POLICY}" --get-target)" == 'ACCEPT' ]]
  [[ "$(firewall-cmd --policy="${POD_OUT_POLICY}" --list-rich-rules | awk 'NF { count++ } END { print count + 0 }')" -eq 0 ]]

  firewall-cmd --policy="${POD_HOST_POLICY}" --query-ingress-zone="${POD_ZONE}" >/dev/null
  firewall-cmd --policy="${POD_HOST_POLICY}" --query-egress-zone=HOST >/dev/null
  [[ "$(firewall-cmd --policy="${POD_HOST_POLICY}" --list-ingress-zones)" == "${POD_ZONE}" ]]
  [[ "$(firewall-cmd --policy="${POD_HOST_POLICY}" --list-egress-zones)" == 'HOST' ]]
  [[ "$(firewall-cmd --policy="${POD_HOST_POLICY}" --get-target)" == 'CONTINUE' ]]
  rule="rule family=\"ipv4\" destination address=\"${SERVICE_CIDR}\" accept"
  firewall-cmd --policy="${POD_HOST_POLICY}" --query-rich-rule="${rule}" >/dev/null
  for rule in \
    'rule family="ipv4" port port="53" protocol="udp" accept' \
    'rule family="ipv4" port port="53" protocol="tcp" accept' \
    'rule family="ipv4" port port="6443" protocol="tcp" accept' \
    'rule family="ipv4" port port="9100" protocol="tcp" accept' \
    'rule family="ipv4" port port="10250" protocol="tcp" accept'; do
    firewall-cmd --policy="${POD_HOST_POLICY}" --query-rich-rule="${rule}" >/dev/null
  done
  [[ "$(firewall-cmd --policy="${POD_HOST_POLICY}" --list-rich-rules | awk 'NF { count++ } END { print count + 0 }')" -eq 6 ]]

  for url in \
    'https://192.168.34.31:6443/livez' \
    'https://192.168.34.100:6443/livez' \
    'https://10.96.0.1:443/livez'; do
    rc=0
    code="$(curl --noproxy '*' -ksS \
      --connect-timeout 3 --max-time 5 \
      -o /dev/null -w '%{http_code}' "${url}")" || rc=$?
    printf '%-43s HTTP=%s curl_rc=%s\n' "${url}" "${code}" "${rc}"
    [[ ${rc} -eq 0 && "${code}" =~ ^(200|401|403)$ ]]
  done

  echo "[PASS] ${NODE_NAME}: firewalld runtime and host API paths"
}

case "${ACTION}" in
  status)
    show_status
    ;;
  verify)
    require_base_configuration
    verify_runtime
    ;;
  apply-k8s)
    require_base_configuration
    cancel_stale_safety_timers
    if systemctl is-active --quiet firewalld; then
      if ! validate_state_file; then
        echo "[FAIL] ${NODE_NAME}: active firewalld is not owned by this compatibility action" >&2
        echo "       runtime-only Network rules must not be discarded automatically" >&2
        exit 15
      fi
      schedule_safety_rollback 900
      verify_runtime
      show_status
      exit 0
    fi
    backup_configuration pre-apply
    backup_dir="${BACKUP_DIR_RESULT}"
    echo "[BACKUP] ${NODE_NAME}: ${backup_dir}"
    systemctl disable --now firewalld
    firewall-offline-cmd --check-config
    assert_owned_or_unused_names
    if [[ ! -e "${STATE_FILE}" ]]; then
      write_state_file "${backup_dir}"
    fi
    apply_compatibility_objects
    firewall-offline-cmd --check-config
    schedule_safety_rollback 900
    systemctl enable --now firewalld
    show_status
    ;;
  restore-original)
    require_base_configuration
    cancel_stale_safety_timers
    if systemctl is-active --quiet firewalld && [[ ! -e "${STATE_FILE}" ]]; then
      if firewall-cmd --permanent --get-zones |
           tr ' ' '\n' | grep -Fqx -- "${POD_ZONE}"; then
        echo "[FAIL] ${NODE_NAME}: unowned compatibility zone exists while state is missing" >&2
        exit 15
      fi
      for object in \
        "${VXLAN_POLICY}" \
        "${TO_PODS_POLICY}" \
        "${HOST_PODS_POLICY}" \
        "${POD_OUT_POLICY}" \
        "${POD_HOST_POLICY}"; do
        if firewall-cmd --permanent --get-policies |
             tr ' ' '\n' | grep -Fqx -- "${object}"; then
          echo "[FAIL] ${NODE_NAME}: unowned compatibility policy exists: ${object}" >&2
          exit 15
        fi
      done
      schedule_safety_rollback 180
      show_status
      exit 0
    fi
    backup_configuration pre-restore
    backup_dir="${BACKUP_DIR_RESULT}"
    echo "[BACKUP] ${NODE_NAME}: ${backup_dir}"
    systemctl disable --now firewalld
    firewall-offline-cmd --check-config
    remove_owned_objects
    firewall-offline-cmd --check-config
    schedule_safety_rollback 180
    systemctl enable --now firewalld
    show_status
    ;;
  rollback-k8s)
    require_base_configuration
    cancel_stale_safety_timers
    backup_configuration pre-rollback
    backup_dir="${BACKUP_DIR_RESULT}"
    echo "[BACKUP] ${NODE_NAME}: ${backup_dir}"
    systemctl disable --now firewalld
    firewall-offline-cmd --check-config
    remove_owned_objects
    firewall-offline-cmd --check-config
    show_status
    ;;
esac
REMOTE
}

verify_new_connection() {
  local node_name="$1"
  local management_ip="$2"
  local require_objects="$3"

  ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
    sudo -n /usr/bin/bash -s -- "${node_name}" "${require_objects}" <<'REMOTE'
set -Eeuo pipefail
node_name="$1"
require_objects="$2"

systemctl is-enabled --quiet firewalld
systemctl is-active --quiet firewalld
firewall-cmd --state | grep -Fqx running

if [[ "${require_objects}" == 'yes' ]]; then
  firewall-cmd --zone=k8s-pods --query-source=10.244.0.0/16 >/dev/null
  firewall-cmd --info-policy=k8s-vxlan-in >/dev/null
  firewall-cmd --info-policy=k8s-to-pods >/dev/null
  firewall-cmd --info-policy=k8s-host-pods >/dev/null
  firewall-cmd --info-policy=k8s-pod-out >/dev/null
  firewall-cmd --info-policy=k8s-pod-host >/dev/null
fi

echo "[PASS] ${node_name}: a new SSH connection succeeded with firewalld active"
REMOTE
}

verify_disabled_connection() {
  local node_name="$1"
  local management_ip="$2"

  ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
    sudo -n /usr/bin/bash -s -- "${node_name}" <<'REMOTE'
set -Eeuo pipefail
node_name="$1"

[[ "$(systemctl is-enabled firewalld 2>/dev/null || true)" == 'disabled' ]]
[[ "$(systemctl is-active firewalld 2>/dev/null || true)" == 'inactive' ]]

echo "[PASS] ${node_name}: new SSH succeeded and firewalld is disabled/inactive"
REMOTE
}

verify_no_safety_timer() {
  local node_name="$1"
  local management_ip="$2"

  ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
    sudo -n /usr/bin/bash -s -- "${node_name}" <<'REMOTE'
set -Eeuo pipefail
node_name="$1"

for unit_type in timer service; do
  if systemctl list-units --all --type="${unit_type}" --plain --no-legend \
    "np-fw-rb-*.${unit_type}" 2>/dev/null | grep -q '^np-fw-rb-'; then
    echo "[FAIL] ${node_name}: a stale neuroplan firewalld safeguard ${unit_type} exists" >&2
    exit 1
  fi
done
echo "[PASS] ${node_name}: no stale firewalld safety timer/service"
REMOTE
}

cancel_safety_timer() {
  local node_name="$1"
  local management_ip="$2"

  ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
    sudo -n /usr/bin/bash -s -- "${node_name}" "${ROLLBACK_UNIT}" <<'REMOTE'
set -Eeuo pipefail
node_name="$1"
rollback_unit="$2"
[[ "${rollback_unit}" =~ ^np-fw-rb-[0-9]{8}-[0-9]{6}-[0-9]+$ ]]
systemctl stop "${rollback_unit}.timer" "${rollback_unit}.service"
if systemctl is-active --quiet "${rollback_unit}.timer" ||
   systemctl is-active --quiet "${rollback_unit}.service"; then
  echo "[FAIL] ${node_name}: safety rollback timer/service is still active" >&2
  exit 1
fi
systemctl reset-failed \
  "${rollback_unit}.timer" "${rollback_unit}.service" >/dev/null 2>&1 || true
echo "[PASS] ${node_name}: safety rollback timer/service cancelled"
REMOTE
}

nodeport_cross_node_smoke() {
  local pod_name='neuroplan-firewall-echo'
  local client_name='neuroplan-firewall-service-client'
  local service_name='neuroplan-firewall-nodeport'
  local node_port=''
  local client_phase=''
  local nodeport_rule_added=0
  local rc=0

  kubectl -n kube-system delete \
    "service/${service_name}" "pod/${pod_name}" "pod/${client_name}" \
    --ignore-not-found --wait=true --timeout=30s >/dev/null || rc=1

  if (( rc == 0 )); then
    kubectl -n kube-system run "${pod_name}" \
      --image=192.168.34.21:5000/neuroplan/nginx:1.28-alpine \
      --restart=Never \
      --overrides='{"apiVersion":"v1","spec":{"nodeName":"worker1"}}' >/dev/null || rc=1
  fi

  if (( rc == 0 )); then
    kubectl -n kube-system wait --for=condition=Ready \
      "pod/${pod_name}" --timeout=120s || rc=1
  fi

  if (( rc == 0 )); then
    kubectl -n kube-system expose pod "${pod_name}" \
      --name="${service_name}" \
      --type=NodePort \
      --port=80 \
      --target-port=80 >/dev/null || rc=1
  fi

  if (( rc == 0 )); then
    kubectl -n kube-system run "${client_name}" \
      --image=192.168.34.21:5000/neuroplan/curl:8.12.1 \
      --restart=Never \
      --overrides='{"apiVersion":"v1","spec":{"nodeName":"worker3"}}' \
      --command -- sh -ec \
      'code="$(curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" http://neuroplan-firewall-nodeport.kube-system.svc/)"; echo "service_http=${code}"; [ "${code}" = 200 ]' >/dev/null || rc=1
  fi

  if (( rc == 0 )); then
    for _ in {1..60}; do
      client_phase="$(kubectl -n kube-system get pod "${client_name}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "${client_phase}" in
        Succeeded) break ;;
        Failed) rc=1; break ;;
      esac
      sleep 2
    done
    client_phase="$(kubectl -n kube-system get pod "${client_name}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    kubectl -n kube-system logs "${client_name}" || true
    [[ "${client_phase}" == 'Succeeded' ]] || rc=1
  fi

  if (( rc == 0 )); then
    node_port="$(kubectl -n kube-system get service "${service_name}" \
      -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    [[ "${node_port}" =~ ^3[0-9]{4}$ ]] || rc=1
  fi

  if (( rc == 0 )); then
    # The approved base policy exposes only fixed application NodePorts from
    # LB1/LB2. Open this one random validation port from CP1 for 120 seconds
    # at runtime only; the timeout is a second cleanup path if this controller
    # is interrupted before the explicit removal below.
    if ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@192.168.14.42" \
      sudo -n /usr/bin/bash -s -- "${node_port}" <<'REMOTE'
set -Eeuo pipefail
node_port="$1"
[[ "${node_port}" =~ ^3[0-9]{4}$ ]]
rule="rule family=\"ipv4\" source address=\"192.168.34.31/32\" port port=\"${node_port}\" protocol=\"tcp\" accept"
firewall-cmd --zone=nw-internal --add-rich-rule="${rule}" --timeout=120s
firewall-cmd --zone=nw-internal --query-rich-rule="${rule}" >/dev/null
REMOTE
    then
      nodeport_rule_added=1
    else
      rc=1
    fi
  fi

  if (( rc == 0 )); then
    echo "testing CP1 -> Worker2 NodePort ${node_port} -> Worker1 Pod"
    ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@192.168.14.31" \
      /usr/bin/bash -s -- "http://192.168.34.42:${node_port}/" <<'REMOTE' || rc=1
set -Eeuo pipefail
url="$1"
curl --noproxy '*' -fsS \
  --connect-timeout 3 --max-time 10 \
  -o /dev/null \
  -w 'nodeport_http=%{http_code}\n' \
  "${url}"
REMOTE
  fi

  if (( nodeport_rule_added == 1 )); then
    ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@192.168.14.42" \
      sudo -n /usr/bin/bash -s -- "${node_port}" <<'REMOTE' || rc=1
set -Eeuo pipefail
node_port="$1"
rule="rule family=\"ipv4\" source address=\"192.168.34.31/32\" port port=\"${node_port}\" protocol=\"tcp\" accept"
firewall-cmd --zone=nw-internal --remove-rich-rule="${rule}" >/dev/null
if firewall-cmd --zone=nw-internal --query-rich-rule="${rule}" >/dev/null 2>&1; then
  echo "temporary NodePort validation rule still exists" >&2
  exit 1
fi
REMOTE
  fi

  if (( rc != 0 )); then
    kubectl -n kube-system get \
      "pod/${pod_name}" "pod/${client_name}" "service/${service_name}" \
      -o wide 2>/dev/null || true
    kubectl -n kube-system describe "pod/${pod_name}" 2>/dev/null || true
    kubectl -n kube-system describe "pod/${client_name}" 2>/dev/null || true
  fi

  kubectl -n kube-system delete \
    "service/${service_name}" "pod/${pod_name}" "pod/${client_name}" \
    --ignore-not-found --wait=false >/dev/null || true

  if (( rc != 0 )); then
    echo "[FAIL] ClusterIP/NodePort/DNAT/VXLAN smoke failed" >&2
    return 1
  fi
  echo "[PASS] generic ClusterIP and cross-node NodePort/DNAT/VXLAN paths"
}

baseline_cluster_gate() {
  local deployment available metrics_status

  export KUBECONFIG="${HOME}/.kube/config"
  if ! command -v kubectl >/dev/null || [[ ! -f "${KUBECONFIG}" ]]; then
    echo "kubectl or ${KUBECONFIG} is missing; run 12-install-devops-client.sh" >&2
    return 1
  fi

  echo
  echo '===== pre-change healthy-cluster gate ====='
  kubectl get nodes -o wide
  [[ "$(kubectl get nodes --no-headers | wc -l)" -eq 6 ]]
  [[ -z "$(kubectl get nodes --no-headers | awk '$2 != "Ready" { print $1 ":" $2 }')" ]]

  for deployment in calico-kube-controllers coredns metrics-server; do
    available="$(kubectl -n kube-system get deployment "${deployment}" \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
    if [[ "${available}" != 'True' ]]; then
      echo "[FAIL] deployment/${deployment} is not Available before firewalld change" >&2
      return 1
    fi
  done

  metrics_status="$(kubectl get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
  if [[ "${metrics_status}" != 'True' ]]; then
    echo "[FAIL] Metrics API is not Available before firewalld change" >&2
    return 1
  fi
  kubectl top nodes >/dev/null

  echo "[PASS] cluster is healthy before firewalld mutation"
}

cluster_verify() {
  local smoke_pod='neuroplan-firewall-smoke'
  local phase code metrics_status
  local rc=0

  export KUBECONFIG="${HOME}/.kube/config"
  if ! command -v kubectl >/dev/null || [[ ! -f "${KUBECONFIG}" ]]; then
    echo "kubectl or ${KUBECONFIG} is missing; run 12-install-devops-client.sh" >&2
    return 1
  fi

  echo
  echo '===== cluster readiness ====='
  kubectl get nodes -o wide
  [[ "$(kubectl get nodes --no-headers | wc -l)" -eq 6 ]]
  [[ -z "$(kubectl get nodes --no-headers | awk '$2 != "Ready" { print $1 ":" $2 }')" ]]

  kubectl -n kube-system wait --for=condition=Ready \
    pod -l k8s-app=calico-node --timeout=180s
  kubectl -n kube-system wait --for=condition=Available \
    deployment/calico-kube-controllers \
    deployment/coredns \
    deployment/metrics-server \
    --timeout=180s

  metrics_status="$(kubectl get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
  [[ "${metrics_status}" == 'True' ]]

  for _ in {1..30}; do
    if kubectl top nodes; then
      break
    fi
    sleep 2
  done
  kubectl top nodes >/dev/null

  echo
  echo '===== Pod DNS and ClusterIP API smoke ====='
  kubectl -n kube-system delete pod "${smoke_pod}" \
    --ignore-not-found --wait=true --timeout=30s >/dev/null

  kubectl -n kube-system run "${smoke_pod}" \
    --image=192.168.34.21:5000/neuroplan/curl:8.12.1 \
    --restart=Never \
    --command -- sh -ec \
    'code="$(curl -ksS --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" https://kubernetes.default.svc/livez)"; echo "cluster_api_http=${code}"; case "${code}" in 200|401|403) exit 0;; *) exit 1;; esac'

  for _ in {1..60}; do
    phase="$(kubectl -n kube-system get pod "${smoke_pod}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Succeeded) break ;;
      Failed) rc=1; break ;;
    esac
    sleep 2
  done

  phase="$(kubectl -n kube-system get pod "${smoke_pod}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  kubectl -n kube-system logs "${smoke_pod}" || true
  [[ "${phase}" == 'Succeeded' ]] || rc=1
  kubectl -n kube-system delete pod "${smoke_pod}" \
    --ignore-not-found --wait=false >/dev/null || true

  if (( rc != 0 )); then
    echo "[FAIL] Pod DNS/ClusterIP API smoke failed" >&2
    return 1
  fi

  echo
  echo '===== cross-node NodePort and VXLAN smoke ====='
  nodeport_cross_node_smoke

  echo "[PASS] all six nodes, Calico, CoreDNS, Metrics, Pod ClusterIP and cross-node NodePort"
}

PENDING_TIMERS=()

report_pending_timer_on_exit() {
  local rc=$?

  if [[ ${rc} -ne 0 && ${#PENDING_TIMERS[@]} -gt 0 ]]; then
    echo >&2
    echo "[SAFEGUARD] the action failed; any active safety timers were not cancelled" >&2
    if [[ "${ACTION}" == 'apply-k8s' ]]; then
      echo "            they will disable firewalld automatically within 15 minutes" >&2
    else
      echo "            they will disable firewalld automatically within 3 minutes" >&2
    fi
    echo "            use VMware console if a node is not reachable after that" >&2
  fi
  exit "${rc}"
}
trap report_pending_timer_on_exit EXIT

case "${ACTION}" in
  status)
    for node_record in "${NODES[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      echo
      echo "===== ${node_name} (${management_ip}) ====="
      remote_action "${node_name}" "${management_ip}" status
    done
    ;;
  verify)
    for node_record in "${NODES[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      echo
      echo "===== ${node_name} (${management_ip}) ====="
      verify_no_safety_timer "${node_name}" "${management_ip}"
      remote_action "${node_name}" "${management_ip}" verify
    done
    cluster_verify
    ;;
  apply-k8s)
    echo
    echo "[WARN] Calico officially recommends disabling firewalld."
    echo "       This action applies the project's lab compatibility policy."
    baseline_cluster_gate
    for node_record in "${NODES[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      echo
      echo "===== ${node_name} (${management_ip}) ====="
      PENDING_TIMERS+=("${node_record}")
      remote_action "${node_name}" "${management_ip}" apply-k8s
      verify_new_connection "${node_name}" "${management_ip}" yes
      remote_action "${node_name}" "${management_ip}" verify
    done

    cluster_verify

    for node_record in "${PENDING_TIMERS[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      cancel_safety_timer "${node_name}" "${management_ip}"
    done

    echo
    echo '===== final firewalld active-state gate ====='
    for node_record in "${PENDING_TIMERS[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      verify_new_connection "${node_name}" "${management_ip}" yes
      verify_no_safety_timer "${node_name}" "${management_ip}"
      remote_action "${node_name}" "${management_ip}" verify
    done
    PENDING_TIMERS=()
    echo
    echo "[PASS] firewalld is enabled with the Kubernetes compatibility policy"
    ;;
  restore-original)
    echo
    echo "[WARN] This enables the original firewalld policy without Kubernetes compatibility objects."
    echo "       The earlier Pod-to-Service/API failure can reappear."
    for node_record in "${NODES[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      echo
      echo "===== ${node_name} (${management_ip}) ====="
      PENDING_TIMERS+=("${node_record}")
      remote_action "${node_name}" "${management_ip}" "${ACTION}"
      verify_new_connection "${node_name}" "${management_ip}" no
      cancel_safety_timer "${node_name}" "${management_ip}"
      verify_no_safety_timer "${node_name}" "${management_ip}"
    done
    PENDING_TIMERS=()
    echo
    echo "[PASS] original permanent firewalld configuration is enabled on all six nodes"
    echo "[WARN] Run status checks immediately; Kubernetes Pod paths are expected to fail in this mode"
    ;;
  rollback-k8s)
    echo
    echo "[INFO] Removing only script-owned compatibility objects and returning to"
    echo "       the Calico-recommended firewalld disabled/inactive state."
    for node_record in "${NODES[@]}"; do
      IFS='|' read -r node_name management_ip <<<"${node_record}"
      echo
      echo "===== ${node_name} (${management_ip}) ====="
      remote_action "${node_name}" "${management_ip}" rollback-k8s
      verify_disabled_connection "${node_name}" "${management_ip}"
      verify_no_safety_timer "${node_name}" "${management_ip}"
    done
    echo
    echo "[PASS] compatibility objects were removed and firewalld is disabled on all six nodes"
    ;;
esac

trap - EXIT

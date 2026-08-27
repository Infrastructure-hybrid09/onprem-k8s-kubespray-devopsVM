#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

INFRA_IP="192.168.14.62"
CLIENT_CIDR="192.168.14.0/24"
UPSTREAM="3.kr.pool.ntp.org"
WAIT_SECONDS=45
CLIENT_TABLE_WAIT_SECONDS=90
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/neuroplan_k8s}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
MANAGE_INFRA_FIREWALL=0
ALLOW_INITIAL_STEP=0

K8S_NODES=(
  'cp1|192.168.14.31'
  'cp2|192.168.14.32'
  'cp3|192.168.14.33'
  'worker1|192.168.14.41'
  'worker2|192.168.14.42'
  'worker3|192.168.14.43'
)

ROOT_NODES=(
  'lb1|192.168.14.11'
  'lb2|192.168.14.12'
  'db-primary|192.168.14.51'
  'db-replica|192.168.14.52'
  'nfs|192.168.14.61'
)

usage() {
  cat <<'EOF'
Usage: ./01-bootstrap/08-configure-all-vm-ntp.sh [OPTIONS]

Run once on the DevOps VM as the devops user.

The script configures this fixed topology:
  Infra 192.168.14.62 -> upstream NTP
  all other 12 VMs   -> Infra 192.168.14.62

Options:
  --upstream HOST             Infra upstream source
                              (default: 3.kr.pool.ntp.org)
  --wait-seconds N            Per-host sync wait, 15-180 seconds
                              (default: 45)
  --manage-infra-firewall     If firewalld is active on Infra, add an
                              NTP rich rule limited to 192.168.14.0/24
  --allow-initial-step        Allow chronyd to step clocks over 1 second
                              during the first three updates. Use only
                              before Kubernetes/DB workloads start.
  -h, --help                  Show this help

Environment:
  SSH_KEY=/path/to/key        SSH key used for remote connections
  KNOWN_HOSTS=/path/to/file   Pinned OpenSSH known_hosts file

Accounts:
  CP1-3/Worker1-3 : k8sadmin + passwordless sudo + SSH key
  Infra/LB/DB/NFS : root; SSH may ask for the existing root password
  DevOps          : local devops; sudo may ask once for the local password

The script never stores or transmits a password. For a fully unattended run,
install the DevOps public key for root on Infra/LB/DB/NFS beforehand.
Without that key, Infra can ask once more during the final client-table proof.
EOF
}

die() {
  echo "[FAIL] $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --upstream)
      (( $# >= 2 )) || die "--upstream requires a value"
      UPSTREAM="$2"
      shift 2
      ;;
    --wait-seconds)
      (( $# >= 2 )) || die "--wait-seconds requires a value"
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --manage-infra-firewall)
      MANAGE_INFRA_FIREWALL=1
      shift
      ;;
    --allow-initial-step)
      ALLOW_INITIAL_STEP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

[[ ${EUID} -ne 0 ]] || die "run as devops, not root"
[[ "$(id -un)" == "devops" ]] || \
  die "expected local operator devops; current user is $(id -un)"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || \
  die "--wait-seconds must be an integer"
(( WAIT_SECONDS >= 15 && WAIT_SECONDS <= 180 )) || \
  die "--wait-seconds must be between 15 and 180"
[[ "$UPSTREAM" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
  die "invalid upstream hostname or IPv4 address: $UPSTREAM"

for command_name in awk chmod date getent grep install ip mktemp ssh \
  ssh-keygen stat sudo tee touch; do
  command -v "$command_name" >/dev/null || \
    die "required local command not found: $command_name"
done

[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] || \
  die "regular SSH private key not found: $SSH_KEY"
[[ -f "$KNOWN_HOSTS" && ! -L "$KNOWN_HOSTS" ]] || \
  die "regular known_hosts file not found: $KNOWN_HOSTS"

private_mode="$(stat -c '%a' "$SSH_KEY")"
if (( (8#${private_mode}) & 077 )); then
  die "SSH private key permissions are too open (${private_mode}): $SSH_KEY"
fi

ip -o -4 address show | grep -Fq ' 192.168.14.21/' || \
  die "this host does not own DevOps Management IP 192.168.14.21"

LOG_DIR="${PROJECT_ROOT}/logs"
install -d -m 0700 "$LOG_DIR"
LOG_FILE="${LOG_DIR}/08-ntp-all-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "NeuroPlan central NTP configuration"
echo "  operator       : $(id -un)@$(hostname -s)"
echo "  Infra server   : ${INFRA_IP}"
echo "  upstream       : ${UPSTREAM}"
echo "  client network : ${CLIENT_CIDR}"
echo "  log            : ${LOG_FILE}"
echo

declare -A SSH_TARGETS=()
all_remote_records=("infra|${INFRA_IP}" "${K8S_NODES[@]}" "${ROOT_NODES[@]}")
for node_record in "${all_remote_records[@]}"; do
  IFS='|' read -r node_name node_ip <<<"$node_record"
  if ! getent ahostsv4 "$node_name" |
      awk -v expected="$node_ip" '$1 == expected { found=1 } END { exit !found }'; then
    echo "[FAIL] ${node_name} does not resolve to expected Management IP ${node_ip}" >&2
    exit 2
  fi

  if ssh-keygen -F "$node_ip" -f "$KNOWN_HOSTS" >/dev/null; then
    SSH_TARGETS["$node_name"]="$node_ip"
  elif ssh-keygen -F "$node_name" -f "$KNOWN_HOSTS" >/dev/null; then
    SSH_TARGETS["$node_name"]="$node_name"
  else
    echo "[FAIL] no pinned host key for ${node_name} (${node_ip})" >&2
    echo "       verify its ED25519 fingerprint at the VM console, then connect once" >&2
    exit 2
  fi
done

COMMON_SSH_OPTIONS=(
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o IdentitiesOnly=yes
  -i "$SSH_KEY"
)

K8S_SSH_OPTIONS=(
  "${COMMON_SSH_OPTIONS[@]}"
  -o BatchMode=yes
  -o PasswordAuthentication=no
  -o KbdInteractiveAuthentication=no
  -o PreferredAuthentications=publickey
)

ROOT_SSH_OPTIONS=(
  "${COMMON_SSH_OPTIONS[@]}"
  -o BatchMode=no
  -o PreferredAuthentications=publickey,password,keyboard-interactive
)

remote_payload() {
  cat <<'REMOTE'
set -Eeuo pipefail
export LC_ALL=C
umask 077

ROLE="$1"
EXPECTED_NAME="$2"
EXPECTED_IP="$3"
INFRA_IP="$4"
CLIENT_CIDR="$5"
UPSTREAM="$6"
WAIT_SECONDS="$7"
MANAGE_INFRA_FIREWALL="$8"
ALLOW_INITIAL_STEP="$9"

CONFIG_FILE="/etc/chrony.conf"
BLOCK_BEGIN="# BEGIN NEUROPLAN CENTRAL NTP"
BLOCK_END="# END NEUROPLAN CENTRAL NTP"

fail() {
  local message="$*"
  if declare -F rollback_changed_config >/dev/null 2>&1; then
    rollback_changed_config || true
  fi
  echo "[FAIL] ${EXPECTED_NAME}: $message" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "remote payload must run as root"
[[ "$ROLE" == "server" || "$ROLE" == "client" ]] || \
  fail "invalid role: $ROLE"
ip -o -4 address show | grep -Fq " ${EXPECTED_IP}/" || \
  fail "expected Management IP is not present: $EXPECTED_IP"

for command_name in awk cat chmod chown cmp cp date grep ip mktemp mv rm \
  sleep ss systemctl timeout; do
  command -v "$command_name" >/dev/null || \
    fail "required command not found: $command_name"
done

if ! command -v chronyd >/dev/null || ! command -v chronyc >/dev/null; then
  command -v dnf >/dev/null || fail "chrony is missing and dnf is unavailable"
  dnf install -y chrony || fail "failed to install chrony"
fi

[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || \
  fail "expected a regular configuration file: $CONFIG_FILE"

query_source() {
  local source="$1" query_output="" attempt
  for attempt in 1 2 3; do
    if query_output="$(
      timeout 20 chronyd -Q -t 15 \
        "server ${source} iburst maxsamples 1" 2>&1
    )"; then
      return 0
    fi
    echo "[WARN] ${EXPECTED_NAME}: NTP query ${attempt}/3 failed for ${source}" >&2
    echo "$query_output" >&2
    sleep 2
  done
  return 1
}

if [[ "$ROLE" == "server" ]]; then
  command -v getent >/dev/null || fail "required command not found: getent"
  getent ahostsv4 "$UPSTREAM" >/dev/null || \
    fail "cannot resolve upstream source: $UPSTREAM"
  query_source "$UPSTREAM" || \
    fail "upstream did not answer NTP queries: $UPSTREAM"
else
  route_to_infra="$(ip -4 route get "$INFRA_IP" 2>&1 || true)"
  grep -Eq "(^|[[:space:]])src[[:space:]]+${EXPECTED_IP}([[:space:]]|$)" \
    <<<"$route_to_infra" || {
      echo "$route_to_infra" >&2
      fail "route to Infra does not use Management source $EXPECTED_IP"
    }
  query_source "$INFRA_IP" || \
    fail "Infra NTP server did not answer: $INFRA_IP"
fi

temp_config="$(mktemp /etc/.chrony.conf.neuroplan.XXXXXX)"
cleanup() {
  [[ -z "${temp_config:-}" ]] || rm -f -- "$temp_config"
}
trap cleanup EXIT

if ! awk \
    -v block_begin="$BLOCK_BEGIN" \
    -v block_end="$BLOCK_END" '
  function emit(line) {
    while (pending_blank_lines > 0) {
      print ""
      pending_blank_lines--
    }
    print line
  }
  function is_begin(line) {
    return line == block_begin ||
      line == "# BEGIN NEUROPLAN MANAGED NTP" ||
      line == "# BEGIN INFRAREADY NTP MANAGED BLOCK"
  }
  function is_end(line) {
    return line == block_end ||
      line == "# END NEUROPLAN MANAGED NTP" ||
      line == "# END INFRAREADY NTP MANAGED BLOCK"
  }
  is_begin($0) {
    if (in_managed_block) { exit 42 }
    pending_blank_lines = 0
    in_managed_block = 1
    next
  }
  is_end($0) {
    if (!in_managed_block) { exit 42 }
    in_managed_block = 0
    next
  }
  in_managed_block { next }
  /^[[:space:]]*$/ {
    pending_blank_lines++
    next
  }
  $1 ~ /^(server|pool|peer|refclock|sourcedir|include|confdir)$/ {
    emit("# NEUROPLAN DISABLED NTP SOURCE: " $0)
    next
  }
  $1 ~ /^(allow|deny|local|bindaddress|port|noclientlog)$/ {
    emit("# NEUROPLAN DISABLED NTP SERVER DIRECTIVE: " $0)
    next
  }
  $1 == "makestep" {
    emit("# NEUROPLAN DISABLED AUTOMATIC TIME STEP: " $0)
    next
  }
  { emit($0) }
  END {
    if (in_managed_block) { exit 42 }
  }
' "$CONFIG_FILE" >"$temp_config"; then
  fail "malformed managed NTP block in $CONFIG_FILE"
fi

cat >>"$temp_config" <<EOF

$BLOCK_BEGIN
EOF

if [[ "$ROLE" == "server" ]]; then
  cat >>"$temp_config" <<EOF
server $UPSTREAM iburst
allow $CLIENT_CIDR
bindaddress $INFRA_IP
EOF
else
  cat >>"$temp_config" <<EOF
server $INFRA_IP iburst prefer
port 0
EOF
fi

if (( ALLOW_INITIAL_STEP == 1 )); then
  echo 'makestep 1.0 3' >>"$temp_config"
fi
if ! grep -Eq '^[[:space:]]*rtcsync([[:space:]]|$)' "$temp_config"; then
  echo 'rtcsync' >>"$temp_config"
fi
echo "$BLOCK_END" >>"$temp_config"

if ! parsed_config="$(chronyd -p -f "$temp_config" 2>&1)"; then
  echo "$parsed_config" >&2
  fail "generated chrony configuration did not validate"
fi

if [[ "$ROLE" == "server" ]]; then
  awk -v expected="$UPSTREAM" '
    $1 ~ /^(server|pool|peer|refclock|sourcedir|include|confdir)$/ {
      source_count++
      if ($1 == "server" && $2 == expected) { expected_source = 1 }
    }
    END { exit !(source_count == 1 && expected_source == 1) }
  ' <<<"$parsed_config" || {
    echo "$parsed_config" >&2
    fail "effective Infra configuration has an unexpected NTP source"
  }
else
  awk -v expected="$INFRA_IP" '
    $1 ~ /^(server|pool|peer|refclock|sourcedir|include|confdir)$/ {
      source_count++
      if ($1 == "server" && $2 == expected) { expected_source = 1 }
    }
    END { exit !(source_count == 1 && expected_source == 1) }
  ' <<<"$parsed_config" || {
    echo "$parsed_config" >&2
    fail "effective client configuration does not use Infra exclusively"
  }
fi

backup_file=""
configuration_changed=0
if cmp -s "$temp_config" "$CONFIG_FILE"; then
  echo "[INFO] ${EXPECTED_NAME}: chrony configuration already current"
else
  backup_file="$(mktemp "${CONFIG_FILE}.neuroplan-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  cp -a -- "$CONFIG_FILE" "$backup_file"
  chown root:root "$temp_config"
  chmod 0644 "$temp_config"
  mv -f -- "$temp_config" "$CONFIG_FILE"
  temp_config=""
  command -v restorecon >/dev/null && \
    restorecon -F "$CONFIG_FILE" 2>/dev/null || true
  configuration_changed=1
  echo "[INFO] ${EXPECTED_NAME}: backup=${backup_file}"
fi

rollback_changed_config() {
  local rollback_status=0 rollback_temp=""
  if (( ${firewall_runtime_added:-0} == 1 )); then
    firewall-cmd --zone="$management_zone" \
      --remove-rich-rule="$ntp_rule" >/dev/null || rollback_status=1
    firewall_runtime_added=0
  fi
  if (( ${firewall_permanent_added:-0} == 1 )); then
    firewall-cmd --zone="$management_zone" --permanent \
      --remove-rich-rule="$ntp_rule" >/dev/null || rollback_status=1
    firewall_permanent_added=0
  fi
  if (( configuration_changed == 1 )) && \
     [[ -n "$backup_file" && -f "$backup_file" ]]; then
    echo "[INFO] ${EXPECTED_NAME}: restoring previous chrony configuration" >&2
    rollback_temp="$(mktemp /etc/.chrony.conf.rollback.XXXXXX)"
    if cp -a -- "$backup_file" "$rollback_temp" && \
       mv -f -- "$rollback_temp" "$CONFIG_FILE"; then
      rollback_temp=""
    else
      rm -f -- "$rollback_temp"
      rollback_status=1
    fi
    if (( rollback_status == 0 )); then
      command -v restorecon >/dev/null && \
        restorecon -F "$CONFIG_FILE" 2>/dev/null || true
    fi
    if (( rollback_status == 0 )) && systemctl restart chronyd; then
      echo "[INFO] ${EXPECTED_NAME}: rollback completed; backup=${backup_file}" >&2
      configuration_changed=0
    else
      echo "[FAIL] ${EXPECTED_NAME}: rollback service restart failed" >&2
      echo "       preserved backup: $backup_file" >&2
      rollback_status=1
    fi
  fi
  return "$rollback_status"
}

systemctl enable chronyd >/dev/null || fail "failed to enable chronyd"
if (( configuration_changed == 1 )) || ! systemctl is-active --quiet chronyd; then
  if ! systemctl restart chronyd; then
    echo "[FAIL] ${EXPECTED_NAME}: chronyd restart failed" >&2
    rollback_changed_config || true
    exit 1
  fi
fi
systemctl is-active --quiet chronyd || fail "chronyd is not active"
chronyc online >/dev/null 2>&1 || true
chronyc burst 4/4 >/dev/null 2>&1 || true

firewall_runtime_added=0
firewall_permanent_added=0
if [[ "$ROLE" == "server" ]] && systemctl is-active --quiet firewalld; then
  command -v firewall-cmd >/dev/null || \
    fail "firewalld is active but firewall-cmd is missing"
  management_interface="$(
    ip -o -4 address show | awk -v expected="$INFRA_IP/" \
      'index($4, expected) == 1 { print $2; exit }'
  )"
  [[ -n "$management_interface" ]] || \
    fail "could not identify the Infra Management interface"
  management_zone="$(firewall-cmd --get-zone-of-interface="$management_interface")"
  if [[ -z "$management_zone" || "$management_zone" == "no zone" ]]; then
    management_zone="$(firewall-cmd --get-default-zone)"
  fi

  ntp_rule="rule family=\"ipv4\" source address=\"${CLIENT_CIDR}\" service name=\"ntp\" accept"
  runtime_firewall_ok=0
  permanent_firewall_ok=0
  runtime_service_open=0
  permanent_service_open=0
  firewall-cmd --zone="$management_zone" \
    --query-service=ntp >/dev/null && runtime_service_open=1
  firewall-cmd --zone="$management_zone" --permanent \
    --query-service=ntp >/dev/null && permanent_service_open=1

  if (( runtime_service_open == 1 )) ||
     firewall-cmd --zone="$management_zone" \
       --query-rich-rule="$ntp_rule" >/dev/null; then
    runtime_firewall_ok=1
  fi
  if (( permanent_service_open == 1 )) ||
     firewall-cmd --zone="$management_zone" --permanent \
       --query-rich-rule="$ntp_rule" >/dev/null; then
    permanent_firewall_ok=1
  fi

  if (( runtime_service_open == 1 || permanent_service_open == 1 )); then
    echo "[WARN] ${EXPECTED_NAME}: existing zone-wide NTP service is open in ${management_zone}; preserved for Network review" >&2
  fi

  if (( runtime_firewall_ok == 0 || permanent_firewall_ok == 0 )); then
    if (( MANAGE_INFRA_FIREWALL == 1 )); then
      if (( runtime_firewall_ok == 0 )); then
        firewall-cmd --zone="$management_zone" \
          --add-rich-rule="$ntp_rule" >/dev/null || \
          fail "failed to add runtime Infra NTP firewall rule"
        firewall_runtime_added=1
      fi
      if (( permanent_firewall_ok == 0 )); then
        firewall-cmd --zone="$management_zone" --permanent \
          --add-rich-rule="$ntp_rule" >/dev/null || \
          fail "failed to add permanent Infra NTP firewall rule"
        firewall_permanent_added=1
      fi
      echo "[INFO] ${EXPECTED_NAME}: added source-limited NTP rule to firewalld zone ${management_zone}"
    else
      fail "Infra firewalld blocks NTP; rerun with --manage-infra-firewall after Network approval"
    fi
  fi
fi

synced=0
for (( attempt = 1; attempt <= WAIT_SECONDS; attempt++ )); do
  if chronyc tracking 2>/dev/null | \
       grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal[[:space:]]*$' && \
     chronyc -n sources 2>/dev/null | grep -Eq '^\^\*'; then
    synced=1
    break
  fi
  sleep 1
done

if (( synced == 0 )); then
  chronyc tracking >&2 || true
  chronyc -n sources -v >&2 || true
  command -v journalctl >/dev/null && \
    journalctl -u chronyd -b --no-pager -n 60 >&2 || true
  fail "did not reach synchronised state within ${WAIT_SECONDS}s"
fi

if [[ "$ROLE" == "server" ]]; then
  ss -H -lun | awk -v expected="$INFRA_IP:123" '
    {
      for (field = 1; field <= NF; field++) {
        if ($field == expected || $field == "0.0.0.0:123" ||
            $field == "*:123" || $field == "[::]:123" ||
            $field == ":::123") {
          found = 1
        }
      }
    }
    END { exit !found }
  ' || fail "UDP/123 is not listening on $INFRA_IP"

  access_result="$(chronyc accheck 192.168.14.21 2>&1 || true)"
  grep -Fq 'Access allowed' <<<"$access_result" || \
    fail "DevOps client 192.168.14.21 is not allowed"
else
  sources="$(chronyc -n sources 2>/dev/null)"
  selected_source="$(
    awk '$1 == "^*" { print $2 }' <<<"$sources"
  )"
  [[ "$selected_source" == "$INFRA_IP" ]] || {
    echo "$sources" >&2
    fail "selected source is not Infra: ${selected_source:-none}"
  }
  unexpected_sources="$(
    awk -v expected="$INFRA_IP" \
      '$1 ~ /^\^/ && $2 != expected { print $2 }' <<<"$sources"
  )"
  [[ -z "$unexpected_sources" ]] || {
    echo "$sources" >&2
    fail "unexpected additional NTP source(s): $unexpected_sources"
  }
fi

source_summary="$(
  chronyc -n sources 2>/dev/null |
    awk '$1 == "^*" { print $2; exit }'
)"
echo "[PASS] ${EXPECTED_NAME}: role=${ROLE} source=${source_summary:-unknown} leap=Normal"
REMOTE
}

run_infra_server() {
  echo "===== infra (${INFRA_IP}) : NTP SERVER ====="
  remote_payload |
    ssh "${ROOT_SSH_OPTIONS[@]}" "root@${SSH_TARGETS[infra]}" \
      bash -s -- \
      server infra "$INFRA_IP" "$INFRA_IP" "$CLIENT_CIDR" \
      "$UPSTREAM" "$WAIT_SECONDS" "$MANAGE_INFRA_FIREWALL" \
      "$ALLOW_INITIAL_STEP"
}

run_local_devops_client() {
  echo "===== devops (192.168.14.21) : NTP CLIENT ====="
  remote_payload |
    sudo bash -s -- \
      client devops 192.168.14.21 "$INFRA_IP" "$CLIENT_CIDR" \
      "$UPSTREAM" "$WAIT_SECONDS" 0 "$ALLOW_INITIAL_STEP"
}

run_k8s_client() {
  local node_name="$1" node_ip="$2"
  echo "===== ${node_name} (${node_ip}) : NTP CLIENT ====="
  remote_payload |
    ssh "${K8S_SSH_OPTIONS[@]}" "k8sadmin@${SSH_TARGETS[$node_name]}" \
      sudo -n bash -s -- \
      client "$node_name" "$node_ip" "$INFRA_IP" "$CLIENT_CIDR" \
      "$UPSTREAM" "$WAIT_SECONDS" 0 "$ALLOW_INITIAL_STEP"
}

run_root_client() {
  local node_name="$1" node_ip="$2"
  echo "===== ${node_name} (${node_ip}) : NTP CLIENT ====="
  remote_payload |
    ssh "${ROOT_SSH_OPTIONS[@]}" "root@${SSH_TARGETS[$node_name]}" \
      bash -s -- \
      client "$node_name" "$node_ip" "$INFRA_IP" "$CLIENT_CIDR" \
      "$UPSTREAM" "$WAIT_SECONDS" 0 "$ALLOW_INITIAL_STEP"
}

infra_clients_payload() {
  cat <<'REMOTE_CLIENTS'
set -Eeuo pipefail
export LC_ALL=C

wait_seconds="$1"
shift
expected_clients=("$@")

for (( attempt = 1; attempt <= wait_seconds; attempt++ )); do
  client_table="$(chronyc clients -n 2>&1 || true)"
  missing_clients=()
  for client_ip in "${expected_clients[@]}"; do
    if ! awk -v expected="$client_ip" \
      '$1 == expected { found=1 } END { exit !found }' <<<"$client_table"; then
      missing_clients+=("$client_ip")
    fi
  done

  if (( ${#missing_clients[@]} == 0 )); then
    echo "$client_table"
    echo "[PASS] Infra observed all ${#expected_clients[@]} expected NTP clients"
    exit 0
  fi
  sleep 1
done

echo "$client_table" >&2
printf '[FAIL] Infra client table is missing: %s\n' \
  "${missing_clients[*]}" >&2
exit 1
REMOTE_CLIENTS
}

verify_infra_clients() {
  local expected_client_ips=(192.168.14.21)
  local node_record node_name node_ip
  for node_record in "${K8S_NODES[@]}" "${ROOT_NODES[@]}"; do
    IFS='|' read -r node_name node_ip <<<"$node_record"
    expected_client_ips+=("$node_ip")
  done

  echo "===== infra (${INFRA_IP}) : CLIENT TABLE ====="
  infra_clients_payload |
    ssh "${ROOT_SSH_OPTIONS[@]}" "root@${SSH_TARGETS[infra]}" \
      bash -s -- "$CLIENT_TABLE_WAIT_SECONDS" "${expected_client_ips[@]}"
}

echo "Infra is configured and verified before any client is changed."
echo "Root SSH passwords may be requested by OpenSSH and are never logged."
echo

if ! run_infra_server; then
  die "Infra NTP server preparation failed; no client was changed"
fi

client_passes=0
client_failures=0
failed_clients=()

if run_local_devops_client; then
  client_passes=$((client_passes + 1))
else
  client_failures=$((client_failures + 1))
  failed_clients+=(devops)
fi

for node_record in "${K8S_NODES[@]}"; do
  IFS='|' read -r node_name node_ip <<<"$node_record"
  if run_k8s_client "$node_name" "$node_ip"; then
    client_passes=$((client_passes + 1))
  else
    client_failures=$((client_failures + 1))
    failed_clients+=("$node_name")
  fi
done

for node_record in "${ROOT_NODES[@]}"; do
  IFS='|' read -r node_name node_ip <<<"$node_record"
  if run_root_client "$node_name" "$node_ip"; then
    client_passes=$((client_passes + 1))
  else
    client_failures=$((client_failures + 1))
    failed_clients+=("$node_name")
  fi
done

infra_clients_status="SKIPPED"
if (( client_failures == 0 )); then
  if verify_infra_clients; then
    infra_clients_status="PASS (12/12 observed)"
  else
    infra_clients_status="FAIL"
    client_failures=$((client_failures + 1))
    failed_clients+=(infra-client-table)
  fi
fi

echo
echo "===== RESULT ====="
echo "Infra server : PASS"
echo "NTP clients  : ${client_passes}/12 PASS"
echo "Infra table  : ${infra_clients_status}"
echo "log          : ${LOG_FILE}"

if (( client_failures > 0 )); then
  printf 'failed hosts : %s\n' "${failed_clients[*]}" >&2
  echo "Fix SSH/network/chrony on the listed hosts, then rerun this idempotent script." >&2
  exit 1
fi

echo "[PASS] central NTP topology completed"
echo "       Infra -> ${UPSTREAM}"
echo "       12 clients -> ${INFRA_IP}"
echo
echo "Optional Infra-side evidence:"
echo "  ssh root@${INFRA_IP} 'chronyc clients -n'"

#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

EXPECTED_INFRA_IP="192.168.14.62"
EXPECTED_PREFIX="24"
CLIENT_CIDR="192.168.14.0/24"
TEST_CLIENT_IP="192.168.14.31"
UPSTREAM="3.kr.pool.ntp.org"
WAIT_SECONDS=30
CONFIG_FILE="/etc/chrony.conf"
BLOCK_BEGIN="# BEGIN NEUROPLAN MANAGED NTP"
BLOCK_END="# END NEUROPLAN MANAGED NTP"

usage() {
  cat <<'EOF'
Usage: ./07-configure-infra-ntp.sh [OPTIONS]

Run only on the Infra VM (192.168.14.62) as root.

Options:
  --upstream HOST    Upstream NTP hostname or IPv4 address
                     (default: 3.kr.pool.ntp.org)
  --wait-seconds N   Maximum initial synchronisation wait, 5-120 seconds
                     (default: 30)
  -h, --help         Show this help

This script configures chronyd and verifies firewalld. It never changes
firewalld policy; the Network owner must approve and apply a missing NTP rule.
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

[[ ${EUID} -eq 0 ]] || die "run on the Infra VM as root"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be an integer"
(( WAIT_SECONDS >= 5 && WAIT_SECONDS <= 120 )) || \
  die "--wait-seconds must be between 5 and 120"
[[ "$UPSTREAM" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
  die "invalid upstream hostname or IPv4 address: $UPSTREAM"

ip -o -4 address show | grep -Fq " ${EXPECTED_INFRA_IP}/${EXPECTED_PREFIX}" || \
  die "this host does not own ${EXPECTED_INFRA_IP}/${EXPECTED_PREFIX}; refusing to change chrony"

for command in awk cmp date getent grep install ip journalctl mktemp \
  ss systemctl timedatectl timeout; do
  command -v "$command" >/dev/null || die "required command not found: $command"
done

if ! command -v chronyd >/dev/null || ! command -v chronyc >/dev/null; then
  command -v dnf >/dev/null || die "chrony is missing and dnf is unavailable"
  dnf install -y chrony
fi

[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || \
  die "expected a regular configuration file: $CONFIG_FILE"

getent ahostsv4 "$UPSTREAM" >/dev/null || \
  die "cannot resolve or validate upstream NTP source: $UPSTREAM"

if ! awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
  $0 == begin {
    if (seen_begin || in_managed_block) { exit 2 }
    seen_begin = 1
    in_managed_block = 1
    next
  }
  $0 == end {
    if (!in_managed_block || seen_end) { exit 2 }
    seen_end = 1
    in_managed_block = 0
    next
  }
  END {
    if (in_managed_block || seen_begin != seen_end) { exit 2 }
  }
' "$CONFIG_FILE"; then
  die "malformed Neuroplan managed block in $CONFIG_FILE"
fi

if awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
  $0 == begin { in_managed_block = 1; next }
  $0 == end   { in_managed_block = 0; next }
  !in_managed_block && $1 == "local" { found = 1 }
  END { exit !found }
' "$CONFIG_FILE"; then
  die "an unmanaged active 'local' directive exists; review $CONFIG_FILE manually"
fi

if awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" \
    -v client_cidr="$CLIENT_CIDR" '
  $0 == begin { in_managed_block = 1; next }
  $0 == end   { in_managed_block = 0; next }
  !in_managed_block && $1 == "allow" && $2 != client_cidr { found = 1 }
  END { exit !found }
' "$CONFIG_FILE"; then
  die "an unmanaged allow outside $CLIENT_CIDR exists; review $CONFIG_FILE manually"
fi

if awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" \
    -v expected_ip="$EXPECTED_INFRA_IP" '
  $0 == begin { in_managed_block = 1; next }
  $0 == end   { in_managed_block = 0; next }
  in_managed_block { next }
  $1 == "port" && $2 == "0" { found = 1 }
  $1 == "bindaddress" && $2 != expected_ip && $2 != "0.0.0.0" &&
    $2 != "::" && $2 != "*" { found = 1 }
  END { exit !found }
' "$CONFIG_FILE"; then
  die "an unmanaged port 0 or incompatible bindaddress exists; review $CONFIG_FILE manually"
fi

temp_config="$(mktemp /etc/.chrony.conf.neuroplan.XXXXXX)"
cleanup() {
  [[ -z "${temp_config:-}" ]] || rm -f -- "$temp_config"
}
trap cleanup EXIT

awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" \
    -v upstream="$UPSTREAM" -v client_cidr="$CLIENT_CIDR" '
  $0 == begin { in_managed_block = 1; next }
  $0 == end   { in_managed_block = 0; next }
  in_managed_block { next }
  ($1 == "server" || $1 == "pool") && $2 == upstream { next }
  $1 == "allow" && $2 == client_cidr { next }
  { print }
' "$CONFIG_FILE" >"$temp_config"

source_directive="pool"
if [[ "$UPSTREAM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  source_directive="server"
fi

cat >>"$temp_config" <<EOF

$BLOCK_BEGIN
$source_directive $UPSTREAM iburst
allow $CLIENT_CIDR
EOF

if ! grep -Eq '^[[:space:]]*makestep[[:space:]]+' "$temp_config"; then
  echo 'makestep 1.0 3' >>"$temp_config"
fi
if ! grep -Eq '^[[:space:]]*rtcsync([[:space:]]|$)' "$temp_config"; then
  echo 'rtcsync' >>"$temp_config"
fi
echo "$BLOCK_END" >>"$temp_config"

chronyd -p -f "$temp_config" >/dev/null || \
  die "generated chrony configuration failed validation"

backup_file=""
configuration_changed=0
if cmp -s "$temp_config" "$CONFIG_FILE"; then
  echo "[PASS] chrony configuration is already current"
else
  backup_file="$(mktemp "${CONFIG_FILE}.neuroplan-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
  cp -a -- "$CONFIG_FILE" "$backup_file"
  chown root:root "$temp_config"
  chmod 0644 "$temp_config"
  mv -f -- "$temp_config" "$CONFIG_FILE"
  temp_config=""
  if command -v restorecon >/dev/null; then
    restorecon -F "$CONFIG_FILE" 2>/dev/null || true
  fi
  configuration_changed=1
  echo "[PASS] chrony configuration updated"
  echo "       backup: $backup_file"
fi

systemctl enable chronyd >/dev/null
if (( configuration_changed == 1 )) || ! systemctl is-active --quiet chronyd; then
  if ! systemctl restart chronyd; then
    if [[ -n "$backup_file" ]]; then
      echo "chronyd restart failed. Review the service log, or restore with:" >&2
      echo "  cp -a '$backup_file' '$CONFIG_FILE'" >&2
      echo "  systemctl restart chronyd" >&2
    fi
    exit 1
  fi
fi
systemctl is-active --quiet chronyd || die "chronyd did not become active"
chronyc online >/dev/null 2>&1 || true
chronyc burst 4/4 >/dev/null 2>&1 || true

echo "Waiting up to ${WAIT_SECONDS}s for upstream synchronisation"
synchronised=0
for (( attempt = 1; attempt <= WAIT_SECONDS; attempt++ )); do
  if chronyc tracking 2>/dev/null | \
       grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal[[:space:]]*$' && \
     chronyc -n sources 2>/dev/null | grep -Eq '^\^\*'; then
    synchronised=1
    break
  fi
  sleep 1
done

if (( synchronised == 0 )); then
  echo "[FAIL] Infra did not synchronise with $UPSTREAM" >&2
  getent ahostsv4 "$UPSTREAM" >&2 || true
  chronyc -n sources -v >&2 || true
  chronyc tracking >&2 || true
  journalctl -u chronyd -b --no-pager -n 80 >&2 || true
  echo "Check Infra DNS/NAT and outbound UDP/123. The previous configuration backup was preserved." >&2
  exit 1
fi

if ! direct_query_output="$(
  timeout 20 chronyd -Q -t 15 \
    "server $UPSTREAM iburst maxsamples 1" 2>&1
)"; then
  echo "$direct_query_output" >&2
  die "direct read-only query to configured upstream $UPSTREAM failed"
fi
echo "[PASS] configured upstream responded to a direct read-only query"

if ! ss -H -lun | awk -v expected_ip="$EXPECTED_INFRA_IP" '
  {
    for (field = 1; field <= NF; field++) {
      endpoint = $field
      if (endpoint == "0.0.0.0:123" || endpoint == "*:123" ||
          endpoint == "[::]:123" || endpoint == ":::123" ||
          endpoint == expected_ip ":123") {
        found = 1
      }
    }
  }
  END { exit !found }
'; then
  ss -lunp >&2 || true
  die "UDP/123 is not listening on wildcard or $EXPECTED_INFRA_IP"
fi

access_result="$(chronyc accheck "$TEST_CLIENT_IP" 2>&1 || true)"
grep -Fq 'Access allowed' <<<"$access_result" || {
  echo "$access_result" >&2
  die "chronyd does not allow test client $TEST_CLIENT_IP"
}

management_interface="$(
  ip -o -4 address show | \
    awk -v expected="${EXPECTED_INFRA_IP}/${EXPECTED_PREFIX}" \
      '$4 == expected { print $2; exit }'
)"
[[ -n "$management_interface" ]] || die "could not identify the Management interface"

if systemctl is-active --quiet firewalld; then
  command -v firewall-cmd >/dev/null || \
    die "firewalld is active but firewall-cmd is unavailable"
  management_zone="$(firewall-cmd --get-zone-of-interface="$management_interface")"
  if [[ -z "$management_zone" || "$management_zone" == "no zone" ]]; then
    management_zone="$(firewall-cmd --get-default-zone)"
    echo "[INFO] Management interface has no explicit zone; effective default is $management_zone"
  fi
  runtime_ntp=0
  permanent_ntp=0
  firewall-cmd --zone="$management_zone" --query-service=ntp >/dev/null && runtime_ntp=1
  firewall-cmd --zone="$management_zone" --permanent \
    --query-service=ntp >/dev/null && permanent_ntp=1
  if (( runtime_ntp == 0 || permanent_ntp == 0 )); then
    echo "[FAIL] firewalld NTP rule is incomplete in zone $management_zone" >&2
    echo "       runtime=$runtime_ntp permanent=$permanent_ntp" >&2
    echo "Network owner action required:" >&2
    echo "  firewall-cmd --zone='$management_zone' --add-service=ntp" >&2
    echo "  firewall-cmd --zone='$management_zone' --permanent --add-service=ntp" >&2
    exit 1
  fi
  echo "[PASS] firewalld zone $management_zone allows NTP at runtime and after reboot"
else
  echo "[INFO] firewalld is inactive; verify the external Network policy allows UDP/123"
fi

echo "[PASS] Infra NTP server is ready"
echo "       local address : ${EXPECTED_INFRA_IP}"
echo "       upstream      : ${source_directive} ${UPSTREAM}"
echo "       allowed CIDR  : ${CLIENT_CIDR}"
echo "       client check  : ${access_result}"
chronyc -n sources -v
chronyc tracking
ss -lunp | grep ':123'
echo
echo "Next, verify from the DevOps VM:"
echo "  ssh -i ~/.ssh/neuroplan_k8s k8sadmin@cp1 'sudo timeout 15 chronyd -Q -t 10 \"server ${EXPECTED_INFRA_IP} iburst\"'"

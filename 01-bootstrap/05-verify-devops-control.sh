#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
BASELINE_INVENTORY="${PROJECT_ROOT}/02-ansible/inventory/hosts.yaml"
KUBESPRAY_INVENTORY="${PROJECT_ROOT}/03-kubespray/inventory/mycluster/hosts.yaml"
BASELINE_ANSIBLE_CONFIG="${PROJECT_ROOT}/02-ansible/ansible.cfg"
KUBESPRAY_ANSIBLE_CONFIG="${PROJECT_ROOT}/03-kubespray/ansible.cfg"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/neuroplan_k8s}"
KNOWN_HOSTS="${KNOWN_HOSTS:-${HOME}/.ssh/known_hosts}"
REMOTE_USER="k8sadmin"

print_key_repair_hint() {
  echo "repair the public key without replacing the private key:" >&2
  echo "  bash '${PROJECT_ROOT}/01-bootstrap/06-repair-devops-public-key.sh'" >&2
}

inventory_host_names() {
  local inventory="$1"
  awk '
    /^  hosts:[[:space:]]*$/ { in_hosts = 1; next }
    in_hosts && /^  vars:[[:space:]]*$/ { exit }
    in_hosts && /^    [^[:space:]][^:]*:[[:space:]]*$/ {
      name = $0
      sub(/^    /, "", name)
      sub(/:[[:space:]]*$/, "", name)
      print name
    }
  ' "${inventory}"
}

inventory_host_has() {
  local inventory="$1" host="$2" key="$3" value="$4"
  awk -v host="${host}" -v key="${key}:" -v value="${value}" '
    $0 == "    " host ":" { in_host = 1; next }
    in_host && /^    [^[:space:]][^:]*:[[:space:]]*$/ { exit }
    in_host && /^  [^[:space:]]/ { exit }
    in_host && $1 == key && $2 == value { found = 1 }
    END { exit !found }
  ' "${inventory}"
}

inventory_group_host_names() {
  local inventory="$1" group="$2"
  awk -v group="${group}" '
    $0 == "    " group ":" { in_group = 1; next }
    in_group && /^    [^[:space:]][^:]*:[[:space:]]*$/ { exit }
    in_group && /^      hosts:[[:space:]]*$/ { in_hosts = 1; next }
    in_group && in_hosts && /^        [^[:space:]][^:]*:[[:space:]]*$/ {
      name = $0
      sub(/^        /, "", name)
      sub(/:[[:space:]]*$/, "", name)
      print name
    }
    in_group && in_hosts && /^      [^[:space:]]/ { in_hosts = 0 }
  ' "${inventory}"
}

inventory_group_child_names() {
  local inventory="$1" group="$2"
  awk -v group="${group}" '
    $0 == "    " group ":" { in_group = 1; next }
    in_group && /^    [^[:space:]][^:]*:[[:space:]]*$/ { exit }
    in_group && /^      children:[[:space:]]*$/ { in_children = 1; next }
    in_group && in_children && /^        [^[:space:]][^:]*:[[:space:]]*$/ {
      name = $0
      sub(/^        /, "", name)
      sub(/:[[:space:]]*$/, "", name)
      print name
    }
    in_group && in_children && /^      [^[:space:]]/ { in_children = 0 }
  ' "${inventory}"
}

inventory_declared_host_names() {
  local inventory="$1"
  awk '
    function indentation(line, stripped) {
      stripped = line
      sub(/^ */, "", stripped)
      return length(line) - length(stripped)
    }
    {
      indent = indentation($0)
      if ($0 ~ /^ *hosts:[[:space:]]*$/) {
        in_hosts = 1
        hosts_indent = indent
        next
      }
      if (in_hosts && indent <= hosts_indent) {
        in_hosts = 0
      }
      if (in_hosts && indent == hosts_indent + 2 &&
          $0 ~ /^ *[A-Za-z0-9_-]+:[[:space:]]*$/) {
        name = $0
        sub(/^ */, "", name)
        sub(/:[[:space:]]*$/, "", name)
        print name
      }
    }
  ' "${inventory}"
}

assert_group_hosts() {
  local inventory="$1" group="$2" actual expected
  shift 2
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  actual="$(inventory_group_host_names "${inventory}" "${group}" | LC_ALL=C sort)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "inventory group ${group} has an unexpected host set: ${inventory}" >&2
    printf 'actual hosts:\n%s\n' "${actual}" >&2
    exit 2
  fi
}

assert_group_children() {
  local inventory="$1" group="$2" actual expected
  shift 2
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  actual="$(inventory_group_child_names "${inventory}" "${group}" | LC_ALL=C sort)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "inventory group ${group} has an unexpected child-group set: ${inventory}" >&2
    printf 'actual children:\n%s\n' "${actual}" >&2
    exit 2
  fi
}

if [[ ${EUID} -eq 0 ]]; then
  echo "run on the PC2 DevOps VM as devops, not root" >&2
  exit 1
fi

if [[ "$(id -un)" != "devops" ]]; then
  echo "expected local operator 'devops'; current user is '$(id -un)'" >&2
  exit 1
fi

for required_file in \
  "${BASELINE_INVENTORY}" \
  "${KUBESPRAY_INVENTORY}" \
  "${BASELINE_ANSIBLE_CONFIG}" \
  "${KUBESPRAY_ANSIBLE_CONFIG}" \
  "${SSH_KEY}" \
  "${KNOWN_HOSTS}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "required file not found: ${required_file}" >&2
    exit 2
  fi
done

if [[ ! -f "${SSH_KEY}.pub" || -L "${SSH_KEY}.pub" ]]; then
  echo "regular public key not found: ${SSH_KEY}.pub" >&2
  print_key_repair_hint
  exit 2
fi

for ansible_config in "${BASELINE_ANSIBLE_CONFIG}" "${KUBESPRAY_ANSIBLE_CONFIG}"; do
  grep -Eqi '^[[:space:]]*host_key_checking[[:space:]]*=[[:space:]]*true[[:space:]]*$' "${ansible_config}" || {
    echo "host_key_checking is not enabled: ${ansible_config}" >&2
    exit 2
  }
  grep -Fq 'StrictHostKeyChecking=yes' "${ansible_config}" || {
    echo "strict SSH host checking is not configured: ${ansible_config}" >&2
    exit 2
  }
  grep -Fq 'IdentitiesOnly=yes' "${ansible_config}" || {
    echo "exclusive SSH identity use is not configured: ${ansible_config}" >&2
    exit 2
  }
  if grep -Fq 'UserKnownHostsFile=/dev/null' "${ansible_config}"; then
    echo "unsafe known_hosts bypass found: ${ansible_config}" >&2
    exit 2
  fi
done

for inventory in "${BASELINE_INVENTORY}" "${KUBESPRAY_INVENTORY}"; do
  if ! grep -Eq '^[[:space:]]+ansible_user:[[:space:]]+k8sadmin[[:space:]]*$' "${inventory}"; then
    echo "inventory does not fix ansible_user to k8sadmin: ${inventory}" >&2
    exit 2
  fi
done

if ! grep -Eq '^[[:space:]]+ansible_become:[[:space:]]+true[[:space:]]*$' "${BASELINE_INVENTORY}"; then
  echo "baseline inventory does not enable ansible_become: ${BASELINE_INVENTORY}" >&2
  exit 2
fi

# Kubespray entrypoints pass -b explicitly.  Setting ansible_become under
# all.vars also affects delegate_to: localhost tasks and makes the unprivileged
# DevOps artifact copy request a local sudo password.
if grep -Eq '^[[:space:]]+ansible_become:[[:space:]]+true[[:space:]]*$' "${KUBESPRAY_INVENTORY}"; then
  echo "Kubespray inventory must not set global ansible_become; entrypoints use -b: ${KUBESPRAY_INVENTORY}" >&2
  exit 2
fi

expected_baseline_hosts="$(printf '%s\n' devops cp1 cp2 cp3 worker1 worker2 worker3 | LC_ALL=C sort)"
actual_baseline_hosts="$(inventory_host_names "${BASELINE_INVENTORY}" | LC_ALL=C sort)"
if [[ "${actual_baseline_hosts}" != "${expected_baseline_hosts}" ]]; then
  echo "baseline inventory must contain exactly devops, cp1-3 and worker1-3" >&2
  printf 'actual hosts:\n%s\n' "${actual_baseline_hosts}" >&2
  exit 2
fi
actual_baseline_declared="$(inventory_declared_host_names "${BASELINE_INVENTORY}" | LC_ALL=C sort -u)"
if [[ "${actual_baseline_declared}" != "${expected_baseline_hosts}" ]]; then
  echo "baseline inventory declares a host outside devops, cp1-3 and worker1-3" >&2
  printf 'declared hosts:\n%s\n' "${actual_baseline_declared}" >&2
  exit 2
fi

expected_kubespray_hosts="$(printf '%s\n' cp1 cp2 cp3 worker1 worker2 worker3 | LC_ALL=C sort)"
actual_kubespray_hosts="$(inventory_host_names "${KUBESPRAY_INVENTORY}" | LC_ALL=C sort)"
if [[ "${actual_kubespray_hosts}" != "${expected_kubespray_hosts}" ]]; then
  echo "Kubespray inventory must contain exactly cp1-3 and worker1-3" >&2
  printf 'actual hosts:\n%s\n' "${actual_kubespray_hosts}" >&2
  exit 2
fi
actual_kubespray_declared="$(inventory_declared_host_names "${KUBESPRAY_INVENTORY}" | LC_ALL=C sort -u)"
if [[ "${actual_kubespray_declared}" != "${expected_kubespray_hosts}" ]]; then
  echo "Kubespray inventory declares a host outside cp1-3 and worker1-3" >&2
  printf 'declared hosts:\n%s\n' "${actual_kubespray_declared}" >&2
  exit 2
fi

assert_group_hosts "${BASELINE_INVENTORY}" control_plane_nodes cp1 cp2 cp3
assert_group_hosts "${BASELINE_INVENTORY}" worker_nodes worker1 worker2 worker3
assert_group_children "${BASELINE_INVENTORY}" kubernetes_nodes control_plane_nodes worker_nodes
assert_group_hosts "${KUBESPRAY_INVENTORY}" kube_control_plane cp1 cp2 cp3
assert_group_hosts "${KUBESPRAY_INVENTORY}" etcd cp1 cp2 cp3
assert_group_hosts "${KUBESPRAY_INVENTORY}" kube_node worker1 worker2 worker3
assert_group_children "${KUBESPRAY_INVENTORY}" k8s_cluster kube_control_plane kube_node

private_mode="$(stat -c '%a' "${SSH_KEY}")"
if (( (8#${private_mode}) & 077 )); then
  echo "private key permissions are too open (${private_mode}): ${SSH_KEY}" >&2
  echo "fix with: chmod 0600 '${SSH_KEY}'" >&2
  exit 2
fi

if [[ "$(wc -l <"${SSH_KEY}.pub")" -ne 1 ]]; then
  echo "public key file must contain exactly one line: ${SSH_KEY}.pub" >&2
  print_key_repair_hint
  exit 2
fi

derived_public="$(ssh-keygen -y -f "${SSH_KEY}" | awk 'NR == 1 && NF >= 2 { print $1 " " $2 }')"
stored_public="$(awk 'NR == 1 { print $1 " " $2 }' "${SSH_KEY}.pub")"
if [[ -z "${derived_public}" || "${derived_public}" != "${stored_public}" ]]; then
  echo "private/public key pair mismatch: ${SSH_KEY}" >&2
  print_key_repair_hint
  exit 2
fi

NODES=(
  'cp1|192.168.14.31|192.168.34.31|-'
  'cp2|192.168.14.32|192.168.34.32|-'
  'cp3|192.168.14.33|192.168.34.33|-'
  'worker1|192.168.14.41|192.168.34.41|192.168.44.41'
  'worker2|192.168.14.42|192.168.34.42|192.168.44.42'
  'worker3|192.168.14.43|192.168.34.43|192.168.44.43'
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

failures=0
echo "DevOps central-control gate"
echo "  local operator : $(id -un)@$(hostname -s)"
echo "  remote account : ${REMOTE_USER}"
echo "  private key    : ${SSH_KEY}"
echo "  managed scope  : CP1-3 and Worker1-3 only"

for node_record in "${NODES[@]}"; do
  IFS='|' read -r node_name management_ip internal_ip data_ip <<<"${node_record}"
  echo
  echo "===== ${node_name} (${management_ip}) ====="

  if ! inventory_host_has "${BASELINE_INVENTORY}" "${node_name}" ansible_host "${management_ip}" ||
     ! inventory_host_has "${BASELINE_INVENTORY}" "${node_name}" internal_ip "${internal_ip}" ||
     ! inventory_host_has "${KUBESPRAY_INVENTORY}" "${node_name}" ansible_host "${management_ip}" ||
     ! inventory_host_has "${KUBESPRAY_INVENTORY}" "${node_name}" ip "${internal_ip}" ||
     ! inventory_host_has "${KUBESPRAY_INVENTORY}" "${node_name}" access_ip "${internal_ip}"; then
    echo "[FAIL] ${node_name}: fixed Management/Internal address is inconsistent in an inventory" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ "${data_ip}" != "-" ]] &&
     ! inventory_host_has "${BASELINE_INVENTORY}" "${node_name}" data_ip "${data_ip}"; then
    echo "[FAIL] ${node_name}: fixed Data address is inconsistent in the baseline inventory" >&2
    failures=$((failures + 1))
    continue
  fi

  if ! ssh-keygen -F "${management_ip}" -f "${KNOWN_HOSTS}" >/dev/null; then
    echo "[FAIL] host key is not pinned for ${management_ip}" >&2
    echo "       compare the ED25519 fingerprint with the VM console, then connect once by this IP" >&2
    failures=$((failures + 1))
    continue
  fi

  if remote_output="$(
    ssh "${SSH_OPTIONS[@]}" "${REMOTE_USER}@${management_ip}" \
      bash -s -- "${node_name}" "${management_ip}" "${internal_ip}" "${data_ip}" <<'REMOTE'
set -Eeuo pipefail

inventory_node="$1"
management_ip="$2"
internal_ip="$3"
data_ip="$4"

test "$(id -un)" = "k8sadmin"
test "$(sudo -n id -u)" = "0"
command -v python3 >/dev/null
ip -o -4 address show | grep -Fq " ${management_ip}/"
ip -o -4 address show | grep -Fq " ${internal_ip}/"
if [[ "${data_ip}" != "-" ]]; then
  ip -o -4 address show | grep -Fq " ${data_ip}/"
fi

printf 'current_host=%s inventory_node=%s user=%s sudo_uid=%s python=%s\n' \
  "$(hostname -s)" \
  "${inventory_node}" \
  "$(id -un)" \
  "$(sudo -n id -u)" \
  "$(python3 --version 2>&1)"
REMOTE
  )"; then
    echo "[PASS] ${remote_output}"
  else
    echo "[FAIL] ${node_name}: public-key SSH, passwordless sudo, Python or fixed NIC check failed" >&2
    failures=$((failures + 1))
  fi
done

echo
if (( failures > 0 )); then
  echo "central-control gate failed on ${failures} node(s)" >&2
  echo "do not start Kubespray until every node reports PASS" >&2
  exit 1
fi

echo "[PASS] DevOps can control all six managed nodes as k8sadmin"
echo "LB/DB/NFS/Infra were intentionally not checked and are outside Kubespray inventory"

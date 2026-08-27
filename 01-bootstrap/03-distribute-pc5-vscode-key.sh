#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY_FILE="${1:-}"
TARGETS_FILE="${2:-${SCRIPT_DIR}/02-vscode-ssh-targets.conf}"
K8S_BOOTSTRAP_KEY="${K8S_BOOTSTRAP_KEY:-${HOME}/.ssh/neuroplan_k8s}"

usage() {
  cat <<EOF
usage: $0 /path/to/neuroplan_vscode.pub [targets.conf]

Run as the normal DevOps account on PC2's DevOps VM.
The public key must be created on PC5; never copy its private key to PC2.
EOF
}

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

if [[ -z "${PUBLIC_KEY_FILE}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${PUBLIC_KEY_FILE}" || ! -f "${TARGETS_FILE}" ]]; then
  echo "public key or targets file not found" >&2
  usage >&2
  exit 2
fi

if grep -q 'PRIVATE KEY' "${PUBLIC_KEY_FILE}"; then
  echo "refusing a private key; provide the PC5 .pub file only" >&2
  exit 2
fi

if [[ $(wc -l <"${PUBLIC_KEY_FILE}") -ne 1 ]] ||
   ! grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp)[[:space:]]' "${PUBLIC_KEY_FILE}"; then
  echo "invalid one-line OpenSSH public key: ${PUBLIC_KEY_FILE}" >&2
  exit 2
fi

for required_command in ssh ssh-copy-id ssh-keygen; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "missing command: ${required_command}" >&2
    exit 3
  }
done

PC5_KEY_FINGERPRINT="$(ssh-keygen -lf "${PUBLIC_KEY_FILE}")"
echo "PC5 public key: ${PC5_KEY_FINGERPRINT}"
echo "Compare this fingerprint with PC5 before continuing."
read -r -p "Type DEPLOY to distribute this key to all configured VMs: " CONFIRM
if [[ "${CONFIRM}" != "DEPLOY" ]]; then
  echo "cancelled"
  exit 4
fi

declare -A APPROVED_USERS=()
declare -a SUCCEEDED=()
declare -a FAILED=()
PUBLIC_KEY="$(<"${PUBLIC_KEY_FILE}")"
PUBLIC_KEY="${PUBLIC_KEY%$'\r'}"

while IFS='|' read -r SSH_ALIAS MANAGEMENT_IP LOGIN_SPEC BOOTSTRAP_METHOD <&3; do
  [[ -z "${SSH_ALIAS}" || "${SSH_ALIAS}" == \#* ]] && continue

  LOGIN_USER="${LOGIN_SPEC}"
  if [[ "${LOGIN_SPEC}" == "CURRENT" ]]; then
    LOGIN_USER="${USER}"
  elif [[ "${LOGIN_SPEC}" == ASK:* ]]; then
    USER_GROUP="${LOGIN_SPEC#ASK:}"
    if [[ -z "${APPROVED_USERS[${USER_GROUP}]+present}" ]]; then
      read -r -p "Approved Linux account for ${USER_GROUP}: " APPROVED_USERS["${USER_GROUP}"]
    fi
    LOGIN_USER="${APPROVED_USERS[${USER_GROUP}]}"
  fi

  if [[ ! "${LOGIN_USER}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]]; then
    echo "[FAIL] ${SSH_ALIAS}: approved Linux user is empty or invalid" >&2
    FAILED+=("${SSH_ALIAS}")
    continue
  fi

  echo
  echo "[DEPLOY] ${SSH_ALIAS} ${LOGIN_USER}@${MANAGEMENT_IP}"

  if [[ "${BOOTSTRAP_METHOD}" == "local" ]]; then
    if [[ "${LOGIN_USER}" != "${USER}" ]]; then
      echo "[FAIL] ${SSH_ALIAS}: local target must use current user ${USER}" >&2
      FAILED+=("${SSH_ALIAS}")
      continue
    fi
    install -d -m 0700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/authorized_keys"
    chmod 0600 "${HOME}/.ssh/authorized_keys"
    if ! grep -Fqx -- "${PUBLIC_KEY}" "${HOME}/.ssh/authorized_keys"; then
      printf '%s\n' "${PUBLIC_KEY}" >>"${HOME}/.ssh/authorized_keys"
    fi
    restorecon -RF "${HOME}/.ssh" 2>/dev/null || true
    SUCCEEDED+=("${SSH_ALIAS}")
    continue
  fi

  SSH_OPTIONS=(-o ConnectTimeout=10)
  if [[ "${BOOTSTRAP_METHOD}" == "k8s" ]]; then
    if [[ ! -f "${K8S_BOOTSTRAP_KEY}" ]]; then
      echo "[FAIL] ${SSH_ALIAS}: bootstrap key not found: ${K8S_BOOTSTRAP_KEY}" >&2
      FAILED+=("${SSH_ALIAS}")
      continue
    fi
    SSH_OPTIONS+=(-o IdentitiesOnly=yes -o "IdentityFile=${K8S_BOOTSTRAP_KEY}")
  elif [[ "${BOOTSTRAP_METHOD}" != "password" ]]; then
    echo "[FAIL] ${SSH_ALIAS}: unknown bootstrap method ${BOOTSTRAP_METHOD}" >&2
    FAILED+=("${SSH_ALIAS}")
    continue
  fi

  echo "Verify the host fingerprint before accepting it. A password may be requested."
  if ssh-copy-id -i "${PUBLIC_KEY_FILE}" "${SSH_OPTIONS[@]}" \
      "${LOGIN_USER}@${MANAGEMENT_IP}"; then
    SUCCEEDED+=("${SSH_ALIAS}")
  else
    echo "[FAIL] ${SSH_ALIAS}" >&2
    FAILED+=("${SSH_ALIAS}")
  fi
done 3<"${TARGETS_FILE}"

echo
echo "Distribution summary"
printf '  success: %s\n' "${SUCCEEDED[*]:-none}"
printf '  failed : %s\n' "${FAILED[*]:-none}"

if ((${#FAILED[@]} > 0)); then
  echo "Resolve failed accounts, TCP/22, sshd or credentials and run again; the script is idempotent." >&2
  exit 5
fi

echo "All configured VM authorized_keys contain the PC5 public key."
echo "Return to PC5 and validate each alias with BatchMode=yes."

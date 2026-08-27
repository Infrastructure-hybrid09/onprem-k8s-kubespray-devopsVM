#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANAGED_NODE_SCRIPT="${MANAGED_NODE_SCRIPT:-${SCRIPT_DIR}/01-managed-node-bootstrap.sh}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-${HOME}/.ssh/neuroplan_k8s.pub}"
SCRIPT_DELIMITER='NEUROPLAN_MANAGED_NODE_SCRIPT_EOF'
KEY_DELIMITER='NEUROPLAN_K8S_PUBLIC_KEY_EOF'

for required_file in "${MANAGED_NODE_SCRIPT}" "${PUBLIC_KEY_FILE}"; do
  if [[ ! -f "${required_file}" ]]; then
    echo "required file not found: ${required_file}" >&2
    exit 2
  fi
done

if grep -Fqx "${SCRIPT_DELIMITER}" "${MANAGED_NODE_SCRIPT}"; then
  echo "heredoc delimiter collision in ${MANAGED_NODE_SCRIPT}" >&2
  exit 2
fi

if [[ $(wc -l <"${PUBLIC_KEY_FILE}") -ne 1 ]] ||
   ! grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp)[[:space:]]+[^[:space:]]+' \
     "${PUBLIC_KEY_FILE}"; then
  echo "invalid one-line OpenSSH public key: ${PUBLIC_KEY_FILE}" >&2
  exit 2
fi

cat <<'COMMAND_HEADER'
(
set -Eeuo pipefail

INSTALLER=/root/01-managed-node-bootstrap.sh
PUBLIC_KEY=/root/neuroplan_k8s.pub

cleanup_console_bootstrap() {
  rm -f -- "$INSTALLER" "$PUBLIC_KEY"
}
trap cleanup_console_bootstrap EXIT

cat >"$INSTALLER" <<'NEUROPLAN_MANAGED_NODE_SCRIPT_EOF'
COMMAND_HEADER

cat "${MANAGED_NODE_SCRIPT}"

printf '%s\n' "${SCRIPT_DELIMITER}"
printf '%s\n' 'cat >"$PUBLIC_KEY" <<'"${KEY_DELIMITER}"''
cat "${PUBLIC_KEY_FILE}"
printf '%s\n' "${KEY_DELIMITER}"

cat <<'COMMAND_FOOTER'

chmod 0700 "$INSTALLER"
chmod 0600 "$PUBLIC_KEY"
"$INSTALLER" "$PUBLIC_KEY"

test "$(getent passwd k8sadmin | awk -F: '{print $6 ":" $7}')" = "/home/k8sadmin:/bin/bash"
id -nG k8sadmin | tr ' ' '\n' | grep -Fxq wheel
test "$(stat -c '%U:%G:%a' /home/k8sadmin/.ssh/authorized_keys)" = "k8sadmin:k8sadmin:600"
test "$(sudo -u k8sadmin sudo -n id -u)" = "0"
visudo -cf /etc/sudoers.d/90-k8sadmin
sshd -t
systemctl is-active --quiet sshd

echo "[PASS] $(hostname -s): k8sadmin local bootstrap and validation complete"
ssh-keygen -lf /home/k8sadmin/.ssh/authorized_keys
)
COMMAND_FOOTER

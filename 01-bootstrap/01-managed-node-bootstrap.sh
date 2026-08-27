#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_KEY_FILE="${1:-}"

if [[ ${EUID} -ne 0 ]]; then
  echo "run locally as root or with sudo on each CP/Worker VM" >&2
  exit 1
fi

if [[ -n "${PUBLIC_KEY_FILE}" ]]; then
  if [[ ! -f "${PUBLIC_KEY_FILE}" ]]; then
    echo "public key file not found: ${PUBLIC_KEY_FILE}" >&2
    exit 2
  fi
  if [[ $(wc -l <"${PUBLIC_KEY_FILE}") -ne 1 ]]; then
    echo "public key file must contain exactly one line" >&2
    exit 2
  fi
  IFS= read -r PUBLIC_KEY <"${PUBLIC_KEY_FILE}"
else
  echo "Paste the single-line contents of DevOps ~/.ssh/neuroplan_k8s.pub."
  IFS= read -r -p "neuroplan_k8s public key: " PUBLIC_KEY
fi

PUBLIC_KEY="${PUBLIC_KEY%$'\r'}"
if [[ ! "${PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp)[[:space:]]+[^[:space:]]+([[:space:]].*)?$ ]]; then
  echo "invalid OpenSSH public key" >&2
  exit 2
fi

dnf install -y openssh-server python3 sudo
systemctl enable --now sshd

if ! id k8sadmin >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash k8sadmin
fi

K8SADMIN_HOME="$(getent passwd k8sadmin | awk -F: '{print $6}')"
K8SADMIN_SHELL="$(getent passwd k8sadmin | awk -F: '{print $7}')"
if [[ "${K8SADMIN_HOME}" != "/home/k8sadmin" ]]; then
  echo "existing k8sadmin home is unexpected: ${K8SADMIN_HOME}" >&2
  exit 3
fi
if [[ "${K8SADMIN_SHELL}" != "/bin/bash" ]]; then
  echo "existing k8sadmin shell is unexpected: ${K8SADMIN_SHELL}" >&2
  exit 3
fi
usermod -aG wheel k8sadmin

install -d -o k8sadmin -g k8sadmin -m 0700 "${K8SADMIN_HOME}/.ssh"
AUTHORIZED_KEYS="${K8SADMIN_HOME}/.ssh/authorized_keys"
touch "$AUTHORIZED_KEYS"
chown k8sadmin:k8sadmin "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"
if ! grep -Fqx -- "$PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  printf '%s\n' "$PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
fi
restorecon -RF "${K8SADMIN_HOME}/.ssh" 2>/dev/null || true

SUDOERS_TEMP="$(mktemp /etc/sudoers.d/.90-k8sadmin.XXXXXX)"
trap 'rm -f -- "${SUDOERS_TEMP:-}"' EXIT
cat >"${SUDOERS_TEMP}" <<'EOF'
k8sadmin ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "${SUDOERS_TEMP}"
visudo -cf "${SUDOERS_TEMP}"
mv -f -- "${SUDOERS_TEMP}" /etc/sudoers.d/90-k8sadmin
trap - EXIT
restorecon -F /etc/sudoers.d/90-k8sadmin 2>/dev/null || true
visudo -cf /etc/sudoers.d/90-k8sadmin

echo "managed-node bootstrap complete"
id k8sadmin
echo "authorized key fingerprint:"
ssh-keygen -lf "${AUTHORIZED_KEYS}"
echo "network, swap, sysctl, kernel modules and Kubernetes packages were not changed"

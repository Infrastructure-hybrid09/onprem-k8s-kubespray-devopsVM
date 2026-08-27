#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SSH_PRIVATE="${SSH_KEY:-${HOME}/.ssh/neuroplan_k8s}"
SSH_PUBLIC="${SSH_PRIVATE}.pub"
PUBLIC_COMMENT="neuroplan-kubespray"
TEMP_PUBLIC=""

cleanup() {
  if [[ -n "${TEMP_PUBLIC}" && -e "${TEMP_PUBLIC}" ]]; then
    rm -f -- "${TEMP_PUBLIC}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

if [[ ! -f "${SSH_PRIVATE}" || -L "${SSH_PRIVATE}" ]]; then
  echo "regular private key not found: ${SSH_PRIVATE}" >&2
  echo "This repair never creates or replaces the private key." >&2
  exit 2
fi

if [[ "$(stat -c '%U' "${SSH_PRIVATE}")" != "$(id -un)" ]]; then
  echo "private key is not owned by $(id -un): ${SSH_PRIVATE}" >&2
  exit 2
fi

if [[ -L "${SSH_PUBLIC}" || ( -e "${SSH_PUBLIC}" && ! -f "${SSH_PUBLIC}" ) ]]; then
  echo "refusing to replace a symlink or non-regular public-key path: ${SSH_PUBLIC}" >&2
  exit 2
fi

chmod 0600 "${SSH_PRIVATE}"

# Extract only the public algorithm and base64 key blob. Some OpenSSH builds
# append a comment to ssh-keygen -y output; comments do not define key identity.
# Private-key material is never copied to a temporary file or printed.
derived_identity="$(ssh-keygen -y -f "${SSH_PRIVATE}")" || {
  echo "could not derive a public key from: ${SSH_PRIVATE}" >&2
  exit 2
}
derived_identity="$(awk 'NR == 1 && NF >= 2 { print $1 " " $2 }' <<<"${derived_identity}")"
if [[ -z "${derived_identity}" ]]; then
  echo "derived public key is not a valid two-field OpenSSH key" >&2
  exit 2
fi

stored_identity=""
if [[ -f "${SSH_PUBLIC}" && "$(wc -l <"${SSH_PUBLIC}")" -eq 1 ]]; then
  stored_identity="$(awk 'NR == 1 && NF >= 2 { print $1 " " $2 }' "${SSH_PUBLIC}")"
fi

if [[ "${stored_identity}" == "${derived_identity}" ]]; then
  chmod 0644 "${SSH_PUBLIC}"
  echo "[OK] public key already matches the private key"
else
  TEMP_PUBLIC="$(mktemp "${SSH_PUBLIC}.tmp.XXXXXX")"
  printf '%s %s\n' "${derived_identity}" "${PUBLIC_COMMENT}" >"${TEMP_PUBLIC}"
  chmod 0644 "${TEMP_PUBLIC}"

  candidate_identity="$(awk 'NR == 1 && NF >= 2 { print $1 " " $2 }' "${TEMP_PUBLIC}")"
  if [[ "${candidate_identity}" != "${derived_identity}" ]]; then
    echo "generated public-key verification failed" >&2
    exit 2
  fi

  mv -f -- "${TEMP_PUBLIC}" "${SSH_PUBLIC}"
  TEMP_PUBLIC=""
  echo "[REPAIRED] public key was atomically derived from the existing private key"
fi

echo "Private key was not replaced or displayed: ${SSH_PRIVATE}"
echo "Current public-key fingerprint:"
ssh-keygen -lf "${SSH_PUBLIC}"

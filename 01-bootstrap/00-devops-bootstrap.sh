#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

sudo dnf install -y \
  git curl wget jq vim-enhanced bash-completion tar rsync \
  iproute bind-utils net-tools nmap-ncat openssh-clients \
  python3.11 python3.11-pip podman

install -d -m 0700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/neuroplan_k8s" ]]; then
  ssh-keygen -t ed25519 -a 100 \
    -f "$HOME/.ssh/neuroplan_k8s" \
    -C "neuroplan-kubespray" \
    -N ""
fi

# Repair a missing, malformed, or stale .pub from the existing private key.
# The helper compares the OpenSSH algorithm/key blob and replaces only .pub.
bash "${SCRIPT_DIR}/06-repair-devops-public-key.sh"

install -d -m 0755 "$HOME/.config/neuroplan"
touch "$HOME/.bashrc"
sed -i \
  -e '\|^# Neuroplan DevOps prompt$|d' \
  -e '\|^source "$HOME/.config/neuroplan/devops-prompt.sh"$|d' \
  "$HOME/.bashrc"
rm -f -- "$HOME/.config/neuroplan/devops-prompt.sh"

cat >"$HOME/.config/neuroplan/kubectl-aliases.sh" <<'EOF'
alias k='kubectl'
alias kgp='kubectl get pods -A -o wide'
EOF

if ! grep -Fq '.config/neuroplan/kubectl-aliases.sh' "$HOME/.bashrc"; then
  printf '\n# Neuroplan kubectl aliases\nsource "$HOME/.config/neuroplan/kubectl-aliases.sh"\n' >>"$HOME/.bashrc"
fi

echo "DevOps bootstrap complete"
echo "Public key to place on managed nodes:"
cat "$HOME/.ssh/neuroplan_k8s.pub"
echo "Private key remains only at $HOME/.ssh/neuroplan_k8s"

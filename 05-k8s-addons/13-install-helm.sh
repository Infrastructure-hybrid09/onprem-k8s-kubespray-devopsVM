#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

HELM_VERSION="3.18.4"
HELM_SHA256="f8180838c23d7c7d797b208861fecb591d9ce1690d8704ed1e4cb8e2add966c1"
ARCHIVE="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
URL="https://get.helm.sh/$ARCHIVE"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

if command -v helm >/dev/null && \
   helm version --short | grep -Fq "v$HELM_VERSION"; then
  echo "Helm v$HELM_VERSION is already installed"
  exit 0
fi

curl -fL --retry 3 "$URL" -o "$TMP_DIR/$ARCHIVE"
printf '%s  %s\n' "$HELM_SHA256" "$TMP_DIR/$ARCHIVE" | sha256sum -c -
tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"
install -d -m 0755 "$HOME/.local/bin"
install -m 0755 "$TMP_DIR/linux-amd64/helm" "$HOME/.local/bin/helm"

export PATH="$HOME/.local/bin:$PATH"
helm version --short

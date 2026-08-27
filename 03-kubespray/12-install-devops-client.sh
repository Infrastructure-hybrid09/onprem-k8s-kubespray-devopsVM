#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ARTIFACTS="$SCRIPT_DIR/inventory/mycluster/artifacts"
API_VIP="192.168.34.100"
API_ENDPOINT="https://$API_VIP:6443"
TARGET_KUBECTL="$HOME/.local/bin/kubectl"
TARGET_KUBECONFIG="$HOME/.kube/config"
TEMP_KUBECONFIG=""

cleanup() {
  [[ -n "$TEMP_KUBECONFIG" && -e "$TEMP_KUBECONFIG" ]] &&
    rm -f -- "$TEMP_KUBECONFIG"
}
trap cleanup EXIT

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi
[[ -f "$ARTIFACTS/admin.conf" ]] || { echo "missing $ARTIFACTS/admin.conf" >&2; exit 1; }
[[ -f "$ARTIFACTS/kubectl" ]] || { echo "missing $ARTIFACTS/kubectl" >&2; exit 1; }

install -d -m 0755 "$HOME/.local/bin"
install -m 0755 "$ARTIFACTS/kubectl" "$TARGET_KUBECTL"
install -d -m 0700 "$HOME/.kube"
TEMP_KUBECONFIG="$(mktemp "$HOME/.kube/.config.api-vip.XXXXXX")"
install -m 0600 "$ARTIFACTS/admin.conf" "$TEMP_KUBECONFIG"

export PATH="$HOME/.local/bin:$PATH"
cluster_name="$(
  KUBECONFIG="$TEMP_KUBECONFIG" "$TARGET_KUBECTL" \
    config view --minify \
    -o jsonpath='{.contexts[0].context.cluster}'
)"
[[ -n "$cluster_name" ]] || {
  echo "cannot determine the cluster in the artifact kubeconfig" >&2
  exit 1
}
KUBECONFIG="$TEMP_KUBECONFIG" "$TARGET_KUBECTL" \
  config set-cluster "$cluster_name" --server="$API_ENDPOINT" >/dev/null
[[ "$(
  KUBECONFIG="$TEMP_KUBECONFIG" "$TARGET_KUBECTL" \
    config view --minify -o jsonpath='{.clusters[0].cluster.server}'
)" == "$API_ENDPOINT" ]] || {
  echo "failed to normalize the artifact endpoint to $API_ENDPOINT" >&2
  exit 1
}
KUBECONFIG="$TEMP_KUBECONFIG" "$TARGET_KUBECTL" \
  --request-timeout=10s get --raw='/readyz' >/dev/null

if [[ -f "$TARGET_KUBECONFIG" ]]; then
  install -d -m 0700 "$HOME/.kube/backups"
  backup_file="$(mktemp "$HOME/.kube/backups/config.before.XXXXXX")"
  install -m 0600 "$TARGET_KUBECONFIG" "$backup_file"
  echo "previous kubeconfig backup: $backup_file"
fi
mv -f -- "$TEMP_KUBECONFIG" "$TARGET_KUBECONFIG"
TEMP_KUBECONFIG=""

export KUBECONFIG="$TARGET_KUBECONFIG"
"$TARGET_KUBECTL" version --client
"$TARGET_KUBECTL" --request-timeout=10s get --raw='/readyz'
echo "DevOps kubectl client and kubeconfig installed"

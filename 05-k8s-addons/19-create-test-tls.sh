#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

NAMESPACE="application"
SECRET_NAME="nplan-tls-v1"
HOSTNAME="app.nplan.local"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

for command in kubectl openssl; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done

kubectl apply -f "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/15-namespace.yaml"
if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "$NAMESPACE/$SECRET_NAME already exists; leaving it unchanged"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "$TMP_DIR/tls.key" \
  -out "$TMP_DIR/tls.crt" \
  -subj "/CN=$HOSTNAME" \
  -addext "subjectAltName=DNS:$HOSTNAME"

kubectl -n "$NAMESPACE" create secret tls "$SECRET_NAME" \
  --cert="$TMP_DIR/tls.crt" --key="$TMP_DIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "created a 30-day self-signed TEST certificate"
echo "replace it with the team-approved certificate before production use"

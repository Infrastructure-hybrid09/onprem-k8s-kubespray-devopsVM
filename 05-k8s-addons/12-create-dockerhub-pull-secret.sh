#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi
if (( $# != 0 )); then
  echo "usage: ./05-k8s-addons/12-create-dockerhub-pull-secret.sh" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AUTH_FILE="$HOME/.config/containers/dockerhub-auth.json"
NAMESPACE="application"
SECRET_NAME="dockerhub-pull"

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

for command in kubectl jq; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done
[[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" ]] || {
  echo "Docker Hub auth is missing; run 04-registry/06-configure-dockerhub-auth.sh" >&2
  exit 1
}
[[ "$(stat -c '%U:%a' "$AUTH_FILE")" == "devops:600" ]] || {
  echo "Docker Hub auth must be owned by devops with mode 0600" >&2
  exit 1
}
jq -e '
  (.auths | type == "object") and
  any(.auths | keys[]; contains("docker.io"))
' "$AUTH_FILE" >/dev/null || { echo "invalid Docker Hub auth file" >&2; exit 1; }

kubectl apply -f "$SCRIPT_DIR/15-namespace.yaml"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$AUTH_FILE" \
  --dry-run=client -o yaml | kubectl apply \
    --server-side \
    --field-manager=neuroplan-secret-manager \
    -f -

service_account_json=""
for attempt in {1..30}; do
  if service_account_json="$(kubectl -n "$NAMESPACE" get serviceaccount default -o json 2>/dev/null)"; then
    break
  fi
  sleep 1
done
[[ -n "$service_account_json" ]] || {
  echo "default ServiceAccount was not created in namespace $NAMESPACE" >&2
  exit 1
}

if ! jq -e --arg name "$SECRET_NAME" \
  'any(.imagePullSecrets[]?; .name == $name)' <<<"$service_account_json" >/dev/null; then
  if jq -e '(.imagePullSecrets? | type) == "array"' <<<"$service_account_json" >/dev/null; then
    kubectl -n "$NAMESPACE" patch serviceaccount default --type=json \
      -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"dockerhub-pull"}}]'
  else
    kubectl -n "$NAMESPACE" patch serviceaccount default --type=json \
      -p='[{"op":"add","path":"/imagePullSecrets","value":[{"name":"dockerhub-pull"}]}]'
  fi
fi

secret_type="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.type}')"
[[ "$secret_type" == "kubernetes.io/dockerconfigjson" ]] || {
  echo "unexpected Secret type: $secret_type" >&2
  exit 1
}
kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o json | jq -e \
  '.data[".dockerconfigjson"] | type == "string" and length > 0' >/dev/null
kubectl -n "$NAMESPACE" get serviceaccount default \
  -o json | jq -e --arg name "$SECRET_NAME" \
  'any(.imagePullSecrets[]?; .name == $name)' >/dev/null

echo "Docker Hub image pull Secret is ready: $NAMESPACE/$SECRET_NAME"
echo "The Secret is namespace-scoped and its credential data was not printed."

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for command in kubectl jq; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done

kubectl apply -f "$SCRIPT_DIR/15-namespace.yaml"

secret_type="$(kubectl -n application get secret dockerhub-pull \
  -o jsonpath='{.type}' 2>/dev/null || true)"
if [[ "$secret_type" != "kubernetes.io/dockerconfigjson" ]]; then
  echo "application/dockerhub-pull is missing or invalid" >&2
  echo "run 05-k8s-addons/12-create-dockerhub-pull-secret.sh first" >&2
  exit 1
fi
kubectl -n application get secret dockerhub-pull -o json | jq -e \
  '.data[".dockerconfigjson"] | type == "string" and length > 0' >/dev/null || {
  echo "application/dockerhub-pull has no Docker auth data" >&2
  exit 1
}
kubectl -n application get serviceaccount default \
  -o jsonpath='{.imagePullSecrets[*].name}' | tr ' ' '\n' | grep -Fxq dockerhub-pull || {
  echo "application/default does not reference imagePullSecret dockerhub-pull" >&2
  echo "run 05-k8s-addons/12-create-dockerhub-pull-secret.sh first" >&2
  exit 1
}

kubectl apply -f "$SCRIPT_DIR/16-test-workload.yaml"
kubectl apply -f "$SCRIPT_DIR/17-pdb.yaml"
kubectl apply -f "$SCRIPT_DIR/18-hpa.yaml"
"$SCRIPT_DIR/19-create-test-tls.sh"
kubectl apply -f "$SCRIPT_DIR/20-gateway.yaml"
kubectl apply -f "$SCRIPT_DIR/21-httproute.yaml"

kubectl -n application rollout status deployment/validation-echo --timeout=5m
kubectl -n application wait --for=condition=Ready pod/validation-busybox --timeout=5m
kubectl -n application wait --for=condition=Ready pod/validation-curl --timeout=5m
kubectl -n application wait --for=condition=Accepted gateway/neuroplan-gateway --timeout=5m
kubectl -n application wait --for=condition=Programmed gateway/neuroplan-gateway --timeout=5m

for attempt in {1..60}; do
  route_json="$(kubectl -n application get httproute validation-echo -o json)"
  if jq -e 'any(.status.parents[]?.conditions[]?; .type == "Accepted" and .status == "True")' \
       <<<"$route_json" >/dev/null && \
     jq -e 'any(.status.parents[]?.conditions[]?; .type == "ResolvedRefs" and .status == "True")' \
       <<<"$route_json" >/dev/null; then
    echo "HTTPRoute Accepted=True and ResolvedRefs=True"
    break
  fi
  if (( attempt == 60 )); then
    echo "HTTPRoute did not become ready" >&2
    kubectl -n application get httproute validation-echo -o yaml >&2
    exit 1
  fi
  sleep 5
done

kubectl -n application get deployment,pod,service,gateway,httproute -o wide
echo "platform test resources applied"

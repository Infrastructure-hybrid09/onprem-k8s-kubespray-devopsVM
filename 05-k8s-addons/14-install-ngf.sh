#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VALUES_FILE="$SCRIPT_DIR/14-ngf-values.yaml"
EXPECTED_GATEWAY_API="v1.5.1"
NGF_VERSION="2.6.7"

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

for command in kubectl helm; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done

echo "Verifying the Gateway API CRDs installed once by Kubespray"
for crd in \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io; do
  actual="$(kubectl get crd "$crd" \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')"
  if [[ "$actual" != "$EXPECTED_GATEWAY_API" ]]; then
    echo "$crd bundle version is '$actual', expected '$EXPECTED_GATEWAY_API'" >&2
    echo "Do not overwrite it here; reconcile the Kubespray version decision first" >&2
    exit 1
  fi
done

echo "Gateway API $EXPECTED_GATEWAY_API matches the NGF $NGF_VERSION technical specification"
echo "This script does not install or re-apply Gateway API CRDs"

helm upgrade --install ngf \
  oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version "$NGF_VERSION" \
  --namespace nginx-gateway \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait --timeout 10m

kubectl -n nginx-gateway wait \
  --for=condition=Available deployment/ngf-nginx-gateway-fabric \
  --timeout=5m
helm -n nginx-gateway list
kubectl get gatewayclass nginx -o wide
echo "NGF installation completed"

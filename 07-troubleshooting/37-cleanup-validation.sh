#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

kubectl -n application delete \
  httproute,service,deployment,hpa,pdb,configmap,pod,job \
  -l validation.neuroplan.io/owned=true \
  --ignore-not-found --wait=true

echo "validation-owned resources were removed"
echo "application namespace, Gateway, TLS Secret, GatewayClass, NGF and CRDs were retained"

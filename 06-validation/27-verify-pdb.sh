#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

NAMESPACE="application"
PDB="validation-echo"

max_unavailable="$(kubectl -n "$NAMESPACE" get pdb "$PDB" -o jsonpath='{.spec.maxUnavailable}')"
current_healthy="$(kubectl -n "$NAMESPACE" get pdb "$PDB" -o jsonpath='{.status.currentHealthy}')"
desired_healthy="$(kubectl -n "$NAMESPACE" get pdb "$PDB" -o jsonpath='{.status.desiredHealthy}')"
allowed="$(kubectl -n "$NAMESPACE" get pdb "$PDB" -o jsonpath='{.status.disruptionsAllowed}')"

[[ "$max_unavailable" == "1" ]]
(( current_healthy >= desired_healthy ))
(( allowed >= 1 ))

kubectl -n "$NAMESPACE" get pdb "$PDB" -o wide
echo "[PASS] PDB maxUnavailable=1 healthy=$current_healthy desired=$desired_healthy allowed=$allowed"
echo "PDB covers voluntary Eviction/drain, not VM failure or direct Pod deletion"

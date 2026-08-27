#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NAMESPACE="application"

kubectl top nodes >/dev/null
kubectl -n "$NAMESPACE" top pod \
  -l app.kubernetes.io/name=validation-echo >/dev/null
kubectl -n "$NAMESPACE" delete job validation-hpa-load \
  --ignore-not-found --wait=true
kubectl apply -f "$SCRIPT_DIR/26-hpa-load-job.yaml"

for attempt in {1..48}; do
  failed="$(kubectl -n "$NAMESPACE" get job validation-hpa-load \
    -o jsonpath='{.status.failed}')"
  if [[ "${failed:-0}" =~ ^[0-9]+$ ]] && (( failed > 0 )); then
    kubectl -n "$NAMESPACE" logs job/validation-hpa-load --all-containers=true >&2 || true
    echo "HPA load Job failed before scale-up" >&2
    exit 1
  fi

  current="$(kubectl -n "$NAMESPACE" get hpa validation-echo \
    -o jsonpath='{.status.currentReplicas}')"
  desired="$(kubectl -n "$NAMESPACE" get hpa validation-echo \
    -o jsonpath='{.status.desiredReplicas}')"
  echo "HPA current=${current:-unknown} desired=${desired:-unknown}"
  if [[ "${current:-0}" =~ ^[0-9]+$ && "${desired:-0}" =~ ^[0-9]+$ ]] && \
     (( current > 3 || desired > 3 )); then
    kubectl -n "$NAMESPACE" get hpa validation-echo
    echo "[PASS] HPA scaled above three replicas"
    exit 0
  fi
  sleep 5
done

kubectl -n "$NAMESPACE" describe hpa validation-echo >&2
kubectl -n "$NAMESPACE" top pod >&2 || true
kubectl -n "$NAMESPACE" get job validation-hpa-load -o wide >&2 || true
kubectl -n "$NAMESPACE" logs job/validation-hpa-load --all-containers=true >&2 || true
kubectl -n kube-system logs deployment/metrics-server --tail=200 >&2 || true
echo "HPA did not scale within 240 seconds" >&2
exit 1

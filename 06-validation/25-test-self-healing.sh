#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

NAMESPACE="application"
SELECTOR="app.kubernetes.io/name=validation-echo"

old_pod="$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}')"
old_uid="$(kubectl -n "$NAMESPACE" get pod "$old_pod" -o jsonpath='{.metadata.uid}')"

echo "deleting $old_pod uid=$old_uid for ReplicaSet self-healing test"
kubectl -n "$NAMESPACE" delete pod "$old_pod" --wait=false
kubectl -n "$NAMESPACE" rollout status deployment/validation-echo --timeout=5m

if kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | grep -Fxq "$old_uid"; then
  echo "old Pod UID still exists after rollout" >&2
  exit 1
fi

ready="$(kubectl -n "$NAMESPACE" get deployment validation-echo \
  -o jsonpath='{.status.readyReplicas}')"
desired="$(kubectl -n "$NAMESPACE" get deployment validation-echo \
  -o jsonpath='{.spec.replicas}')"
[[ "$ready" == "$desired" ]] || { echo "ready=$ready desired=$desired" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec validation-busybox -- \
  wget -T 5 -qO- http://validation-echo/validation/self-healing | grep -Fq validation-ok
echo "[PASS] ReplicaSet self-healing created a new Pod and service is healthy"

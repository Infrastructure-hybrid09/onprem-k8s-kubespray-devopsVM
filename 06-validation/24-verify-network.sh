#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

export KUBECONFIG="$HOME/.kube/config"
[[ -r "$KUBECONFIG" ]] || { echo "kubeconfig is missing: $KUBECONFIG" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
INVENTORY="$PROJECT_ROOT/03-kubespray/inventory/mycluster/hosts.yaml"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$PROJECT_ROOT/03-kubespray/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
NAMESPACE="application"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-neuroplan.local}"
PYTHON="${PYTHON:-python3.11}"

pass() { printf '[PASS] %s\n' "$*"; }

for command in kubectl jq "$PYTHON"; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done
[[ -x "$VENV_DIR/bin/ansible" ]] || { echo "Ansible venv is missing: $VENV_DIR" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "SSH key is missing: $SSH_KEY" >&2; exit 1; }
export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"

secret_type="$(kubectl -n "$NAMESPACE" get secret dockerhub-pull -o jsonpath='{.type}')"
[[ "$secret_type" == "kubernetes.io/dockerconfigjson" ]] || {
  echo "unexpected application/dockerhub-pull type: $secret_type" >&2
  exit 1
}
kubectl -n "$NAMESPACE" get secret dockerhub-pull -o json | jq -e \
  '.data[".dockerconfigjson"] | type == "string" and length > 0' >/dev/null
kubectl -n "$NAMESPACE" get serviceaccount default \
  -o jsonpath='{.imagePullSecrets[*].name}' | tr ' ' '\n' | grep -Fxq dockerhub-pull
pass "namespace-scoped Docker Hub pull Secret reference"

kubectl -n "$NAMESPACE" rollout status deployment/validation-echo --timeout=5m
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/validation-busybox --timeout=5m
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/validation-curl --timeout=5m

mapfile -t POD_IPS < <(kubectl -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/name=validation-echo \
  -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')
[[ ${#POD_IPS[@]} -ge 3 ]] || { echo "expected at least three Pod IPs" >&2; exit 1; }

for ip in "${POD_IPS[@]}"; do
  "$PYTHON" - "$ip" <<'PY'
import ipaddress
import sys
assert ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network("10.244.0.0/16")
PY
  kubectl -n "$NAMESPACE" exec validation-busybox -- \
    wget -T 5 -qO- "http://$ip:8080/validation/pod-ip" | grep -Fq validation-ok
done
pass "Pod-to-Pod for ${#POD_IPS[@]} endpoints"

SERVICE_IP="$(kubectl -n "$NAMESPACE" get service validation-echo -o jsonpath='{.spec.clusterIP}')"
"$PYTHON" - "$SERVICE_IP" <<'PY'
import ipaddress
import sys
assert ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network("10.96.0.0/12")
PY
kubectl -n "$NAMESPACE" exec validation-busybox -- \
  wget -T 5 -qO- "http://validation-echo.application.svc.${CLUSTER_DOMAIN}/validation/service" |
  grep -Fq validation-ok
pass "Pod-to-Service ClusterIP=$SERVICE_IP"

kubectl -n "$NAMESPACE" exec validation-busybox -- \
  nslookup "kubernetes.default.svc.${CLUSTER_DOMAIN}" >/dev/null
kubectl -n "$NAMESPACE" exec validation-busybox -- \
  nslookup "validation-echo.application.svc.${CLUSTER_DOMAIN}" >/dev/null
pass "CoreDNS service resolution domain=${CLUSTER_DOMAIN}"

status="$(kubectl -n "$NAMESPACE" exec validation-curl -- \
  curl -LsS --connect-timeout 5 --max-time 20 \
  -o /dev/null -w '%{http_code}' https://kubernetes.io/)"
[[ "$status" =~ ^[23][0-9][0-9]$ ]] || { echo "Pod egress HTTP status=$status" >&2; exit 1; }
pass "Pod Internet egress HTTP=$status"

NODES="$(kubectl -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/name=validation-echo \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u)"
[[ "$(wc -l <<<"$NODES")" -eq 3 ]] || {
  echo "initial replicas are not spread across three workers: $NODES" >&2
  exit 1
}
grep -Fxq worker1 <<<"$NODES" && grep -Fxq worker2 <<<"$NODES" && grep -Fxq worker3 <<<"$NODES"
pass "Anti-Affinity spread across Worker1~3"

"$VENV_DIR/bin/ansible" -i "$INVENTORY" all \
  --private-key "$SSH_KEY" -b \
  -m ansible.builtin.command \
  -a '/usr/local/bin/crictl pull 192.168.34.21:5000/neuroplan/busybox:1.36.1'
pass "All node containerd runtimes can pull from the private Registry"

echo "network verification completed"

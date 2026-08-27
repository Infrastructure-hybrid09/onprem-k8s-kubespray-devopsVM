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
API_VIP="192.168.34.100"

pass() { printf '[PASS] %s\n' "$*"; }

for command in kubectl openssl jq sed; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done
[[ -x "$VENV_DIR/bin/ansible" ]] || { echo "Ansible venv is missing: $VENV_DIR" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "SSH key is missing: $SSH_KEY" >&2; exit 1; }

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"
"$VENV_DIR/bin/ansible" -i "$INVENTORY" all \
  --private-key "$SSH_KEY" -m ping >/dev/null
"$VENV_DIR/bin/ansible" -i "$INVENTORY" all \
  --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell \
  -a 'set -eu; test "$(hostname -s)" = "{{ inventory_hostname }}"; ip -o -4 address show | grep -Fq " {{ ip }}/"; timedatectl show -p NTPSynchronized --value | grep -Fxq yes' >/dev/null
pass "SSH, inventory hostname, Internal IP and NTP sync on all six nodes"

ENCRYPTION_COMMAND='set -eu; test -s /etc/kubernetes/ssl/secrets_encryption.yaml; grep -Fq -- "--encryption-provider-config=/etc/kubernetes/ssl/secrets_encryption.yaml" /etc/kubernetes/manifests/kube-apiserver.yaml'
"$VENV_DIR/bin/ansible" -i "$INVENTORY" kube_control_plane \
  --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell -a "$ENCRYPTION_COMMAND" >/dev/null
pass "API Servers use the Kubespray Secret encryption provider config"

kubectl get --raw='/readyz?verbose' >/dev/null
pass "Kubernetes API readyz"

kubectl --server="https://$API_VIP:6443" \
  --request-timeout=10s get --raw='/readyz' >/dev/null
pass "authenticated canonical API VIP path $API_VIP:6443"

declare -A EXPECTED_IPS=(
  [cp1]=192.168.34.31 [cp2]=192.168.34.32 [cp3]=192.168.34.33
  [worker1]=192.168.34.41 [worker2]=192.168.34.42 [worker3]=192.168.34.43
)

[[ "$(kubectl get nodes --no-headers | wc -l)" -eq 6 ]] || {
  echo "expected exactly six Kubernetes nodes" >&2
  exit 1
}

for node in cp1 cp2 cp3 worker1 worker2 worker3; do
  actual_ip="$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  [[ "$actual_ip" == "${EXPECTED_IPS[$node]}" ]] || {
    echo "$node InternalIP=$actual_ip expected=${EXPECTED_IPS[$node]}" >&2
    exit 1
  }
  [[ "$ready" == "True" ]] || { echo "$node is not Ready" >&2; exit 1; }
  pass "$node Ready InternalIP=$actual_ip"
done

for node in cp1 cp2 cp3; do
  kubectl get node "$node" -o json |
    jq -e '.metadata.labels | has("node-role.kubernetes.io/control-plane")' >/dev/null
done
for node in worker1 worker2 worker3; do
  node_json="$(kubectl get node "$node" -o json)"
  jq -e '.metadata.labels["node-role.kubernetes.io/worker"] == "true"' \
    <<<"$node_json" >/dev/null
  jq -e '(.metadata.labels | has("node-role.kubernetes.io/control-plane")) | not' \
    <<<"$node_json" >/dev/null
done
pass "CP/Worker roles remain separate"

kubectl -n kube-system rollout status deployment/coredns --timeout=5m
kubectl -n kube-system wait --for=condition=Ready pod \
  -l k8s-app=calico-node --timeout=5m
kubectl get apiservice v1beta1.metrics.k8s.io \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -Fxq True
kubectl top nodes
pass "CoreDNS, Calico and Metrics Server"

for attempt in {1..10}; do
  kubectl --server=https://192.168.34.100:6443 \
    --request-timeout=5s get --raw='/readyz' >/dev/null
done
pass "API VIP 192.168.34.100:6443 repeated readiness"

for ip in 192.168.34.31 192.168.34.32 192.168.34.33; do
  kubectl --server="https://$ip:6443" \
    --request-timeout=5s get --raw='/readyz' >/dev/null
  pass "Control Plane API backend $ip:6443"
done

API_CERT="$(
  openssl s_client -connect "$API_VIP:6443" </dev/null 2>/dev/null |
    openssl x509
)"
openssl x509 -noout -checkip "$API_VIP" <<<"$API_CERT" >/dev/null
pass "API certificate contains the canonical VIP SAN"

openssl x509 -noout -checkend 2592000 <<<"$API_CERT" >/dev/null
pass "API certificate remains valid for at least 30 days"

ETCD_COMMAND='set -o pipefail; /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem member list --write-out=json | jq -e ".members | length == 3" >/dev/null && /usr/local/bin/etcdctl --endpoints=https://192.168.34.31:2379,https://192.168.34.32:2379,https://192.168.34.33:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem endpoint health --cluster'
"$VENV_DIR/bin/ansible" -i "$INVENTORY" cp1 \
  --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell -a "$ETCD_COMMAND"
pass "etcd exactly three members and three-endpoint health"

kubectl get nodes -o wide
kubectl get pods -A -o wide
echo "cluster verification completed"

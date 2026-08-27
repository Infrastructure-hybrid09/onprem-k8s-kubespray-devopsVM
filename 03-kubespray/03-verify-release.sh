#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
INVENTORY_DIR="$SCRIPT_DIR/inventory/mycluster"
HARDENED_ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg"
CHECKSUMS="$KUBESPRAY_DIR/roles/kubespray_defaults/vars/main/checksums.yml"
DOWNLOAD_DEFAULTS="$KUBESPRAY_DIR/roles/kubespray_defaults/defaults/main/download.yml"
ADDONS_SAMPLE="$KUBESPRAY_DIR/inventory/sample/group_vars/k8s_cluster/addons.yml"
CONTAINERD_DEFAULTS="$KUBESPRAY_DIR/roles/container-engine/containerd/defaults/main.yml"
EXPECTED_COMMIT="1c9add48975060f45396b34d8e022c30d7f80dab"

fail() { echo "[FAIL] $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

[[ -f "$CHECKSUMS" ]] || fail "Kubespray source is missing; run 02-install-kubespray.sh"
[[ -f "$HARDENED_ANSIBLE_CONFIG" ]] || fail "project hardened ansible.cfg is missing"
[[ "$(git -C "$KUBESPRAY_DIR" rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] || \
  fail "Kubespray commit does not match v2.31.0"
pass "Kubespray v2.31.0 commit"

grep -Eqi '^[[:space:]]*host_key_checking[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$HARDENED_ANSIBLE_CONFIG" || fail "host key checking is not enabled"
grep -Fq 'StrictHostKeyChecking=yes' "$HARDENED_ANSIBLE_CONFIG" || \
  fail "strict SSH host checking is missing"
grep -Fq 'IdentitiesOnly=yes' "$HARDENED_ANSIBLE_CONFIG" || \
  fail "exclusive SSH identity use is missing"
if grep -Fq 'UserKnownHostsFile=/dev/null' "$HARDENED_ANSIBLE_CONFIG"; then
  fail "unsafe known_hosts bypass is configured"
fi
pass "project hardened Ansible SSH policy"

for value in 1.35.4 2.2.3 3.31.5 1.5.1 3.18.4; do
  grep -Eq "^[[:space:]]+${value//./\\.}:" "$CHECKSUMS" || \
    fail "checksum not found for $value"
  pass "checksum exists for $value"
done

grep -Fq 'metrics_server_version: "0.8.1"' "$DOWNLOAD_DEFAULTS" || \
  fail "Metrics Server 0.8.1 is not the selected release default"
pass "Metrics Server default is 0.8.1"

if grep -Eq '^[[:space:]]+1\.35\.6:' "$CHECKSUMS"; then
  fail "documentation decision is stale: 1.35.6 unexpectedly exists"
else
  pass "1.35.6 is not supported by this pinned release; inventory remains 1.35.4"
fi

for variable in \
  gateway_api_enabled registry_enabled metallb_enabled kube_vip_enabled \
  argocd_enabled local_path_provisioner_enabled \
  local_volume_provisioner_enabled cert_manager_enabled ingress_alb_enabled; do
  grep -Fq "$variable" "$ADDONS_SAMPLE" || fail "v2.31.0 variable missing: $variable"
done
pass "approved/prohibited add-on variables exist in the selected release"

grep -Fq 'containerd_registries_mirrors:' "$CONTAINERD_DEFAULTS" || \
  fail "containerd mirror variable is unavailable"
pass "containerd registry mirror variable exists"

grep -Fq 'kube_version: "1.35.4"' \
  "$INVENTORY_DIR/group_vars/k8s_cluster/k8s-cluster.yml" || \
  fail "project kube_version changed without decision update"
grep -Fq 'calico_version: "3.31.5"' \
  "$INVENTORY_DIR/group_vars/k8s_cluster/k8s-net-calico.yml" || \
  fail "project calico_version changed without decision update"
grep -Fq 'containerd_version: "2.2.3"' \
  "$INVENTORY_DIR/group_vars/all/containerd.yml" || \
  fail "project containerd_version changed without decision update"
grep -Fq 'kube_encrypt_secret_data: true' \
  "$INVENTORY_DIR/group_vars/k8s_cluster/k8s-cluster.yml" || \
  fail "Kubernetes Secret encryption at rest is not enabled"
grep -Fq 'kube_encryption_algorithm: "secretbox"' \
  "$INVENTORY_DIR/group_vars/k8s_cluster/k8s-cluster.yml" || \
  fail "Kubernetes Secret encryption algorithm is not pinned to secretbox"
pass "Kubernetes Secret encryption at rest"

echo "release verification completed"

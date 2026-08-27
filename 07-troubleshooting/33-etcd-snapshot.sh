#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
INVENTORY="$PROJECT_ROOT/03-kubespray/inventory/mycluster/hosts.yaml"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$PROJECT_ROOT/03-kubespray/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/neuroplan_k8s}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_DIR="/var/backups/etcd"
REMOTE_FILE="$REMOTE_DIR/neuroplan-etcd-$TIMESTAMP.db"
REMOTE_BASENAME="$(basename -- "$REMOTE_FILE")"
LOCAL_DIR="$PROJECT_ROOT/logs/etcd-snapshots/$TIMESTAMP"
ENCRYPTION_CREDENTIAL="$PROJECT_ROOT/03-kubespray/inventory/mycluster/credentials/kube_encrypt_token.creds"

export KUBESPRAY_DIR
export ANSIBLE_CONFIG="$PROJECT_ROOT/03-kubespray/ansible.cfg"
install -d -m 0700 "$LOCAL_DIR"
[[ -s "$ENCRYPTION_CREDENTIAL" ]] || {
  echo "Secret encryption credential is missing: $ENCRYPTION_CREDENTIAL" >&2
  echo "Do not take a new encrypted-cluster backup until key recovery is resolved" >&2
  exit 1
}

SNAPSHOT_COMMAND="install -d -m 0700 $REMOTE_DIR && /usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem endpoint health --cluster && /usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/node-cp1.pem --key=/etc/ssl/etcd/ssl/node-cp1-key.pem snapshot save $REMOTE_FILE && /usr/local/bin/etcdutl snapshot status $REMOTE_FILE --write-out=table && cd $REMOTE_DIR && sha256sum $REMOTE_BASENAME >$REMOTE_BASENAME.sha256"

"$VENV_DIR/bin/ansible" -i "$INVENTORY" cp1 --private-key "$SSH_KEY" -b \
  -m ansible.builtin.shell -a "$SNAPSHOT_COMMAND"
"$VENV_DIR/bin/ansible" -i "$INVENTORY" cp1 --private-key "$SSH_KEY" -b \
  -m ansible.builtin.fetch \
  -a "src=$REMOTE_FILE dest=$LOCAL_DIR/ flat=true"
"$VENV_DIR/bin/ansible" -i "$INVENTORY" cp1 --private-key "$SSH_KEY" -b \
  -m ansible.builtin.fetch \
  -a "src=$REMOTE_FILE.sha256 dest=$LOCAL_DIR/ flat=true"

(cd -- "$LOCAL_DIR" && sha256sum -c "$(basename -- "$REMOTE_FILE").sha256")
echo "snapshot fetched to $LOCAL_DIR"
echo "copy both files to the approved NFS /backup/etcd path"
echo "back up the Kubespray credentials directory separately in an encrypted, access-controlled secret store"
echo "never place kube_encrypt_token.creds beside the NFS snapshot or in Git"

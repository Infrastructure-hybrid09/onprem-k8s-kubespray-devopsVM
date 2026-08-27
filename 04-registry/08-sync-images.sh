#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REGISTRY_ENDPOINT="192.168.34.21:5000"
DOCKERHUB_AUTH_FILE="$HOME/.config/containers/dockerhub-auth.json"
IMAGE_FILE="${1:-$SCRIPT_DIR/08-images.txt}"
LOCK_FILE="$SCRIPT_DIR/08-images.lock"
LOCK_TMP="$(mktemp "$SCRIPT_DIR/.images.lock.XXXXXX")"
ROOT_TMP_DIR=""
ROOT_DIGEST_FILE=""

cleanup() {
  [[ -z "${LOCK_TMP:-}" ]] || rm -f -- "$LOCK_TMP"
  if [[ "${ROOT_TMP_DIR:-}" == /var/tmp/neuroplan-image-sync.* ]]; then
    [[ -z "${ROOT_DIGEST_FILE:-}" ]] || \
      sudo -n rm -f -- "$ROOT_DIGEST_FILE" >/dev/null 2>&1 || true
    sudo -n rmdir -- "$ROOT_TMP_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for command in podman curl sudo; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done
[[ -f "$IMAGE_FILE" ]] || { echo "image list not found: $IMAGE_FILE" >&2; exit 1; }
[[ -f "$DOCKERHUB_AUTH_FILE" && ! -L "$DOCKERHUB_AUTH_FILE" ]] || {
  echo "Docker Hub auth is missing; run 04-registry/06-configure-dockerhub-auth.sh" >&2
  exit 1
}
[[ "$(stat -c '%U:%a' "$DOCKERHUB_AUTH_FILE")" == "devops:600" ]] || {
  echo "Docker Hub auth must be owned by devops with mode 0600" >&2
  exit 1
}
podman login --authfile "$DOCKERHUB_AUTH_FILE" --get-login docker.io >/dev/null || {
  echo "Docker Hub login is not present in $DOCKERHUB_AUTH_FILE" >&2
  exit 1
}
curl -fsS "http://$REGISTRY_ENDPOINT/v2/" >/dev/null

# A rootful Podman process must create its digest file in a root-owned
# directory. Reusing a devops-owned /tmp file can be rejected by the host's
# protected-regular/SELinux policy even though the image push itself succeeds.
sudo -v
ROOT_TMP_DIR="$(sudo mktemp -d /var/tmp/neuroplan-image-sync.XXXXXX)"
if [[ "$ROOT_TMP_DIR" != /var/tmp/neuroplan-image-sync.* ]]; then
  echo "unexpected root temporary directory: $ROOT_TMP_DIR" >&2
  exit 1
fi
ROOT_DIGEST_FILE="$ROOT_TMP_DIR/push.digest"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

line_number=0
while IFS='|' read -r source target extra || [[ -n "${source:-}${target:-}${extra:-}" ]]; do
  line_number=$((line_number + 1))
  source="$(trim "${source%$'\r'}")"
  target="$(trim "${target%$'\r'}")"
  extra="$(trim "${extra%$'\r'}")"
  [[ -z "$source" || "$source" == \#* ]] && continue

  if [[ -z "$target" || -n "$extra" || "$target" == *:latest ]]; then
    echo "invalid SOURCE|TARGET mapping at line $line_number" >&2
    exit 1
  fi
  [[ "$source" == */* && "$target" == */*:* ]] || {
    echo "fully qualified source and tagged target required at line $line_number" >&2
    exit 1
  }

  destination="$REGISTRY_ENDPOINT/$target"
  repository="${target%:*}"
  tag="${target##*:}"

  echo "syncing $source -> $destination"
  sudo podman pull --authfile "$DOCKERHUB_AUTH_FILE" "$source"
  sudo podman tag "$source" "$destination"
  sudo rm -f -- "$ROOT_DIGEST_FILE"
  sudo podman push --tls-verify=false \
    --digestfile "$ROOT_DIGEST_FILE" "$destination"
  digest="$(sudo cat "$ROOT_DIGEST_FILE" | tr -d '\r\n')"
  [[ -n "$digest" ]] || { echo "push returned no digest" >&2; exit 1; }
  sudo rm -f -- "$ROOT_DIGEST_FILE"

  curl -fsSI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://$REGISTRY_ENDPOINT/v2/$repository/manifests/$tag" >/dev/null
  printf '%s|%s/%s@%s\n' "$source" "$REGISTRY_ENDPOINT" "$repository" "$digest" >>"$LOCK_TMP"
done <"$IMAGE_FILE"

sudo rmdir -- "$ROOT_TMP_DIR"
ROOT_TMP_DIR=""
ROOT_DIGEST_FILE=""
mv -f -- "$LOCK_TMP" "$LOCK_FILE"
LOCK_TMP=""
echo "image synchronization complete: $LOCK_FILE"

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REGISTRY_ENDPOINT="192.168.34.21:5000"
EXPECTED_IMAGES=5

curl -fsS "http://$REGISTRY_ENDPOINT/v2/" >/dev/null
sudo systemctl is-active --quiet onprem-registry.service
sudo ss -lnt | grep -Fq '192.168.34.21:5000'

ACTUAL_IMAGES="$("$SCRIPT_DIR/09-list-images.sh" | wc -l)"
if (( ACTUAL_IMAGES < EXPECTED_IMAGES )); then
  echo "expected at least $EXPECTED_IMAGES tags, found $ACTUAL_IMAGES" >&2
  "$SCRIPT_DIR/09-list-images.sh" >&2
  exit 1
fi

sudo podman pull --tls-verify=false \
  "$REGISTRY_ENDPOINT/neuroplan/busybox:1.36.1"
sudo podman run --rm \
  "$REGISTRY_ENDPOINT/neuroplan/busybox:1.36.1" \
  echo registry-podman-ok

echo "registry verification completed"

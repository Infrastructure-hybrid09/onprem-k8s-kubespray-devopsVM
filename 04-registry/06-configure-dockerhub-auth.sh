#!/usr/bin/env bash
set -Eeuo pipefail
set +x

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi
if (( $# != 0 )); then
  echo "usage: ./04-registry/06-configure-dockerhub-auth.sh" >&2
  exit 2
fi

AUTH_DIR="$HOME/.config/containers"
AUTH_FILE="$AUTH_DIR/dockerhub-auth.json"
AUTH_TMP=""
DOCKERHUB_TOKEN=""

cleanup() {
  unset DOCKERHUB_TOKEN
  if [[ -n "$AUTH_TMP" ]]; then
    rm -f -- "$AUTH_TMP"
  fi
}
trap cleanup EXIT

for command in podman jq; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command; rerun 01-bootstrap/00-devops-bootstrap.sh" >&2
    exit 1
  }
done

install -d -m 0700 "$AUTH_DIR"
if [[ -L "$AUTH_FILE" || ( -e "$AUTH_FILE" && ! -f "$AUTH_FILE" ) ]]; then
  echo "refusing to replace a symbolic link or non-regular path: $AUTH_FILE" >&2
  exit 1
fi

read -r -p "Docker Hub ID: " DOCKERHUB_USER
if [[ ! "$DOCKERHUB_USER" =~ ^[a-z0-9]{4,30}$ ]]; then
  echo "Docker Hub ID must be 4-30 lowercase letters or digits" >&2
  exit 2
fi

echo "Use a dedicated Read-only PAT with an expiration date, not the account password."
IFS= read -r -s -p "Docker Hub Read-only PAT: " DOCKERHUB_TOKEN
printf '\n'
[[ -n "$DOCKERHUB_TOKEN" ]] || { echo "empty PAT is not allowed" >&2; exit 2; }

AUTH_TMP="$(mktemp "$AUTH_DIR/.dockerhub-auth.XXXXXX")"
chmod 0600 "$AUTH_TMP"
printf '{"auths":{}}\n' >"$AUTH_TMP"

printf '%s' "$DOCKERHUB_TOKEN" | podman login \
  --authfile "$AUTH_TMP" \
  --username "$DOCKERHUB_USER" \
  --password-stdin \
  docker.io
unset DOCKERHUB_TOKEN

jq -e '
  (.auths | type == "object") and
  any(.auths | keys[]; contains("docker.io"))
' "$AUTH_TMP" >/dev/null || {
  echo "Podman did not create a valid registry auth file" >&2
  exit 1
}

LOGIN_USER="$(podman login --authfile "$AUTH_TMP" --get-login docker.io)"
[[ "$LOGIN_USER" == "$DOCKERHUB_USER" ]] || {
  echo "authenticated user mismatch" >&2
  exit 1
}

mv -f -- "$AUTH_TMP" "$AUTH_FILE"
AUTH_TMP=""
chmod 0600 "$AUTH_FILE"

echo "Docker Hub authentication configured for: $LOGIN_USER"
echo "credential file: $AUTH_FILE (mode 0600, outside the repository)"
echo "The file contains a reversible credential; do not copy, print, or commit it."

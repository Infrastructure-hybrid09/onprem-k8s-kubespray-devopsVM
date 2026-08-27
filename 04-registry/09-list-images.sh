#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

REGISTRY_URL="http://192.168.34.21:5000"
for command in curl jq; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 1; }
done

curl -fsS "$REGISTRY_URL/v2/" >/dev/null
curl -fsS "$REGISTRY_URL/v2/_catalog?n=1000" |
  jq -r '.repositories[]?' |
  while IFS= read -r repository; do
    curl -fsS "$REGISTRY_URL/v2/$repository/tags/list?n=1000" |
      jq -r --arg repository "$repository" '.tags[]? | "\($repository):\(.)"'
  done

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_DIRS=(
  01-bootstrap
  02-ansible
  03-kubespray
  04-registry
  05-k8s-addons
  06-validation
  07-troubleshooting
)

for directory in "${SCRIPT_DIRS[@]}"; do
  if [[ ! -d "${PROJECT_ROOT}/${directory}" ]]; then
    echo "required directory is missing: ${PROJECT_ROOT}/${directory}" >&2
    exit 1
  fi
done

script_count=0
chmod 0755 -- "${PROJECT_ROOT}/00-set-executable-permissions.sh"
script_count=$((script_count + 1))

for directory in "${SCRIPT_DIRS[@]}"; do
  while IFS= read -r -d '' script_path; do
    chmod 0755 -- "${script_path}"
    script_count=$((script_count + 1))
  done < <(find "${PROJECT_ROOT}/${directory}" -maxdepth 1 -type f -name '*.sh' -print0)
done

echo "[PASS] executable permission initialized for ${script_count} shell scripts"
echo "YAML, Jinja2 templates, configuration files and documentation were not changed"

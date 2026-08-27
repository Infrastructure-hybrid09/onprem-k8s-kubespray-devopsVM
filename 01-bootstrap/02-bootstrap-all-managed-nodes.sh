#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONTROL_GATE="${SCRIPT_DIR}/05-verify-devops-control.sh"

if (( $# != 0 )); then
  echo "usage: $0" >&2
  exit 2
fi

cat <<'EOF'
[INFO] Remote root bootstrap is retired.

The fixed operating model is:
  - one-time k8sadmin creation at each CP/Worker VMware root console
  - every later command on the PC2 DevOps VM as devops
  - remote automation as k8sadmin with public-key SSH and sudo

This compatibility command now performs the read-only DevOps central-control gate.
EOF

exec "${CONTROL_GATE}"

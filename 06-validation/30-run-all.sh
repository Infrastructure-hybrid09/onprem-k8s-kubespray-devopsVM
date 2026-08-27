#!/usr/bin/env bash
set -uo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_HPA_TESTS="${RUN_HPA_TESTS:-1}"
PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local script="$1"
  echo
  echo "===== $(basename -- "$script") ====="
  if "$script"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

run_test "$SCRIPT_DIR/23-verify-cluster.sh"
run_test "$SCRIPT_DIR/24-verify-network.sh"
run_test "$SCRIPT_DIR/25-test-self-healing.sh"
if [[ "$RUN_HPA_TESTS" == "1" ]]; then
  run_test "$SCRIPT_DIR/26-test-hpa.sh"
fi
run_test "$SCRIPT_DIR/27-verify-pdb.sh"
run_test "$SCRIPT_DIR/28-verify-ngf.sh"
run_test "$SCRIPT_DIR/29-verify-ha-readonly.sh"

echo
echo "Validation summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
(( FAIL_COUNT == 0 ))

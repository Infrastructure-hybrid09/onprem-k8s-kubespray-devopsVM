#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$SCRIPT_DIR/vendor/kubespray}"
VENV_DIR="${VENV_DIR:-$PROJECT_ROOT/.venv}"
KUBESPRAY_TAG="v2.31.0"
EXPECTED_COMMIT="1c9add48975060f45396b34d8e022c30d7f80dab"

for command in git python3.11; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

if [[ ! -d "$KUBESPRAY_DIR/.git" ]]; then
  install -d -m 0755 "$(dirname -- "$KUBESPRAY_DIR")"
  git clone --branch "$KUBESPRAY_TAG" --depth 1 \
    https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
fi

ACTUAL_COMMIT="$(git -C "$KUBESPRAY_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "unexpected Kubespray commit: $ACTUAL_COMMIT" >&2
  echo "expected: $EXPECTED_COMMIT" >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3.11 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install \
  -r "$KUBESPRAY_DIR/requirements.txt"

echo "Kubespray $KUBESPRAY_TAG installed at $KUBESPRAY_DIR"
echo "Commit: $ACTUAL_COMMIT"
echo "Activate with: source $VENV_DIR/bin/activate"

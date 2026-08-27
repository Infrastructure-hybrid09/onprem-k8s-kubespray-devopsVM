#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 || "$(id -un)" != "devops" ]]; then
  echo "run on the PC2 DevOps VM as the devops user" >&2
  exit 1
fi

SERVICE_NAME="onprem-registry.service"
ACTION="${1:-status}"

case "$ACTION" in
  start|stop|restart|status)
    sudo systemctl "$ACTION" "$SERVICE_NAME"
    ;;
  logs)
    sudo journalctl -u "$SERVICE_NAME" -b -n 200 --no-pager
    ;;
  follow)
    sudo journalctl -fu "$SERVICE_NAME"
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|logs|follow}" >&2
    exit 2
    ;;
esac

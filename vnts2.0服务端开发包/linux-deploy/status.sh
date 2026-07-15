#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_NAME="vnts2.service"

systemctl --no-pager --full status "${SERVICE_NAME}" || true
printf '\n最近 20 条日志：\n'
journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true

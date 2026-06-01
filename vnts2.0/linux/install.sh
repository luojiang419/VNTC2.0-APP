#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行此脚本。"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-/root/vnts2}"
SERVICE_NAME="vnts2.service"

install -d "${TARGET_DIR}"
install -m 755 "${SCRIPT_DIR}/vnts2" "${TARGET_DIR}/vnts2"
install -m 644 "${SCRIPT_DIR}/config.toml" "${TARGET_DIR}/config.toml"
sed "s#/root/vnts2#${TARGET_DIR}#g" "${SCRIPT_DIR}/${SERVICE_NAME}" > "/etc/systemd/system/${SERVICE_NAME}"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "VNTS 已部署到 ${TARGET_DIR}"
systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,12p'

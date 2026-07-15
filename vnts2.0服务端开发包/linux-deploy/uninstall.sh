#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_NAME="vnts2.service"
readonly SERVICE_USER="vnts2"
readonly INSTALL_DIR="/opt/vnts2"
readonly CONFIG_DIR="/etc/vnts2"
readonly DATA_DIR="/var/lib/vnts2"

if [[ "${EUID}" -ne 0 ]]; then
  printf '错误：请使用 root 运行此脚本。\n' >&2
  exit 1
fi

purge=false
case "${1:-}" in
  "") ;;
  --purge) purge=true ;;
  *) printf '用法：%s [--purge]\n' "$0" >&2; exit 2 ;;
esac

systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -f -- "/etc/systemd/system/${SERVICE_NAME}"
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
rm -rf -- "${INSTALL_DIR}"

if [[ "${purge}" == true ]]; then
  [[ "${CONFIG_DIR}" == "/etc/vnts2" ]] || exit 1
  [[ "${DATA_DIR}" == "/var/lib/vnts2" ]] || exit 1
  rm -rf -- "${CONFIG_DIR}" "${DATA_DIR}"
  userdel "${SERVICE_USER}" >/dev/null 2>&1 || true
  printf 'VNTS 2.0 已卸载，配置和数据已清除。\n'
else
  printf 'VNTS 2.0 已卸载；配置和数据已保留。需要彻底清除时使用 --purge。\n'
fi

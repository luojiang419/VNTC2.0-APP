#!/usr/bin/env bash
set -euo pipefail

service_name="vntc-linux-webui"
service_user="vntc"
purge=false

if [[ "${1:-}" == "--purge" ]]; then
  purge=true
elif [[ $# -gt 0 ]]; then
  echo "用法：sudo ./uninstall.sh [--purge]" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo ./uninstall.sh" >&2
  exit 1
fi

systemctl disable --now "$service_name.service" 2>/dev/null || true
rm -f "/etc/systemd/system/$service_name.service"
rm -f "/usr/local/bin/$service_name"
systemctl daemon-reload

if [[ "$purge" == true ]]; then
  rm -rf -- "/etc/$service_name" "/var/lib/$service_name"
  userdel "$service_user" 2>/dev/null || true
  echo "已卸载服务并删除配置、状态和服务用户。"
else
  echo "已卸载服务，配置保留在 /etc/$service_name/config.json。"
  echo "如需彻底删除，请运行：sudo ./uninstall.sh --purge"
fi

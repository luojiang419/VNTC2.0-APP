#!/usr/bin/env bash
set -euo pipefail

config_path="${VNTC_CONFIG:-/data/config.json}"
config_dir="$(dirname "$config_path")"

mkdir -p "$config_dir"
if [[ ! -f "$config_path" ]]; then
  install -m 0600 /opt/vntc/config.example.json "$config_path"
  echo "已创建默认配置：$config_path"
fi

if [[ ! -c /dev/net/tun ]]; then
  echo "警告：容器内没有 /dev/net/tun；WebUI 可以启动，但 TUN 网络无法连接" >&2
fi

exec /usr/local/bin/vntc-linux-webui --config "$config_path" "$@"

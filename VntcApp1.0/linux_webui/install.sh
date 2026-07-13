#!/usr/bin/env bash
set -euo pipefail

service_name="vntc-linux-webui"
service_user="vntc"
install_dir="/usr/local/bin"
config_dir="/etc/vntc-linux-webui"
state_dir="/var/lib/vntc-linux-webui"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行：sudo ./install.sh" >&2
  exit 1
fi

for command_name in install useradd systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "缺少安装所需命令：$command_name" >&2
    exit 1
  fi
done

if [[ ! -c /dev/net/tun ]]; then
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun || true
  fi
  if [[ ! -c /dev/net/tun ]]; then
    echo "系统没有可用的 /dev/net/tun，请启用 Linux TUN 内核模块" >&2
    exit 1
  fi
fi

for file in "vntc-linux-webui" "config.example.json" "vntc-linux-webui.service"; do
  if [[ ! -f "$script_dir/$file" ]]; then
    echo "安装包缺少文件：$file" >&2
    exit 1
  fi
done

if ! id "$service_user" >/dev/null 2>&1; then
  useradd --system --home-dir "$state_dir" --shell /usr/sbin/nologin "$service_user"
fi

install -d -m 0750 -o "$service_user" -g "$service_user" "$config_dir" "$state_dir"
install -m 0755 "$script_dir/vntc-linux-webui" "$install_dir/vntc-linux-webui"

if [[ ! -f "$config_dir/config.json" ]]; then
  install -m 0640 -o "$service_user" -g "$service_user" \
    "$script_dir/config.example.json" "$config_dir/config.json"
  echo "已创建默认配置：$config_dir/config.json"
else
  echo "保留现有配置：$config_dir/config.json"
fi

install -m 0644 "$script_dir/vntc-linux-webui.service" \
  "/etc/systemd/system/$service_name.service"
systemctl daemon-reload
systemctl enable --now "$service_name.service"

echo
echo "VNTC Linux WebUI 安装完成。"
echo "本机访问：http://127.0.0.1:18080/"
echo "服务状态：systemctl status $service_name"
echo "实时日志：journalctl -u $service_name -f"
echo "修改配置：$config_dir/config.json"
echo
echo "默认配置不会自动连接。请先在 WebUI 中填写真实服务器地址和网络代码。"

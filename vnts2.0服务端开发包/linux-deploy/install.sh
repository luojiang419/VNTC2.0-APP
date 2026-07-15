#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_NAME="vnts2.service"
readonly SERVICE_USER="vnts2"
readonly INSTALL_DIR="/opt/vnts2"
readonly CONFIG_DIR="/etc/vnts2"
readonly DATA_DIR="/var/lib/vnts2"
readonly WIREGUARD_KEY_PATH="${DATA_DIR}/wireguard-master.key"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "请使用 root 运行此脚本（例如 sudo ./install.sh）。"

for command_name in install systemctl useradd getent awk od tr mktemp head stat chown chmod; do
  command -v "${command_name}" >/dev/null 2>&1 || die "缺少必要命令：${command_name}"
done

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "当前部署包仅支持 Linux x86_64，检测到：$(uname -m)" ;;
esac

[[ -x "${SCRIPT_DIR}/vnts2" ]] || die "部署包缺少可执行文件：${SCRIPT_DIR}/vnts2"
[[ -f "${SCRIPT_DIR}/config.example.toml" ]] || die "部署包缺少 config.example.toml"
[[ -f "${SCRIPT_DIR}/${SERVICE_NAME}" ]] || die "部署包缺少 ${SERVICE_NAME}"
"${SCRIPT_DIR}/vnts2" --version >/dev/null 2>&1 || die "vnts2 二进制无法在当前系统运行"

if ! getent passwd "${SERVICE_USER}" >/dev/null; then
  nologin_shell="$(command -v nologin || true)"
  [[ -n "${nologin_shell}" ]] || nologin_shell="/usr/sbin/nologin"
  useradd --system --home-dir "${DATA_DIR}" --shell "${nologin_shell}" "${SERVICE_USER}"
fi

install -d -m 0755 -o root -g root "${INSTALL_DIR}"
install -d -m 0750 -o root -g "${SERVICE_USER}" "${CONFIG_DIR}"
install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${DATA_DIR}"
install -m 0755 -o root -g root "${SCRIPT_DIR}/vnts2" "${INSTALL_DIR}/vnts2"

config_path="${DATA_DIR}/config.toml"
config_link="${CONFIG_DIR}/config.toml"
password_path="${CONFIG_DIR}/admin-password.txt"
if [[ -f "${config_path}" ]]; then
  backup_path="${config_path}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0640 -o root -g "${SERVICE_USER}" "${config_path}" "${backup_path}"
  printf '保留已有配置，并备份到 %s\n' "${backup_path}"
elif [[ -f "${config_link}" && ! -L "${config_link}" ]]; then
  backup_path="${config_link}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  install -m 0640 -o root -g "${SERVICE_USER}" "${config_link}" "${backup_path}"
  install -m 0640 -o root -g "${SERVICE_USER}" "${config_link}" "${config_path}"
  printf '迁移已有配置到持久数据目录，并备份到 %s\n' "${backup_path}"
else
  admin_password="$(od -An -N 24 -tx1 /dev/urandom | tr -d ' \n')"
  temp_config="$(mktemp)"
  temp_password="$(mktemp)"
  temp_wireguard_key=""
  wireguard_key_created=false
  cleanup_bootstrap_files() {
    rm -f -- "${temp_config:-}" "${temp_password:-}" "${temp_wireguard_key:-}"
    if [[ "${wireguard_key_created:-false}" == true ]]; then
      rm -f -- "${WIREGUARD_KEY_PATH}"
    fi
  }
  trap cleanup_bootstrap_files EXIT

  if [[ -e "${WIREGUARD_KEY_PATH}" || -L "${WIREGUARD_KEY_PATH}" ]]; then
    [[ -f "${WIREGUARD_KEY_PATH}" && ! -L "${WIREGUARD_KEY_PATH}" ]] \
      || die "WireGuard 主密钥路径必须是普通文件：${WIREGUARD_KEY_PATH}"
    [[ "$(stat -c '%s' "${WIREGUARD_KEY_PATH}")" -eq 32 ]] \
      || die "WireGuard 主密钥文件必须严格为 32 字节：${WIREGUARD_KEY_PATH}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${WIREGUARD_KEY_PATH}"
    chmod 0600 "${WIREGUARD_KEY_PATH}"
  else
    temp_wireguard_key="$(mktemp)"
    head -c 32 /dev/urandom > "${temp_wireguard_key}"
    [[ "$(stat -c '%s' "${temp_wireguard_key}")" -eq 32 ]] \
      || die "无法生成严格 32 字节的 WireGuard 主密钥"
    install -m 0600 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
      "${temp_wireguard_key}" "${WIREGUARD_KEY_PATH}"
    wireguard_key_created=true
  fi

  awk -v password="${admin_password}" '
    /^\[custom_nets\]$/ && !inserted {
      print ""
      print "# Web 管理端仅绑定本机回环地址；远程访问请使用 SSH 隧道。"
      print "web_bind = \"127.0.0.1:29871\""
      print "username = \"admin\""
      print "password = \"" password "\""
      print ""
      inserted = 1
    }
    { print }
  ' "${SCRIPT_DIR}/config.example.toml" > "${temp_config}"
  install -m 0640 -o root -g "${SERVICE_USER}" "${temp_config}" "${config_path}"
  printf '%s\n' "${admin_password}" > "${temp_password}"
  install -m 0600 -o root -g root "${temp_password}" "${password_path}"
  unset admin_password
  wireguard_key_created=false
  rm -f -- "${temp_config}" "${temp_password}" "${temp_wireguard_key}"
  trap - EXIT
  unset -f cleanup_bootstrap_files
fi

if [[ -e "${config_link}" || -L "${config_link}" ]]; then
  rm -f -- "${config_link}"
fi
ln -s "${config_path}" "${config_link}"

install -m 0644 -o root -g root "${SCRIPT_DIR}/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
install -m 0644 -o root -g root "${SCRIPT_DIR}/DEPLOY.md" "${INSTALL_DIR}/DEPLOY.md"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

stable_checks=0
for _ in {1..40}; do
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    stable_checks=$((stable_checks + 1))
  else
    stable_checks=0
  fi
  if (( stable_checks >= 6 )); then
    printf '\nVNTS 2.0 安装成功。\n'
    printf '  服务状态：systemctl status %s\n' "${SERVICE_NAME}"
    printf '  配置文件：%s\n' "${config_path}"
    printf '  数据目录：%s\n' "${DATA_DIR}"
    if [[ -f "${password_path}" ]]; then
      printf '  管理密码：sudo cat %s\n' "${password_path}"
    else
      printf '  管理密码：沿用已有配置（安装器未改写）\n'
    fi
    printf '  本地控制台：http://127.0.0.1:29871\n'
    printf '  WireGuard：UDP 51820（已自动启用）\n'
    exit 0
  fi
  sleep 0.5
done

systemctl --no-pager --full status "${SERVICE_NAME}" >&2 || true
journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
die "服务安装后未能正常启动"

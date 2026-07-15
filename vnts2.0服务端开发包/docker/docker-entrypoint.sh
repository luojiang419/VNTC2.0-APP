#!/bin/sh
set -eu

readonly DATA_DIR="/data"
readonly CONFIG_FILE="${DATA_DIR}/config.toml"
readonly PASSWORD_FILE="${DATA_DIR}/admin-password.txt"
readonly WIREGUARD_KEY_FILE="${DATA_DIR}/wireguard-master.key"
readonly TEMPLATE_FILE="/opt/vnts2/config.example.toml"

umask 077

if [ ! -f "${CONFIG_FILE}" ]; then
  admin_password="$(od -An -N 24 -tx1 /dev/urandom | tr -d ' \n')"
  temp_config="${DATA_DIR}/.config.toml.tmp.$$"
  temp_password="${DATA_DIR}/.admin-password.txt.tmp.$$"
  temp_wireguard_key=""
  wireguard_key_created=0
  cleanup_bootstrap_files() {
    rm -f -- "${temp_config:-}" "${temp_password:-}" "${temp_wireguard_key:-}"
    if [ "${wireguard_key_created:-0}" -eq 1 ]; then
      rm -f -- "${WIREGUARD_KEY_FILE}"
    fi
  }
  trap cleanup_bootstrap_files EXIT HUP INT TERM

  if [ -e "${WIREGUARD_KEY_FILE}" ] || [ -L "${WIREGUARD_KEY_FILE}" ]; then
    if [ ! -f "${WIREGUARD_KEY_FILE}" ] || [ -L "${WIREGUARD_KEY_FILE}" ]; then
      printf '错误：WireGuard 主密钥路径必须是普通文件：%s\n' "${WIREGUARD_KEY_FILE}" >&2
      exit 1
    fi
    if [ "$(wc -c < "${WIREGUARD_KEY_FILE}" | tr -d ' ')" -ne 32 ]; then
      printf '错误：WireGuard 主密钥文件必须严格为 32 字节：%s\n' "${WIREGUARD_KEY_FILE}" >&2
      exit 1
    fi
    chmod 0600 "${WIREGUARD_KEY_FILE}"
  else
    temp_wireguard_key="${DATA_DIR}/.wireguard-master.key.tmp.$$"
    head -c 32 /dev/urandom > "${temp_wireguard_key}"
    if [ "$(wc -c < "${temp_wireguard_key}" | tr -d ' ')" -ne 32 ]; then
      printf '错误：无法生成严格 32 字节的 WireGuard 主密钥。\n' >&2
      exit 1
    fi
    chmod 0600 "${temp_wireguard_key}"
  fi

  awk -v password="${admin_password}" '
    /^\[custom_nets\]$/ && !inserted {
      print ""
      print "# Web 管理端仅绑定容器回环地址；Linux 请配合 host 网络模式访问。"
      print "web_bind = \"127.0.0.1:29871\""
      print "username = \"admin\""
      print "password = \"" password "\""
      print ""
      inserted = 1
    }
    { print }
  ' "${TEMPLATE_FILE}" > "${temp_config}"
  printf '%s\n' "${admin_password}" > "${temp_password}"
  unset admin_password
  chmod 0600 "${temp_config}" "${temp_password}"
  if [ -n "${temp_wireguard_key}" ]; then
    mv -- "${temp_wireguard_key}" "${WIREGUARD_KEY_FILE}"
    temp_wireguard_key=""
    wireguard_key_created=1
  fi
  mv -- "${temp_password}" "${PASSWORD_FILE}"
  mv -- "${temp_config}" "${CONFIG_FILE}"
  wireguard_key_created=0
  trap - EXIT HUP INT TERM
  printf 'VNTS 2.0 已生成首次启动配置和 WireGuard 主密钥；管理密码保存在 /data/admin-password.txt。\n'
fi

if grep -Ev '^[[:space:]]*#' "${CONFIG_FILE}" | grep -Eq 'CHANGE_ME|GENERATE_ADMIN_PASSWORD|请替换'; then
  printf '错误：/data/config.toml 仍包含未替换的占位值。\n' >&2
  exit 1
fi

exec /opt/vnts2/vnts2 --conf "${CONFIG_FILE}"

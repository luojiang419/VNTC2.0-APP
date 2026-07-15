#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_NAME="vnts2.service"
readonly SERVICE_USER="vnts2"
readonly BINARY_PATH="/opt/vnts2/vnts2"
readonly CONFIG_PATH="/var/lib/vnts2/config.toml"
readonly DATA_DIR="/var/lib/vnts2"
readonly WIREGUARD_KEY_PATH="${DATA_DIR}/wireguard-master.key"

failures=0
warnings=0

pass() { printf '[通过] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf '[失败] %s\n' "$*"; failures=$((failures + 1)); }

printf 'VNTS 2.0 Linux 部署诊断\n\n'

if [[ -x "${BINARY_PATH}" ]] && "${BINARY_PATH}" --version >/dev/null 2>&1; then
  pass "二进制存在且可运行：$(${BINARY_PATH} --version)"
else
  fail "二进制缺失或无法运行：${BINARY_PATH}"
fi

if [[ -r "${CONFIG_PATH}" ]]; then
  if grep -Ev '^[[:space:]]*#' "${CONFIG_PATH}" | grep -Eq 'CHANGE_ME|GENERATE_ADMIN_PASSWORD|请替换'; then
    fail "配置文件仍包含占位值"
  else
    pass "配置文件存在且未发现占位值"
  fi
else
  fail "配置文件不存在或不可读：${CONFIG_PATH}"
fi

if [[ -r "${CONFIG_PATH}" ]] \
  && grep -Eq '^[[:space:]]*wireguard_master_key_file[[:space:]]*=' "${CONFIG_PATH}" \
  && grep -Eq '^[[:space:]]*wireguard_bind[[:space:]]*=' "${CONFIG_PATH}"; then
  pass "WireGuard 默认配置已启用"
else
  warn "WireGuard 配置未启用；已有部署可按需手工配置"
fi

if [[ -f "${WIREGUARD_KEY_PATH}" && ! -L "${WIREGUARD_KEY_PATH}" ]] \
  && [[ "$(stat -c '%s' "${WIREGUARD_KEY_PATH}")" -eq 32 ]] \
  && [[ "$(stat -c '%U:%G' "${WIREGUARD_KEY_PATH}")" == "${SERVICE_USER}:${SERVICE_USER}" ]] \
  && [[ "$(stat -c '%a' "${WIREGUARD_KEY_PATH}")" == "600" ]]; then
  pass "WireGuard 主密钥长度、属主和权限正确"
else
  fail "WireGuard 主密钥必须是 vnts2:vnts2 所有的 32 字节 0600 普通文件"
fi

if [[ -L /etc/vnts2/config.toml ]] && [[ "$(readlink -f /etc/vnts2/config.toml)" == "${CONFIG_PATH}" ]]; then
  pass "标准配置入口正确链接到持久数据目录"
else
  warn "/etc/vnts2/config.toml 未链接到 ${CONFIG_PATH}"
fi

if getent passwd "${SERVICE_USER}" >/dev/null 2>&1; then
  pass "服务账号存在：${SERVICE_USER}"
else
  fail "服务账号不存在：${SERVICE_USER}"
fi

if [[ -d "${DATA_DIR}" ]]; then
  if runuser -u "${SERVICE_USER}" -- test -w "${DATA_DIR}"; then
    pass "服务账号可写持久数据目录"
  else
    fail "服务账号不可写持久数据目录"
  fi
else
  fail "持久数据目录不存在：${DATA_DIR}"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
  pass "服务已设置开机启动"
else
  warn "服务未设置开机启动"
fi

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  pass "服务正在运行"
else
  fail "服务未运行"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -lntup | grep -Eq ':(29871|29872)([[:space:]]|$)'; then
    pass "检测到默认端口监听"
  else
    warn "未检测到默认端口监听；若已修改端口可忽略"
  fi
  if ss -lunp | grep -Eq ':51820([[:space:]]|$)'; then
    pass "WireGuard UDP 51820 正在监听"
  else
    warn "未检测到 WireGuard UDP 51820；若已修改端口可忽略"
  fi
else
  warn "系统缺少 ss，跳过端口检查"
fi

if command -v curl >/dev/null 2>&1; then
  if curl --fail --silent --show-error --max-time 3 http://127.0.0.1:29871/ >/dev/null; then
    pass "Web 控制台入口可访问"
  else
    warn "默认 Web 控制台入口不可访问；若已禁用或修改端口可忽略"
  fi
else
  warn "系统缺少 curl，跳过 Web 控制台检查"
fi

printf '\n诊断结束：Failures=%d; Warnings=%d\n' "${failures}" "${warnings}"
(( failures == 0 ))

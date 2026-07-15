#!/usr/bin/env bash
set -Eeuo pipefail

readonly BASE_URL="http://127.0.0.1:29871"
readonly PASSWORD_FILE="/etc/vnts2/admin-password.txt"
readonly DATABASE_FILE="/var/lib/vnts2/network_control.db"
readonly WIREGUARD_KEY_FILE="/var/lib/vnts2/wireguard-master.key"

api_token=""

die() {
  printf '验收失败：%s\n' "$*" >&2
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  printf '错误：安装后验收必须使用 root 运行。\n' >&2
  exit 1
fi

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT

login_and_check_status() {
  local password config_password login_payload
  password="$(tr -d '\r\n' < "${PASSWORD_FILE}")"
  [[ ${#password} -ge 12 ]] || die "管理密码文件无效"
  config_password="$(awk -F '"' '/^password[[:space:]]*=/ { print $2; exit }' /var/lib/vnts2/config.toml)"
  [[ "${password}" == "${config_password}" ]] || die "密码文件与运行配置不一致"
  login_payload="$(printf '{"username":"admin","password":"%s"}' "${password}")"
  if ! curl --fail --silent --show-error \
    -c "${temp_dir}/cookies.txt" \
    -H 'Content-Type: application/json' \
    --data "${login_payload}" \
    "${BASE_URL}/api/login" > "${temp_dir}/login.json"; then
    unset password config_password login_payload
    die "管理端登录请求失败"
  fi
  unset password config_password login_payload

  grep -q '"code":200' "${temp_dir}/login.json" || die "管理端登录响应语义错误"
  api_token="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "${temp_dir}/login.json")"
  [[ -n "${api_token}" ]] || die "管理端登录响应缺少访问令牌"
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${api_token}" \
    "${BASE_URL}/api/status" > "${temp_dir}/status.json"
  grep -q '"version":"2.0.0"' "${temp_dir}/status.json" || die "状态 API 版本错误"
  grep -q '"ready":true' "${temp_dir}/status.json" || die "状态 API 数据库未就绪"
  grep -q '"wireguard":{"configured":true,"running":true' "${temp_dir}/status.json" \
    || die "WireGuard 未处于已配置且运行状态"
}

systemctl is-active --quiet vnts2.service || die "服务未运行"
curl --fail --silent --show-error "${BASE_URL}/" >/dev/null || die "Web 控制台入口不可访问"
[[ -s "${DATABASE_FILE}" ]] || die "数据库文件不存在"
[[ -s "${PASSWORD_FILE}" ]] || die "管理密码文件不存在"
[[ -f "${WIREGUARD_KEY_FILE}" && ! -L "${WIREGUARD_KEY_FILE}" ]] \
  || die "WireGuard 主密钥不是普通文件"
[[ "$(stat -c '%s' "${WIREGUARD_KEY_FILE}")" -eq 32 ]] \
  || die "WireGuard 主密钥不是严格 32 字节"
[[ "$(stat -c '%U:%G' "${WIREGUARD_KEY_FILE}")" == "vnts2:vnts2" ]] \
  || die "WireGuard 主密钥属主错误"
[[ "$(stat -c '%a' "${WIREGUARD_KEY_FILE}")" == "600" ]] \
  || die "WireGuard 主密钥权限错误"
printf '[1/4] 首次启动、持久文件与 WireGuard 主密钥检查通过。\n'
login_and_check_status
printf '[2/4] 认证登录、状态 API 与 WireGuard 运行状态检查通过。\n'

test_network="linux-install-e2e-$$"
test_peer="linux-install-peer-$$"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${api_token}" \
  -H 'Content-Type: application/json' \
  --data "{\"network_code\":\"${test_network}\",\"gateway\":\"10.48.0.1\",\"netmask\":24,\"lease_duration\":60}" \
  "${BASE_URL}/api/networks" > "${temp_dir}/create-network.json"
grep -q '"code":200' "${temp_dir}/create-network.json" || die "创建 WireGuard 验收网络失败"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${api_token}" \
  -H 'Content-Type: application/json' \
  --data "{\"network_code\":\"${test_network}\",\"peer_id\":\"${test_peer}\"}" \
  "${BASE_URL}/api/wireguard/peers/generated" > "${temp_dir}/generated-peer.json"
grep -q '"code":200' "${temp_dir}/generated-peer.json" || die "自动生成 WireGuard 客户端配置失败"
grep -q '"private_key":"[^"]\+"' "${temp_dir}/generated-peer.json" \
  || die "生成响应缺少客户端私钥"
generated_endpoint="$(sed -n 's/.*"endpoint":"\([^"]*\)".*/\1/p' "${temp_dir}/generated-peer.json")"
case "${generated_endpoint}" in
  ""|0.0.0.0:*|'[::]':*|127.*|198.18.*|198.19.*)
    die "自动生成的 WireGuard Endpoint 不可连接：${generated_endpoint:-<empty>}"
    ;;
esac
printf '[3/4] WireGuard 客户端配置自动生成通过，Endpoint=%s。\n' "${generated_endpoint}"

database_inode_before="$(stat -c '%i' "${DATABASE_FILE}")"
wireguard_key_inode_before="$(stat -c '%i' "${WIREGUARD_KEY_FILE}")"
systemctl restart vnts2.service
for _ in {1..20}; do
  if systemctl is-active --quiet vnts2.service \
    && curl --fail --silent --max-time 2 "${BASE_URL}/" >/dev/null; then
    break
  fi
  sleep 0.5
done
systemctl is-active --quiet vnts2.service || die "重启后服务未运行"
login_and_check_status
database_inode_after="$(stat -c '%i' "${DATABASE_FILE}")"
[[ "${database_inode_before}" == "${database_inode_after}" ]] || die "重启后数据库文件被替换"
wireguard_key_inode_after="$(stat -c '%i' "${WIREGUARD_KEY_FILE}")"
[[ "${wireguard_key_inode_before}" == "${wireguard_key_inode_after}" ]] \
  || die "重启后 WireGuard 主密钥文件被替换"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${api_token}" \
  "${BASE_URL}/api/wireguard/peers?network_code=${test_network}" > "${temp_dir}/peers.json"
grep -q "\"peer_id\":\"${test_peer}\"" "${temp_dir}/peers.json" \
  || die "重启后 WireGuard Peer 未持久化"
curl --fail --silent --show-error -X DELETE \
  -H "Authorization: Bearer ${api_token}" \
  "${BASE_URL}/api/wireguard/peers?network_code=${test_network}&peer_id=${test_peer}" \
  > "${temp_dir}/delete-peer.json"
grep -q '"code":200' "${temp_dir}/delete-peer.json" || die "清理 WireGuard 验收 Peer 失败"
curl --fail --silent --show-error -X DELETE \
  -H "Authorization: Bearer ${api_token}" \
  "${BASE_URL}/api/networks/${test_network}" > "${temp_dir}/delete-network.json"
grep -q '"code":200' "${temp_dir}/delete-network.json" || die "清理 WireGuard 验收网络失败"
printf '[4/4] 服务重启、数据库、主密钥和 Peer 持久性检查通过。\n'

printf 'Linux 安装后验收通过：WireGuard 开箱即用、客户端配置生成、服务重启和持久性均正常。\n'

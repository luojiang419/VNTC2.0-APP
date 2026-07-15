#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE="vnts2:2.0.0"
readonly CONTAINER="vnts2-package-test"
readonly VOLUME="vnts2-package-test-data"

cleanup() {
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker image inspect "${IMAGE}" >/dev/null
[[ "$(docker image inspect --format '{{.Config.User}}' "${IMAGE}")" == "10001:10001" ]]

docker volume create "${VOLUME}" >/dev/null
docker run -d \
  --name "${CONTAINER}" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=1777 \
  --mount "type=volume,source=${VOLUME},target=/data" \
  "${IMAGE}" >/dev/null

for _ in {1..40}; do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER}")"
  [[ "${health}" == "healthy" ]] && break
  [[ "$(docker inspect --format '{{.State.Status}}' "${CONTAINER}")" == "running" ]] || {
    docker logs "${CONTAINER}" >&2
    exit 1
  }
  sleep 0.5
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER}")" == "healthy" ]]
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "${CONTAINER}")" == "true" ]]
[[ "$(docker inspect --format '{{.HostConfig.SecurityOpt}}' "${CONTAINER}")" == "[no-new-privileges:true]" ]]
docker exec "${CONTAINER}" /opt/vnts2/vnts2 --version | grep -q 'vnts2 2.0.0'
docker exec "${CONTAINER}" test -s /data/config.toml
docker exec "${CONTAINER}" test -s /data/admin-password.txt
docker exec "${CONTAINER}" test -s /data/network_control.db
docker exec "${CONTAINER}" test -f /data/wireguard-master.key
docker exec "${CONTAINER}" test ! -L /data/wireguard-master.key
[[ "$(docker exec "${CONTAINER}" stat -c '%s' /data/wireguard-master.key)" == "32" ]]
[[ "$(docker exec "${CONTAINER}" stat -c '%u:%g' /data/wireguard-master.key)" == "10001:10001" ]]
[[ "$(docker exec "${CONTAINER}" stat -c '%a' /data/wireguard-master.key)" == "600" ]]
docker exec "${CONTAINER}" sh -eu -c '
  password="$(tr -d "\r\n" < /data/admin-password.txt)"
  payload="$(printf "{\"username\":\"admin\",\"password\":\"%s\"}" "${password}")"
  curl --fail --silent --show-error -c /tmp/cookies.txt -H "Content-Type: application/json" \
    --data "${payload}" http://127.0.0.1:29871/api/login > /tmp/login.json
  unset password payload
  grep -q "\"code\":200" /tmp/login.json
  token="$(sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p" /tmp/login.json)"
  test -n "${token}"
  curl --fail --silent --show-error -H "Authorization: Bearer ${token}" \
    http://127.0.0.1:29871/api/status > /tmp/status.json
  grep -q "\"version\":\"2.0.0\"" /tmp/status.json
  grep -q "\"ready\":true" /tmp/status.json
  grep -q "\"wireguard\":{\"configured\":true,\"running\":true" /tmp/status.json
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "{\"network_code\":\"docker-image-e2e\",\"gateway\":\"10.49.0.1\",\"netmask\":24,\"lease_duration\":60}" \
    http://127.0.0.1:29871/api/networks > /tmp/create-network.json
  grep -q "\"code\":200" /tmp/create-network.json
  curl --fail --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "{\"network_code\":\"docker-image-e2e\",\"peer_id\":\"docker-image-peer\"}" \
    http://127.0.0.1:29871/api/wireguard/peers/generated > /tmp/generated-peer.json
  grep -q "\"code\":200" /tmp/generated-peer.json
  grep -q "\"private_key\":\"[^\"]\+\"" /tmp/generated-peer.json
  endpoint="$(sed -n "s/.*\"endpoint\":\"\([^\"]*\)\".*/\1/p" /tmp/generated-peer.json)"
  case "${endpoint}" in
    ""|0.0.0.0:*|"[::]":*|127.*|198.18.*|198.19.*)
      printf "错误：自动生成的 WireGuard Endpoint 不可连接：%s\n" "${endpoint:-<empty>}" >&2
      exit 1
      ;;
  esac
  printf "%s\n" "${endpoint}" > /data/.docker-e2e-endpoint
  rm -f /tmp/cookies.txt /tmp/login.json /tmp/status.json /tmp/create-network.json /tmp/generated-peer.json
'

config_hash_before="$(docker exec "${CONTAINER}" sha256sum /data/config.toml | awk '{print $1}')"
password_hash_before="$(docker exec "${CONTAINER}" sha256sum /data/admin-password.txt | awk '{print $1}')"
wireguard_key_hash_before="$(docker exec "${CONTAINER}" sha256sum /data/wireguard-master.key | awk '{print $1}')"
wireguard_key_inode_before="$(docker exec "${CONTAINER}" stat -c '%i' /data/wireguard-master.key)"
generated_endpoint="$(docker exec "${CONTAINER}" cat /data/.docker-e2e-endpoint)"

docker rm -f "${CONTAINER}" >/dev/null
docker run -d \
  --name "${CONTAINER}" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=1777 \
  --mount "type=volume,source=${VOLUME},target=/data" \
  "${IMAGE}" >/dev/null
for _ in {1..40}; do
  [[ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${CONTAINER}")" == "healthy" ]] && break
  sleep 0.5
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER}")" == "healthy" ]]
docker exec "${CONTAINER}" test -s /data/network_control.db
[[ "$(docker exec "${CONTAINER}" sha256sum /data/config.toml | awk '{print $1}')" == "${config_hash_before}" ]]
[[ "$(docker exec "${CONTAINER}" sha256sum /data/admin-password.txt | awk '{print $1}')" == "${password_hash_before}" ]]
[[ "$(docker exec "${CONTAINER}" sha256sum /data/wireguard-master.key | awk '{print $1}')" == "${wireguard_key_hash_before}" ]]
[[ "$(docker exec "${CONTAINER}" stat -c '%i' /data/wireguard-master.key)" == "${wireguard_key_inode_before}" ]]
docker exec "${CONTAINER}" sh -eu -c '
  password="$(tr -d "\r\n" < /data/admin-password.txt)"
  payload="$(printf "{\"username\":\"admin\",\"password\":\"%s\"}" "${password}")"
  curl --fail --silent --show-error -H "Content-Type: application/json" \
    --data "${payload}" http://127.0.0.1:29871/api/login > /tmp/login.json
  unset password payload
  token="$(sed -n "s/.*\"token\":\"\([^\"]*\)\".*/\1/p" /tmp/login.json)"
  test -n "${token}"
  curl --fail --silent --show-error -H "Authorization: Bearer ${token}" \
    "http://127.0.0.1:29871/api/wireguard/peers?network_code=docker-image-e2e" > /tmp/peers.json
  grep -q "\"peer_id\":\"docker-image-peer\"" /tmp/peers.json
  curl --fail --silent --show-error -X DELETE -H "Authorization: Bearer ${token}" \
    "http://127.0.0.1:29871/api/wireguard/peers?network_code=docker-image-e2e&peer_id=docker-image-peer" \
    > /tmp/delete-peer.json
  grep -q "\"code\":200" /tmp/delete-peer.json
  curl --fail --silent --show-error -X DELETE -H "Authorization: Bearer ${token}" \
    http://127.0.0.1:29871/api/networks/docker-image-e2e > /tmp/delete-network.json
  grep -q "\"code\":200" /tmp/delete-network.json
  rm -f /data/.docker-e2e-endpoint /tmp/login.json /tmp/peers.json /tmp/delete-peer.json /tmp/delete-network.json
'

if docker logs "${CONTAINER}" 2>&1 | grep -Eq '(^|[^0-9a-f])[0-9a-f]{48}([^0-9a-f]|$)'; then
  printf '错误：容器日志疑似包含管理密码。\n' >&2
  exit 1
fi

printf 'Docker 镜像验收通过：WireGuard 开箱即用，Endpoint=%s；非 root、只读根目录、健康检查和卷持久化均正常。\n' "${generated_endpoint}"

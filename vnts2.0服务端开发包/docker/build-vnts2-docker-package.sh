#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly DIST_DIR="${PACKAGE_ROOT}/dist"
readonly IMAGE="vnts2:2.0.0"
readonly ARCHIVE_NAME="vnts2-2.0.0-docker-linux-amd64.tar.gz"

for command_name in docker gzip sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '错误：缺少必要命令：%s\n' "${command_name}" >&2
    exit 1
  }
done
docker info >/dev/null 2>&1 || {
  printf '错误：Docker Linux 引擎未运行。\n' >&2
  exit 1
}

install -d "${DIST_DIR}"
archive_path="${DIST_DIR}/${ARCHIVE_NAME}"

docker build --pull --platform linux/amd64 \
  --file "${SCRIPT_DIR}/Dockerfile" \
  --tag "${IMAGE}" \
  "${PACKAGE_ROOT}"
docker image inspect "${IMAGE}" >/dev/null
docker save "${IMAGE}" | gzip -n -9 > "${archive_path}"
sha256sum "${archive_path}" > "${archive_path}.sha256"

printf 'Docker 离线镜像包已生成：%s\n' "${archive_path}"

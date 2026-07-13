#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 1 ]]; then
  echo "用法：$0 [镜像包.tar.gz]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  archive="$1"
  [[ "$archive" = /* ]] || archive="$PWD/$archive"
else
  shopt -s nullglob
  archives=("$script_dir"/VNTC_Linux_WebUI_*_Docker_amd64.tar.gz)
  shopt -u nullglob
  if [[ ${#archives[@]} -ne 1 ]]; then
    echo "发布目录必须且只能包含一个 VNTC Docker 离线镜像包" >&2
    exit 1
  fi
  archive="${archives[0]}"
fi

archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
hash_file="$archive.sha256"

command -v docker >/dev/null 2>&1 || {
  echo "未找到 docker 命令" >&2
  exit 1
}
[[ -f "$archive" ]] || {
  echo "镜像包不存在：$archive" >&2
  exit 1
}
[[ -f "$hash_file" ]] || {
  echo "校验文件不存在：$hash_file" >&2
  exit 1
}

cd "$(dirname "$archive")"
sha256sum --check "$(basename "$hash_file")"
gzip -dc "$(basename "$archive")" | docker load

echo "镜像导入完成。请执行：docker compose up -d"

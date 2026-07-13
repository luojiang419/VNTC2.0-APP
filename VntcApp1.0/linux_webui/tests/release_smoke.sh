#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "用法：tests/release_smoke.sh <release.tar.gz>" >&2
  exit 1
fi

archive="$(realpath "$1")"
hash_file="$archive.sha256"
work_dir="$(mktemp -d)"

cleanup() {
  if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -INT "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

(
  cd "$(dirname "$archive")"
  sha256sum -c "$(basename "$hash_file")"
)

tar -xzf "$archive" -C "$work_dir"
package_dir="$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$package_dir" ]]; then
  echo "压缩包中没有顶层目录" >&2
  exit 1
fi

(
  cd "$package_dir"
  sha256sum -c SHA256SUMS
)

[[ "$(stat -c '%a' "$package_dir/vntc-linux-webui")" == "755" ]]
[[ "$(stat -c '%a' "$package_dir/install.sh")" == "755" ]]
[[ "$(stat -c '%a' "$package_dir/uninstall.sh")" == "755" ]]
[[ "$(stat -c '%a' "$package_dir/config.example.json")" == "644" ]]
[[ "$(stat -c '%a' "$package_dir/vntc-linux-webui.service")" == "644" ]]

file "$package_dir/vntc-linux-webui" | grep -q "ELF 64-bit.*x86-64"
"$package_dir/vntc-linux-webui" --config "$package_dir/config.example.json" --check-config

"$package_dir/vntc-linux-webui" --config "$package_dir/config.example.json" \
  >"$work_dir/server.out" 2>"$work_dir/server.err" &
server_pid=$!

for _ in $(seq 1 30); do
  if health="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/health)"; then
    break
  fi
  sleep 0.2
done
if [[ -z "${health:-}" ]]; then
  cat "$work_dir/server.err" >&2
  exit 1
fi

status="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/status)"
index="$(curl --fail --silent --show-error http://127.0.0.1:18080/)"
grep -q '"phase":"stopped"' <<<"$status"
grep -q "VNTC Linux" <<<"$index"

printf 'RELEASE_HEALTH=%s\nRELEASE_STATUS=%s\n' "$health" "$status"

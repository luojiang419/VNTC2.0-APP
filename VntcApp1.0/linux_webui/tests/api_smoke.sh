#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$project_dir/target/debug/vntc-linux-webui"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
work_dir="$(mktemp -d)"
config_file="$work_dir/config.json"
cp "$project_dir/config.example.json" "$config_file"

cargo build --manifest-path "$project_dir/Cargo.toml" --bin vntc-linux-webui

cleanup() {
  if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -INT "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$stdout_file" "$stderr_file"
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

"$binary" --config "$config_file" \
  >"$stdout_file" 2>"$stderr_file" &
server_pid=$!

for _ in $(seq 1 30); do
  if health="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/health)"; then
    break
  fi
  sleep 0.2
done

if [[ -z "${health:-}" ]]; then
  cat "$stderr_file" >&2
  exit 1
fi

status="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/status)"
index="$(curl --fail --silent --show-error http://127.0.0.1:18080/)"
javascript="$(curl --fail --silent --show-error http://127.0.0.1:18080/assets/js/app.js)"
stylesheet="$(curl --fail --silent --show-error http://127.0.0.1:18080/assets/styles/responsive.css)"
profiles="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/profiles)"
settings="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/settings)"
about="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/about)"
backup="$(curl --fail --silent --show-error http://127.0.0.1:18080/api/backup)"

grep -q "VNTC Linux" <<<"$index"
grep -q 'document.addEventListener("DOMContentLoaded", boot)' <<<"$javascript"
grep -q "@media (max-width: 680px)" <<<"$stylesheet"
grep -q '仪表盘' <<<"$index"
grep -q '链接状态' <<<"$index"
grep -q '"default_profile_id"' <<<"$profiles"
grep -q '"refresh_interval_seconds":5' <<<"$settings"
grep -q '"version":"4.5.0"' <<<"$about"
grep -q '"schema_version":1' <<<"$backup"

printf 'HEALTH=%s\nSTATUS=%s\nPROFILES=%s\nSETTINGS=%s\nABOUT=%s\n' "$health" "$status" "$profiles" "$settings" "$about"

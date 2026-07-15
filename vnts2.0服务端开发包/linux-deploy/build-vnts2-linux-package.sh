#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_DIR="${PACKAGE_ROOT}/official-vnts-source-2.0.0"
readonly DIST_DIR="${PACKAGE_ROOT}/dist"
readonly VERSION="2.0.0"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *) printf '错误：该脚本必须在 Linux x86_64 环境运行。\n' >&2; exit 1 ;;
esac

for command_name in cargo tar gzip sha256sum mktemp; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '错误：缺少必要命令：%s\n' "${command_name}" >&2
    exit 1
  }
done

build_root="$(mktemp -d)"
trap 'rm -rf -- "${build_root}"' EXIT
export CARGO_TARGET_DIR="${build_root}/target"

printf '构建 VNTS %s Linux x86_64 二进制...\n' "${VERSION}"
cargo build --manifest-path "${SOURCE_DIR}/Cargo.toml" --release --locked

package_name="vnts2-${VERSION}-linux-x86_64"
stage_dir="${build_root}/${package_name}"
install -d "${stage_dir}"
install -m 0755 "${CARGO_TARGET_DIR}/release/vnts2" "${stage_dir}/vnts2"
for file_name in install.sh status.sh diagnose.sh uninstall.sh; do
  install -m 0755 "${SCRIPT_DIR}/${file_name}" "${stage_dir}/${file_name}"
done
install -m 0644 "${SCRIPT_DIR}/config.example.toml" "${stage_dir}/config.example.toml"
install -m 0644 "${SCRIPT_DIR}/vnts2.service" "${stage_dir}/vnts2.service"
install -m 0644 "${SCRIPT_DIR}/DEPLOY.md" "${stage_dir}/DEPLOY.md"
install -m 0644 "${SOURCE_DIR}/NOTICE" "${stage_dir}/NOTICE"

(
  cd "${stage_dir}"
  sha256sum vnts2 install.sh status.sh diagnose.sh uninstall.sh config.example.toml vnts2.service DEPLOY.md NOTICE > SHA256SUMS
)

install -d "${DIST_DIR}"
archive_path="${DIST_DIR}/${package_name}.tar.gz"
epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"
tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
  -C "${build_root}" -cf - "${package_name}" | gzip -n -9 > "${archive_path}"
(
  cd "${DIST_DIR}"
  sha256sum "${package_name}.tar.gz" > "${package_name}.tar.gz.sha256"
)

printf 'Linux 部署包已生成：%s\n' "${archive_path}"

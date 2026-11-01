#!/usr/bin/env bash
set -euo pipefail
package_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-2.0.0}"
arch="${3:-aarch64}"
manifest="$package_root/official-vnts-source-2.0.0/Cargo.toml"
binary_name=vnts2
feature=openwrt
source "$package_root/../tools/openwrt/build-common.sh"
build_openwrt_binary
package_args=()
[[ -z "${4:-}" ]] || package_args=(--package-arch "$4")
python3 "$package_root/openwrt/package.py" --binary "$binary" --version "$version" --arch "$arch" \
    --output "${2:-$package_root/dist/openwrt/$arch}" "${package_args[@]}"

#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/vntc-openwrt/target}"
version="${1:-$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$project_dir/pubspec.yaml" | head -1)}"
export VNTC_APP_VERSION="$version"
export VNTC_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
arch="${3:-x86_64}"
manifest="$project_dir/linux_webui/Cargo.toml"
binary_name=vntc-linux-webui
feature=openwrt
source "$project_dir/../tools/openwrt/build-common.sh"
build_openwrt_binary
if [[ "$arch" == x86_64 ]]; then
    cargo test --manifest-path "$manifest" --locked --features openwrt --target "$rust_target"
fi
package_args=()
[[ -z "${4:-}" ]] || package_args=(--package-arch "$4")
python3 "$project_dir/openwrt/package.py" --binary "$binary" --version "$version" --arch "$arch" \
    --revision "${VNTC_PACKAGE_REVISION:-2}" --output "${2:-$project_dir/release/openwrt}" "${package_args[@]}"

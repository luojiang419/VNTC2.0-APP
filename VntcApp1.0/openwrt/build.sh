#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/vntc-openwrt/target}"
export CC_x86_64_unknown_linux_musl=musl-gcc
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc
export CARGO_PROFILE_RELEASE_OPT_LEVEL=s
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_STRIP=symbols
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_PANIC=abort
version="${1:-$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$project_dir/pubspec.yaml" | head -1)}"
export VNTC_APP_VERSION="$version"
export VNTC_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rustup target add x86_64-unknown-linux-musl
cargo fmt --manifest-path "$project_dir/linux_webui/Cargo.toml" --check
cargo test --manifest-path "$project_dir/linux_webui/Cargo.toml" --locked --features openwrt --target x86_64-unknown-linux-musl
cargo build --manifest-path "$project_dir/linux_webui/Cargo.toml" --locked --features openwrt --release --target x86_64-unknown-linux-musl
binary="$CARGO_TARGET_DIR/x86_64-unknown-linux-musl/release/vntc-linux-webui"
"$binary" --help
if readelf -l "$binary" | grep -q INTERP; then
    echo '构建失败：要求静态 musl 可执行文件' >&2; exit 1
fi
python3 "$project_dir/openwrt/package.py" --binary "$binary" --version "$version" --output "${2:-$project_dir/release/openwrt}"

#!/usr/bin/env bash
# 调用方设置 manifest、arch、binary_name、feature 后调用 build_openwrt_binary。
build_openwrt_binary() {
    case "$arch" in
        x86_64) rust_target=x86_64-unknown-linux-musl; runner=() ;;
        aarch64) rust_target=aarch64-unknown-linux-musl; runner=(qemu-aarch64-static) ;;
        armv7) rust_target=armv7-unknown-linux-musleabihf; runner=(qemu-arm-static) ;;
        *) echo "不支持的架构：$arch" >&2; return 1 ;;
    esac
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/vnt-openwrt/target}"
    export CARGO_PROFILE_RELEASE_OPT_LEVEL=s
    export CARGO_PROFILE_RELEASE_LTO=thin
    export CARGO_PROFILE_RELEASE_STRIP=symbols
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
    export CARGO_PROFILE_RELEASE_PANIC=abort
    for build_command in cargo rustup python3; do
        command -v "$build_command" >/dev/null || { echo "缺少命令：$build_command" >&2; return 1; }
    done
    if [[ "$arch" != x86_64 ]]; then
        command -v zig >/dev/null && command -v "${runner[0]}" >/dev/null || {
            echo 'ARM 构建需要 Zig、cargo-zigbuild 和 qemu-user-static' >&2; return 1;
        }
    fi
    # 多个构建可以并行，但 rustup 同时安装相同组件会竞争下载文件。
    if command -v flock >/dev/null; then
        (flock 9; rustup target add "$rust_target") 9>"${TMPDIR:-/tmp}/vnt-openwrt-rustup-$UID.lock"
    else
        rustup target add "$rust_target"
    fi
    cargo fmt --manifest-path "$manifest" --check
    if [[ "$arch" == x86_64 ]]; then
        export CC_x86_64_unknown_linux_musl=musl-gcc
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc
        cargo build --manifest-path "$manifest" --locked --features "$feature" --release --target "$rust_target"
    else
        command -v zig >/dev/null || { echo '需要 Zig 和 cargo-zigbuild' >&2; return 1; }
        cargo zigbuild --manifest-path "$manifest" --locked --features "$feature" --release --target "$rust_target"
    fi
    binary="$CARGO_TARGET_DIR/$rust_target/release/$binary_name"
    "${runner[@]}" "$binary" --help >/dev/null
}

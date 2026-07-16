#!/usr/bin/env bash

set -euo pipefail

PAGE_SIZE_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }${PAGE_SIZE_RUSTFLAGS}"

#
# Fix OpenSSL build with Android NDK clang on 32-bit architectures
#

export CFLAGS="-DBROKEN_CLANG_ATOMICS"
export CXXFLAGS="-DBROKEN_CLANG_ATOMICS"

cargo ndk --platform 21 --target i686-linux-android build --release --features flutter

#!/usr/bin/env bash
set -euo pipefail

PAGE_SIZE_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }${PAGE_SIZE_RUSTFLAGS}"

cargo ndk --platform 21 --target armv7-linux-androideabi build --release --features flutter,hwcodec

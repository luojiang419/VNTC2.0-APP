#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_SRC_DIR="$PROJECT_DIR/vntcrustdesk-src"
RUNTIME_DIST_DIR="$PROJECT_DIR/third_party/vntcrustdesk/macos/dist"
RUNTIME_APP_NAME="VNTC RustDesk.app"
RUNTIME_SOURCE_APP="$RUNTIME_SRC_DIR/flutter/build/macos/Build/Products/Release/VNTC RustDesk.app"
RUNTIME_TARGET_APP="$RUNTIME_DIST_DIR/$RUNTIME_APP_NAME"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-16.2.0.app/Contents/Developer}"
VCPKG_ROOT="${VCPKG_ROOT:-$HOME/.cache/vntc-vcpkg}"
BUILD_TOOLS_DIR="${VNTC_BUILD_TOOLS_DIR:-$HOME/.cache/vntc-build-tools}"
NASM_VERSION="${NASM_VERSION:-2.16.03}"
FRB_CODEGEN="$HOME/.cargo/bin/flutter_rust_bridge_codegen"
COCOAPODS_VERSION="${COCOAPODS_VERSION:-1.15.2}"

export DEVELOPER_DIR

if [ ! -d "$RUNTIME_SRC_DIR" ]; then
  echo "vntcrustdesk source directory missing: $RUNTIME_SRC_DIR" >&2
  exit 1
fi

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "Xcode developer dir missing: $DEVELOPER_DIR" >&2
  exit 1
fi

ensure_nasm() {
  if command -v nasm >/dev/null 2>&1; then
    return
  fi

  local nasm_prefix="$BUILD_TOOLS_DIR/nasm-$NASM_VERSION"
  local nasm_bin="$nasm_prefix/bin/nasm"
  if [ ! -x "$nasm_bin" ]; then
    local src_dir="$BUILD_TOOLS_DIR/src"
    local archive="$src_dir/nasm-$NASM_VERSION.tar.xz"
    mkdir -p "$src_dir"

    if [ ! -f "$archive" ]; then
      echo "[INFO] downloading nasm $NASM_VERSION"
      curl -L --fail --retry 3 \
        -o "$archive" \
        "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VERSION/nasm-$NASM_VERSION.tar.xz"
    fi

    rm -rf "$src_dir/nasm-$NASM_VERSION"
    tar -xf "$archive" -C "$src_dir"
    (
      cd "$src_dir/nasm-$NASM_VERSION"
      ./configure --prefix="$nasm_prefix"
      make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
      make install
    )
  fi

  export PATH="$nasm_prefix/bin:$PATH"
  if ! command -v nasm >/dev/null 2>&1; then
    echo "nasm is required but could not be prepared" >&2
    exit 1
  fi
}

ensure_pkg_config() {
  if command -v pkg-config >/dev/null 2>&1; then
    return
  fi

  local pkgconf_root="$BUILD_TOOLS_DIR/pkgconf-vcpkg"
  local pkgconf_bin="$pkgconf_root/tools/pkgconf/pkgconf"
  if [ ! -x "$pkgconf_bin" ]; then
    echo "[INFO] preparing pkg-config via vcpkg pkgconf"
    (
      cd "$VCPKG_ROOT"
      "$VCPKG_ROOT/vcpkg" install pkgconf:x64-osx --x-install-root="$VCPKG_ROOT/installed"
    )

    local installed_root="$VCPKG_ROOT/installed/x64-osx"
    local installed_pkgconf="$installed_root/tools/pkgconf/pkgconf"
    if [ ! -x "$installed_pkgconf" ]; then
      echo "vcpkg pkgconf executable missing: $installed_pkgconf" >&2
      exit 1
    fi

    rm -rf "$pkgconf_root"
    mkdir -p "$pkgconf_root/tools/pkgconf" "$pkgconf_root/lib"
    cp -p "$installed_pkgconf" "$pkgconf_root/tools/pkgconf/pkgconf"
    for lib in "$installed_root/lib"/libpkgconf*; do
      [ -e "$lib" ] || continue
      cp -p "$lib" "$pkgconf_root/lib/"
    done
    ln -sf pkgconf "$pkgconf_root/tools/pkgconf/pkg-config"
  fi

  export PATH="$pkgconf_root/tools/pkgconf:$PATH"

  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required but could not be prepared" >&2
    exit 1
  fi

  pkg-config --version >/dev/null
}

prepare_vcpkg() {
  if [ ! -d "$VCPKG_ROOT/.git" ]; then
    rm -rf "$VCPKG_ROOT"
    git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
  fi

  if [ ! -x "$VCPKG_ROOT/vcpkg" ]; then
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
  fi

  export VCPKG_ROOT
  export VCPKG_DISABLE_METRICS=1

  ensure_pkg_config

  echo "[INFO] preparing vcpkg dependencies from $RUNTIME_SRC_DIR/vcpkg.json"
  "$VCPKG_ROOT/vcpkg" install --x-install-root="$VCPKG_ROOT/installed"
}

ensure_flutter_rust_bridge_codegen() {
  if [ ! -x "$FRB_CODEGEN" ] || ! "$FRB_CODEGEN" --version 2>/dev/null | grep -q "1.80.1"; then
    cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid
  fi
}

generate_flutter_bridge() {
  if [ "${VNTC_FORCE_FRB_GENERATE:-0}" != "1" ] \
    && [ -f "$RUNTIME_SRC_DIR/src/bridge_generated.rs" ] \
    && [ -f "$RUNTIME_SRC_DIR/flutter/lib/generated_bridge.dart" ] \
    && [ -f "$RUNTIME_SRC_DIR/flutter/macos/Runner/bridge_generated.h" ]; then
    echo "[INFO] using existing flutter_rust_bridge generated files"
    return
  fi

  ensure_flutter_rust_bridge_codegen
  (
    cd "$RUNTIME_SRC_DIR/flutter"
    flutter pub get
  )
  RUST_LOG=info "$FRB_CODEGEN" \
    --rust-input ./src/flutter_ffi.rs \
    --dart-output ./flutter/lib/generated_bridge.dart \
    --c-output ./flutter/macos/Runner/bridge_generated.h

  if [ -d "$RUNTIME_SRC_DIR/flutter/ios/Runner" ]; then
    cp "$RUNTIME_SRC_DIR/flutter/macos/Runner/bridge_generated.h" \
      "$RUNTIME_SRC_DIR/flutter/ios/Runner/bridge_generated.h"
  fi
}

configure_macos_arch() {
  if [ "$(uname -m)" = "x86_64" ]; then
    export ARCHS=x86_64
    export ONLY_ACTIVE_ARCH=YES
    export EXCLUDED_ARCHS=arm64
  fi
}

ensure_cocoapods() {
  local gem_user_bin
  gem_user_bin="$(ruby -rrubygems -e 'print File.join(Gem.user_dir, "bin")')"
  export PATH="$gem_user_bin:$PATH"
  case "${LANG:-}" in
    "" | C | C.UTF-8)
      export LANG=en_US.UTF-8
      ;;
  esac
  case "${LC_ALL:-}" in
    "" | C | C.UTF-8)
      export LC_ALL=en_US.UTF-8
      ;;
  esac
  case " ${RUBYOPT:-} " in
    *" -rlogger "*)
      ;;
    *)
      export RUBYOPT="${RUBYOPT:+$RUBYOPT }-rlogger"
      ;;
  esac

  if ! command -v pod >/dev/null 2>&1; then
    gem install --user-install cocoapods -v "$COCOAPODS_VERSION" --no-document
  fi

  if ! command -v pod >/dev/null 2>&1 || ! pod --version >/dev/null; then
    echo "CocoaPods is required but could not be prepared" >&2
    exit 1
  fi
}

cd "$RUNTIME_SRC_DIR"
ensure_nasm
prepare_vcpkg
generate_flutter_bridge
configure_macos_arch
ensure_cocoapods
python3 build.py --flutter --screencapturekit

if [ ! -d "$RUNTIME_SOURCE_APP" ]; then
  echo "RustDesk macOS app not found after build: $RUNTIME_SOURCE_APP" >&2
  exit 1
fi

rm -rf "$RUNTIME_TARGET_APP"
mkdir -p "$RUNTIME_DIST_DIR"
ditto "$RUNTIME_SOURCE_APP" "$RUNTIME_TARGET_APP"

VERSION="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$RUNTIME_SRC_DIR/Cargo.toml" | head -n 1)"
if [ -z "$VERSION" ]; then
  VERSION="unknown"
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$RUNTIME_TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$EXECUTABLE_NAME" ]; then
  if [ -f "$RUNTIME_TARGET_APP/Contents/MacOS/vntcrustdesk" ]; then
    EXECUTABLE_NAME="vntcrustdesk"
  elif [ -f "$RUNTIME_TARGET_APP/Contents/MacOS/rustdesk" ]; then
    EXECUTABLE_NAME="rustdesk"
  else
    EXECUTABLE_NAME="RustDesk"
  fi
fi

cat > "$RUNTIME_DIST_DIR/vntcrustdesk.version.json" <<JSON
{
  "platform": "macos",
  "version": "$VERSION",
  "appBundleName": "$RUNTIME_APP_NAME",
  "executableName": "$EXECUTABLE_NAME",
  "sourceDirectory": "$RUNTIME_SRC_DIR",
  "copiedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON

echo "[OK] macOS remote assist runtime: $RUNTIME_TARGET_APP"
echo "[OK] version metadata: $RUNTIME_DIST_DIR/vntcrustdesk.version.json"

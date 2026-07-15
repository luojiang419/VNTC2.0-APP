#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-16.2.0.app/Contents/Developer}"
RUNTIME_DIST_APP="$PROJECT_DIR/third_party/vntcrustdesk/macos/dist/VNTC RustDesk.app"
MAIN_BUILD_APP="$PROJECT_DIR/build/macos/Build/Products/Release/vnt_app.app"
DIST_DIR="$PROJECT_DIR/dist"
DIST_APP="$DIST_DIR/vnt_app.app"
REMOTE_ASSIST_RESOURCE_DIR="$DIST_APP/Contents/Resources/remote_assist"
COCOAPODS_VERSION="${COCOAPODS_VERSION:-1.15.2}"
CREATE_DMG=0
REBUILD_RUNTIME=0
VERSION_FILE="$PROJECT_DIR/scripts/build_version.txt"
VERSION_OVERRIDE=""
BUILD_NUMBER_OVERRIDE=""
OFFICIAL_SIGNING_REQUIRED="${VNT_REQUIRE_OFFICIAL_SIGNING:-0}"
MACOS_SIGN_P12_BASE64="${VNT_MACOS_SIGN_P12_BASE64:-}"
MACOS_SIGN_P12_PASSWORD="${VNT_MACOS_SIGN_P12_PASSWORD_PLAIN:-}"
MACOS_SIGN_IDENTITY="${VNT_MACOS_SIGN_IDENTITY:-}"
MACOS_NOTARY_APPLE_ID="${VNT_MACOS_NOTARY_APPLE_ID:-}"
MACOS_NOTARY_TEAM_ID="${VNT_MACOS_NOTARY_TEAM_ID:-}"
MACOS_NOTARY_APP_PASSWORD="${VNT_MACOS_NOTARY_APP_PASSWORD:-}"
MACOS_SIGN_TEMP_DIR=""
MACOS_SIGN_KEYCHAIN_PATH=""
MACOS_SIGN_KEYCHAIN_PASSWORD=""
MACOS_SIGN_KEYCHAIN_READY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dmg)
      CREATE_DMG=1
      ;;
    --rebuild-runtime)
      REBUILD_RUNTIME=1
      ;;
    --version)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Missing value for --version" >&2
        exit 1
      fi
      VERSION_OVERRIDE="$1"
      ;;
    --version=*)
      VERSION_OVERRIDE="${1#*=}"
      ;;
    --build-number)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Missing value for --build-number" >&2
        exit 1
      fi
      BUILD_NUMBER_OVERRIDE="$1"
      ;;
    --build-number=*)
      BUILD_NUMBER_OVERRIDE="${1#*=}"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

export DEVELOPER_DIR

if [ -n "$VERSION_OVERRIDE" ]; then
  PACKAGE_VERSION="$VERSION_OVERRIDE"
elif [ -n "${VNT_BUILD_VERSION:-}" ]; then
  PACKAGE_VERSION="$VNT_BUILD_VERSION"
else
  PACKAGE_VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
fi

if [ -z "$PACKAGE_VERSION" ]; then
  echo "Build version is empty" >&2
  exit 1
fi

if [ -n "$BUILD_NUMBER_OVERRIDE" ]; then
  PACKAGE_BUILD_NUMBER="$BUILD_NUMBER_OVERRIDE"
elif [ -n "${VNT_BUILD_NUMBER:-}" ]; then
  PACKAGE_BUILD_NUMBER="$VNT_BUILD_NUMBER"
else
  PACKAGE_BUILD_NUMBER=""
fi

cleanup_macos_signing() {
  if [ -n "$MACOS_SIGN_KEYCHAIN_PATH" ] && [ -f "$MACOS_SIGN_KEYCHAIN_PATH" ]; then
    security delete-keychain "$MACOS_SIGN_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  if [ -n "$MACOS_SIGN_TEMP_DIR" ] && [ -d "$MACOS_SIGN_TEMP_DIR" ]; then
    rm -rf "$MACOS_SIGN_TEMP_DIR"
  fi
}

trap cleanup_macos_signing EXIT

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_required_signing_value() {
  local value="$1"
  local label="$2"
  if [ -z "$value" ]; then
    echo "Missing required macOS signing value: $label" >&2
    exit 1
  fi
}

setup_macos_signing() {
  if [ -z "$MACOS_SIGN_P12_BASE64" ]; then
    if is_truthy "$OFFICIAL_SIGNING_REQUIRED"; then
      echo "Missing VNT_MACOS_SIGN_P12_BASE64; refusing to publish unsigned macOS release." >&2
      exit 1
    fi
    return 1
  fi

  ensure_required_signing_value "$MACOS_SIGN_P12_PASSWORD" "VNT_MACOS_SIGN_P12_PASSWORD_PLAIN"
  ensure_required_signing_value "$MACOS_SIGN_IDENTITY" "VNT_MACOS_SIGN_IDENTITY"

  MACOS_SIGN_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vnt_macos_sign.XXXXXX")"
  MACOS_SIGN_KEYCHAIN_PATH="$MACOS_SIGN_TEMP_DIR/vnt-release-signing.keychain-db"
  MACOS_SIGN_KEYCHAIN_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
)"
  local cert_path="$MACOS_SIGN_TEMP_DIR/signing-cert.p12"

  python3 - "$cert_path" <<'PY'
import base64
import os
import sys

raw = os.environ["VNT_MACOS_SIGN_P12_BASE64"]
normalized = "".join(raw.strip().split())
Path = __import__("pathlib").Path
Path(sys.argv[1]).write_bytes(base64.b64decode(normalized))
PY

  security create-keychain -p "$MACOS_SIGN_KEYCHAIN_PASSWORD" "$MACOS_SIGN_KEYCHAIN_PATH"
  security set-keychain-settings -lut 21600 "$MACOS_SIGN_KEYCHAIN_PATH"
  security unlock-keychain -p "$MACOS_SIGN_KEYCHAIN_PASSWORD" "$MACOS_SIGN_KEYCHAIN_PATH"
  security import "$cert_path" \
    -k "$MACOS_SIGN_KEYCHAIN_PATH" \
    -P "$MACOS_SIGN_P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild \
    -T /usr/bin/xcrun
  security set-key-partition-list -S apple-tool:,apple: -s -k "$MACOS_SIGN_KEYCHAIN_PASSWORD" "$MACOS_SIGN_KEYCHAIN_PATH" >/dev/null

  if ! security find-identity -v "$MACOS_SIGN_KEYCHAIN_PATH" | grep -F "$MACOS_SIGN_IDENTITY" >/dev/null; then
    echo "Configured macOS signing identity not found in imported keychain: $MACOS_SIGN_IDENTITY" >&2
    exit 1
  fi

  MACOS_SIGN_KEYCHAIN_READY=1
  return 0
}

sign_macos_bundle() {
  local bundle_path="$1"
  if [ "$MACOS_SIGN_KEYCHAIN_READY" -eq 1 ]; then
    codesign --force --deep --options runtime --timestamp --keychain "$MACOS_SIGN_KEYCHAIN_PATH" --sign "$MACOS_SIGN_IDENTITY" "$bundle_path"
  else
    codesign --force --deep --sign - "$bundle_path"
  fi
  codesign --verify --deep --strict --verbose=2 "$bundle_path"
}

sign_and_notarize_macos_dmg() {
  local dmg_path="$1"

  if [ "$MACOS_SIGN_KEYCHAIN_READY" -ne 1 ]; then
    if is_truthy "$OFFICIAL_SIGNING_REQUIRED"; then
      echo "Official macOS signing is required before DMG notarization." >&2
      exit 1
    fi
    return 0
  fi

  codesign --force --timestamp --keychain "$MACOS_SIGN_KEYCHAIN_PATH" --sign "$MACOS_SIGN_IDENTITY" "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
  if [ -z "$MACOS_NOTARY_APPLE_ID" ] || [ -z "$MACOS_NOTARY_TEAM_ID" ] || [ -z "$MACOS_NOTARY_APP_PASSWORD" ]; then
    if is_truthy "$OFFICIAL_SIGNING_REQUIRED"; then
      echo "Missing macOS notarization credentials; refusing to publish signed-but-unnotarized DMG." >&2
      exit 1
    fi
    echo "[WARN] macOS DMG already signed, but notarization credentials are missing; skipped notarization." >&2
    return 0
  fi

  xcrun notarytool submit "$dmg_path" \
    --apple-id "$MACOS_NOTARY_APPLE_ID" \
    --team-id "$MACOS_NOTARY_TEAM_ID" \
    --password "$MACOS_NOTARY_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$dmg_path"
}

configure_macos_build_env() {
  if [ "$(uname -m)" = "x86_64" ]; then
    export ARCHS=x86_64
    export ONLY_ACTIVE_ARCH=YES
    export EXCLUDED_ARCHS=arm64
  fi

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
}

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "Xcode developer dir missing: $DEVELOPER_DIR" >&2
  exit 1
fi

configure_macos_build_env
setup_macos_signing || true

if [ "$REBUILD_RUNTIME" -eq 1 ] || [ ! -d "$RUNTIME_DIST_APP" ]; then
  "$PROJECT_DIR/scripts/build_macos_remote_assist.sh"
fi

if [ ! -d "$RUNTIME_DIST_APP" ]; then
  echo "macOS remote assist runtime missing: $RUNTIME_DIST_APP" >&2
  exit 1
fi

cd "$PROJECT_DIR"
flutter pub get
build_args=(
  build
  macos
  --release
  --build-name "$PACKAGE_VERSION"
  "--dart-define=APP_BASE_TITLE=VNTC APP2.0"
  "--dart-define=APP_BUILD_VERSION=$PACKAGE_VERSION"
  "--dart-define=APP_DISPLAY_VERSION=v$PACKAGE_VERSION"
  "--dart-define=APP_PRODUCT_NAME=VNTC APP2.0"
  "--dart-define=APP_WINDOW_TITLE=VNTC APP2.0 v$PACKAGE_VERSION"
)
if [ -n "$PACKAGE_BUILD_NUMBER" ]; then
  build_args+=(--build-number "$PACKAGE_BUILD_NUMBER")
fi
flutter "${build_args[@]}"

if [ ! -d "$MAIN_BUILD_APP" ]; then
  echo "main macOS app missing after build: $MAIN_BUILD_APP" >&2
  exit 1
fi

rm -rf "$DIST_APP"
mkdir -p "$DIST_DIR"
ditto "$MAIN_BUILD_APP" "$DIST_APP"

rm -rf "$REMOTE_ASSIST_RESOURCE_DIR"
mkdir -p "$REMOTE_ASSIST_RESOURCE_DIR"
ditto "$RUNTIME_DIST_APP" "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"

RUNTIME_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$RUNTIME_EXECUTABLE_NAME" ]; then
  if [ -f "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app/Contents/MacOS/vntcrustdesk" ]; then
    RUNTIME_EXECUTABLE_NAME="vntcrustdesk"
  elif [ -f "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app/Contents/MacOS/rustdesk" ]; then
    RUNTIME_EXECUTABLE_NAME="rustdesk"
  else
    RUNTIME_EXECUTABLE_NAME="RustDesk"
  fi
fi
RUNTIME_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$RUNTIME_VERSION" ]; then
  RUNTIME_VERSION="unknown"
fi

cat > "$REMOTE_ASSIST_RESOURCE_DIR/vntcrustdesk_manifest.json" <<JSON
{
  "platform": "macos",
  "managedBy": "VNT App 2.0",
  "appBundleName": "VNTC RustDesk.app",
  "appBundleRelativePath": "remote_assist/VNTC RustDesk.app",
  "executableName": "$RUNTIME_EXECUTABLE_NAME",
  "executableRelativePath": "remote_assist/VNTC RustDesk.app/Contents/MacOS/$RUNTIME_EXECUTABLE_NAME",
  "version": "$RUNTIME_VERSION",
  "directAccessPort": 49999,
  "createdAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON

sign_macos_bundle "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"
sign_macos_bundle "$DIST_APP"

if [ "$CREATE_DMG" -eq 1 ]; then
  DMG_PATH="$DIST_DIR/VNT_App_${PACKAGE_VERSION}_macOS.dmg"
  DMG_SHA_PATH="$DMG_PATH.sha256"
  DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vnt_macos_dmg.XXXXXX")"
  ditto "$DIST_APP" "$DMG_STAGE/vnt_app.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  if [ -f "$PROJECT_DIR/macos/安装说明.html" ]; then
    cp "$PROJECT_DIR/macos/安装说明.html" "$DMG_STAGE/"
  fi
  rm -f "$DMG_PATH"
  hdiutil create -volname "VNT App" -fs HFS+ -srcfolder "$DMG_STAGE" -format UDBZ "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
  sign_and_notarize_macos_dmg "$DMG_PATH"
  DMG_HASH="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  printf '%s  %s\n' "$DMG_HASH" "$(basename "$DMG_PATH")" > "$DMG_SHA_PATH"
  rm -rf "$DMG_STAGE"
  echo "[OK] DMG: $DMG_PATH"
  echo "[OK] DMG SHA256: $DMG_SHA_PATH"
fi

echo "[OK] dist app: $DIST_APP"
echo "[OK] bundled runtime: $REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"
echo "[OK] manifest: $REMOTE_ASSIST_RESOURCE_DIR/vntcrustdesk_manifest.json"

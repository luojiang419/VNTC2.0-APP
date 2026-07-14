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

for arg in "$@"; do
  case "$arg" in
    --dmg)
      CREATE_DMG=1
      ;;
    --rebuild-runtime)
      REBUILD_RUNTIME=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

export DEVELOPER_DIR

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

if [ "$REBUILD_RUNTIME" -eq 1 ] || [ ! -d "$RUNTIME_DIST_APP" ]; then
  "$PROJECT_DIR/scripts/build_macos_remote_assist.sh"
fi

if [ ! -d "$RUNTIME_DIST_APP" ]; then
  echo "macOS remote assist runtime missing: $RUNTIME_DIST_APP" >&2
  exit 1
fi

cd "$PROJECT_DIR"
flutter build macos --release

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

codesign --force --deep --sign - "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"
codesign --verify --deep --strict --verbose=2 "$REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"
codesign --force --deep --sign - "$DIST_APP"
codesign --verify --deep --strict --verbose=2 "$DIST_APP"

if [ "$CREATE_DMG" -eq 1 ]; then
  DMG_PATH="$DIST_DIR/VNT_App_4.8.16_macOS.dmg"
  DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vnt_macos_dmg.XXXXXX")"
  trap 'rm -rf "$DMG_STAGE"' EXIT
  ditto "$DIST_APP" "$DMG_STAGE/vnt_app.app"
  ln -s /Applications "$DMG_STAGE/Applications"
  if [ -f "$PROJECT_DIR/macos/安装说明.html" ]; then
    cp "$PROJECT_DIR/macos/安装说明.html" "$DMG_STAGE/"
  fi
  rm -f "$DMG_PATH"
  hdiutil create -volname "VNT App" -fs HFS+ -srcfolder "$DMG_STAGE" -format UDBZ "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
  echo "[OK] DMG: $DMG_PATH"
fi

echo "[OK] dist app: $DIST_APP"
echo "[OK] bundled runtime: $REMOTE_ASSIST_RESOURCE_DIR/VNTC RustDesk.app"
echo "[OK] manifest: $REMOTE_ASSIST_RESOURCE_DIR/vntcrustdesk_manifest.json"

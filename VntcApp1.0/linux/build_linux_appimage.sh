#!/bin/bash
set -e

BUNDLE=$1
APPIMAGE_ARCH=$2
APP_RELEASE_VERSION="${APP_RELEASE_VERSION:-$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)}"
APP_RELEASE_BUILD_NUMBER="${APP_RELEASE_BUILD_NUMBER:-1}"
APP_RELEASE_DISPLAY_VERSION="${APP_RELEASE_DISPLAY_VERSION:-v$APP_RELEASE_VERSION}"

step() { echo -e "\n\033[1;36m>>> $1\033[0m\n"; }

step "安装系统依赖"
apt-get update -q
apt-get install -y --no-install-recommends --no-install-suggests \
  curl git cmake ninja-build pkg-config clang \
  libgtk-3-dev libblkid-dev liblzma-dev \
  libappindicator3-dev libkeybinder-3.0-dev \
  libsecret-1-dev libjsoncpp-dev \
  ca-certificates wget file xz-utils unzip || {
    echo "部分包安装失败，尝试修复..."
    apt-get install -f -y
  }

step "安装 Flutter 3.24.5"
git clone --depth 1 --branch 3.24.5 \
  https://github.com/flutter/flutter.git /opt/flutter
export PATH="/opt/flutter/bin:$PATH"
flutter precache --linux
flutter --version

RUST_VERSION="${RUST_VERSION:-1.88.0}"
step "安装 Rust ${RUST_VERSION}（强制固定，禁止升级）"
export CARGO_HOME=/opt/cargo
export RUSTUP_HOME=/opt/rustup
export PATH="/opt/cargo/bin:$PATH"
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | \
  sh -s -- -y --default-toolchain "${RUST_VERSION}" --no-modify-path \
    --no-update-default-toolchain
rustup set auto-self-update disable
rustup default "${RUST_VERSION}"
rustc -V

step "构建 Flutter Linux Release"
flutter config --no-analytics
flutter pub get
flutter build linux --release -v \
  --build-name "$APP_RELEASE_VERSION" \
  --build-number "$APP_RELEASE_BUILD_NUMBER" \
  --dart-define=APP_BASE_TITLE="VNTC APP2.0" \
  --dart-define=APP_BUILD_VERSION="$APP_RELEASE_VERSION" \
  --dart-define=APP_DISPLAY_VERSION="$APP_RELEASE_DISPLAY_VERSION" \
  --dart-define=APP_PRODUCT_NAME="VNTC APP2.0" \
  --dart-define=APP_WINDOW_TITLE="VNTC APP2.0 $APP_RELEASE_DISPLAY_VERSION"

step "下载并解压 appimagetool"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"
echo "下载: $APPIMAGETOOL_URL"
wget -q -O appimagetool.AppImage "$APPIMAGETOOL_URL"
chmod +x appimagetool.AppImage
./appimagetool.AppImage --appimage-extract
mv squashfs-root appimagetool-extracted

step "构建 AppDir"
mkdir -p AppDir/usr/share/icons/hicolor/256x256/apps
cp -r ${BUNDLE}/. AppDir/
cp assets/app_icon.png AppDir/vnt_app.png
cp assets/app_icon.png AppDir/usr/share/icons/hicolor/256x256/apps/vnt_app.png

cat > AppDir/vnt_app.desktop << EOF
[Desktop Entry]
Name=VNT App
Exec=vnt_app
Icon=vnt_app
Type=Application
Categories=Network;
EOF

cat > AppDir/AppRun << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"

if [ "$(id -u)" -ne 0 ]; then
    SELF="${APPIMAGE:-$(readlink -f "$0")}"

    exec pkexec /bin/bash -c '
        export DISPLAY="'"$DISPLAY"'"
        export XAUTHORITY="'"$XAUTHORITY"'"
        export DBUS_SESSION_BUS_ADDRESS="'"$DBUS_SESSION_BUS_ADDRESS"'"
        export XDG_RUNTIME_DIR="'"$XDG_RUNTIME_DIR"'"
        export WAYLAND_DISPLAY="'"$WAYLAND_DISPLAY"'"
        exec "'"$SELF"'" "$@"
    ' bash "$@"
fi

exec "$HERE/vnt_app" "$@"
EOF
chmod +x AppDir/AppRun

step "打包 AppImage（arch=${APPIMAGE_ARCH}）"
ARCH=${APPIMAGE_ARCH} ./appimagetool-extracted/AppRun AppDir \
  vntApp-linux-${APPIMAGE_ARCH}.AppImage

step "完成 ✓ vntApp-linux-${APPIMAGE_ARCH}.AppImage"

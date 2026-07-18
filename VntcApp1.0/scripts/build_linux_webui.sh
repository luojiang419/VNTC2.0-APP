#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
crate_dir="$project_dir/linux_webui"
version_file="$script_dir/build_version.txt"
release_root="$project_dir/release/linux_webui"
advance_version=true
version_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-advance)
      advance_version=false
      shift
      ;;
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version 后必须提供版本号" >&2
        exit 1
      fi
      version_override="$2"
      shift 2
      ;;
    *)
      echo "用法：scripts/build_linux_webui.sh [--version X.Y.Z] [--no-advance]" >&2
      exit 1
      ;;
  esac
done

version="${version_override:-$(tr -d '[:space:]' < "$version_file")}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "无效构建版本：$version" >&2
  exit 1
fi

arch="$(uname -m)"
if [[ "$arch" != "x86_64" ]]; then
  echo "当前发布脚本仅支持 x86_64，检测到：$arch" >&2
  exit 1
fi

package_base="VNTC_Linux_WebUI_${version}_ubuntu24.04_x86_64"
archive_path="$release_root/$package_base.tar.gz"
archive_hash_path="$archive_path.sha256"
published_stage="$release_root/$package_base"
work_dir="$(mktemp -d)"
stage_dir="$work_dir/$package_base"

cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$release_root"
release_root_real="$(realpath "$release_root")"
published_stage_real="$(realpath -m "$published_stage")"
if [[ "$published_stage_real" != "$release_root_real"/* ]]; then
  echo "拒绝清理发布目录外的路径：$published_stage_real" >&2
  exit 1
fi
rm -rf -- "$published_stage"
rm -f -- "$archive_path" "$archive_hash_path"

echo "[1/7] 检查格式"
cargo fmt --manifest-path "$crate_dir/Cargo.toml" --check

echo "[2/7] 运行 Rust 与 WebUI 测试"
VNTC_APP_VERSION="$version" cargo test --manifest-path "$crate_dir/Cargo.toml" --locked --all-targets
node --test "$crate_dir"/tests/*.test.mjs

echo "[3/7] 编译 Release"
build_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
VNTC_APP_VERSION="$version" VNTC_BUILD_TIME="$build_time" cargo build --manifest-path "$crate_dir/Cargo.toml" --release --locked

echo "[4/7] 组装分发目录"
install -d -m 0755 "$stage_dir"
install -m 0755 "$crate_dir/target/release/vntc-linux-webui" "$stage_dir/vntc-linux-webui"
install -m 0755 "$crate_dir/install.sh" "$stage_dir/install.sh"
install -m 0755 "$crate_dir/uninstall.sh" "$stage_dir/uninstall.sh"
install -m 0644 "$crate_dir/systemd/vntc-linux-webui.service" "$stage_dir/vntc-linux-webui.service"
install -m 0644 "$crate_dir/config.example.json" "$stage_dir/config.example.json"
install -m 0644 "$crate_dir/README.md" "$stage_dir/README.md"
install -m 0644 "$project_dir/LICENSE" "$stage_dir/LICENSE"
printf '%s\n' "$version" > "$stage_dir/VERSION"

echo "[5/7] 校验二进制与安装包内容"
"$stage_dir/vntc-linux-webui" --help | grep -F "vntc-linux-webui $version" >/dev/null
"$stage_dir/vntc-linux-webui" --config "$stage_dir/config.example.json" --check-config >/dev/null
bash -n "$stage_dir/install.sh" "$stage_dir/uninstall.sh"
verify_dir="$(mktemp -d)"
install -m 0755 "$stage_dir/vntc-linux-webui" "$verify_dir/vntc-linux-webui"
sed "s#^ExecStart=.*#ExecStart=$verify_dir/vntc-linux-webui --config $stage_dir/config.example.json#" \
  "$stage_dir/vntc-linux-webui.service" > "$verify_dir/vntc-linux-webui.service"
chmod 0644 "$verify_dir/vntc-linux-webui.service"
if ! systemd-analyze verify "$verify_dir/vntc-linux-webui.service"; then
  rm -rf -- "$verify_dir"
  exit 1
fi
rm -rf -- "$verify_dir"
ldd "$stage_dir/vntc-linux-webui" | tee "$stage_dir/LINKED_LIBRARIES.txt"
if grep -q "not found" "$stage_dir/LINKED_LIBRARIES.txt"; then
  echo "Release 二进制存在缺失动态库" >&2
  exit 1
fi

(
  cd "$stage_dir"
  sha256sum vntc-linux-webui install.sh uninstall.sh \
    vntc-linux-webui.service config.example.json README.md LICENSE VERSION \
    LINKED_LIBRARIES.txt > SHA256SUMS
)

echo "[6/7] 生成压缩包与 SHA256"
tar -C "$work_dir" -czf "$archive_path" "$package_base"
(
  cd "$release_root"
  sha256sum "$(basename "$archive_path")" > "$(basename "$archive_hash_path")"
)

if [[ "$advance_version" == true ]]; then
  IFS='.' read -r major minor patch <<< "$version"
  if [[ -n "${patch:-}" ]]; then
    next_version="$major.$minor.$((10#$patch + 1))"
  else
    next_version="$major.$((10#$minor + 1))"
  fi
  printf '%s\n' "$next_version" > "$version_file"
  echo "下一构建版本：$next_version"
fi

echo "[7/7] Linux Release 构建完成"
echo "Linux Release 构建完成：$archive_path"
cat "$archive_hash_path"

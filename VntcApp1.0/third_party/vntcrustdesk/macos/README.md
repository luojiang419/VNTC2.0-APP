# vntcrustdesk macOS 产物目录

本目录用于暂存 macOS 远程协助运行时产物，供主应用打包时内置到
`vnt_app.app/Contents/Resources/remote_assist/`。

## 期望文件

- `dist/VNTC RustDesk.app`
- `dist/vntcrustdesk.version.json`

## 推荐接入方式

1. 执行 `scripts/build_macos_remote_assist.sh`，从 `vntcrustdesk-src` 构建并暂存 macOS runtime。
2. 执行 `scripts/export_macos_package.sh`，重新编译主应用并把 runtime 内置到 `dist/vnt_app.app`。
3. 如需 DMG，执行 `scripts/export_macos_package.sh --dmg`。

## 注意

- `dist/` 下是构建产物，体积较大，不建议作为源码长期维护内容。
- 正式外发仍需要 Developer ID 签名、公证和 Gatekeeper 验证。

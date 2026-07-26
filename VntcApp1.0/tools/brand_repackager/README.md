# VNT 一键品牌换牌工具

`VNT_一键品牌换牌工具.exe` 使用同一个入口处理 Windows EXE 和 Android APK。工具读取文件真实内容自动识别格式，界面没有 EXE/APK 模式开关；即使扩展名被改错，也不会只按后缀误判。

## 用户操作

1. 运行 `VNT_一键品牌换牌工具.exe`。
2. 在“客户端安装包”位置直接选择任意新版、且声明换牌能力的 VNT `.exe` 或 `.apk`；不需要另外准备特制输入包。
3. 确认识别结果显示“Windows EXE”或“Android APK”。
4. 输入新名称，例如“联网工具”。
5. 可选添加 `.ico`、`.png`、`.jpg/.jpeg` 或 `.bmp` 新图标；不添加则保留源安装包图标。
6. “移除升级功能”默认勾选，生成包不会自动检查、显示升级入口或执行内置升级。
7. 客户分发版可勾选“隐藏‘关于’页面”；默认不勾选，开源版继续显示。
8. 点击“重新打包”，在弹出的保存窗口中保存对应的 `.exe` 或 `.apk`。

图标超过目标尺寸时会自动透明居中、等比缩放并压缩。Windows 会生成 16–256 像素多尺寸 ICO；Android 会生成 36、48、72、96、144、192 像素六档启动图标，并同步应用内 Flutter 图标。源图最大支持 64 MB、16384 像素边长且不超过约 4000 万像素。

最终工具是单个 EXE，已内置 Inno Setup、APKTool、精简 Java 17 运行时、zipalign、apksigner、中文语言文件、默认图标和 PE 资源修改器。最终用户不需要另外安装 Inno Setup、Java、Android SDK 或 APKTool。

## 两种格式的处理结果

### Windows EXE

- 同步修改窗口标题、托盘名称、主程序 EXE/进程文件名、文件描述、安装目录、快捷方式和卸载名称。
- 自定义图标同步到安装程序、主程序和运行时托盘。
- 重新生成仍带换牌能力协议的安装包，可继续二次换牌。

### Android APK

- 同步修改应用显示名、applicationId、默认进程标识、Provider authority、磁贴、小组件、通知和辅助服务名称。
- 自定义图标同步到 Android 六档启动图标和应用内图标。
- APK 使用内置工具完成重建、16 KiB 原生库对齐、v2/v3 签名和成品复检。
- 同一台电脑、同一 Windows 用户使用完全相同的新名称再次封装时，会强制复用 applicationId 和签名证书，可覆盖安装。
- 改变新名称会生成新的 applicationId，Android 会将其视为另一个独立应用，不会覆盖原品牌应用。

Android 品牌签名档案保存在：

```text
%LOCALAPPDATA%\VNTBrandRepackager\android-signing
```

密码使用当前 Windows 用户的 DPAPI 加密，不会明文保存。此目录是该品牌后续覆盖升级的签名身份，应保留原打包电脑和原 Windows 用户环境。当前版本不提供跨用户/跨电脑的便携密钥导出；仅复制该目录不能在另一个 Windows 用户下解密。删除档案、切换 Windows 用户或换电脑后，工具不会用新密钥冒充旧品牌，已换牌 APK 的后续覆盖封装会被拒绝。

## 来源信任

Windows 客户端不再按版本维护整包 SHA-256 白名单；工具会按 PE 结构、换牌能力标记、只读快照和导出后的清单/载荷进行校验，因此同一工具可直接处理后续兼容版本。Windows 输入安装包会以换牌导出参数运行，所以仍只应选择自己构建或来自可信渠道的客户端。Android 官方客户端必须匹配专用发布证书；已换牌 APK 必须同时匹配其本机品牌档案、applicationId 和实际证书。重新签名 APK 或复制伪造的品牌 JSON 会被拒绝。

Android 4.8.20+ 兼容客户端使用独立官方发布证书，公开证书 SHA-256 为 `83EF92B147643697EA8EFAF4B73A9D370875EE0FD1CBA10A7AC03E184F44D8C7`。最终工具只嵌入此公开指纹，不包含官方私钥、密钥密码或 DPAPI 档案。官方私钥仅保存在构建机的 `%LOCALAPPDATA%\VNTBrandRepackager\android-official-signing\v1`，必须由项目维护者离线保护。

## 支持范围与限制

- 直接支持本项目生成、且声明对应换牌能力的任意新版 VNT 客户端，以及本工具生成的品牌包；不是任意第三方 EXE/APK 通用修改器。
- Windows：v4.8.17+ 支持基础换牌；隐藏关于要求 v4.8.18+；完整移除升级要求 v4.8.19+。
- Android：要求 v4.8.20+ 兼容客户端，并声明运行时品牌、隐藏关于、移除升级、图标和 applicationId 重写能力。
- Android 版本以二进制 `AndroidManifest.xml` 为准；若客户端内置换牌能力清单仍记录旧版本，工具会自动修正后再输出。
- 默认移除升级功能；取消勾选会恢复官方更新，可能升级到不匹配当前品牌的安装包，仅应在具备同品牌更新策略时使用。
- 换牌会改变文件哈希和原安装包签名。Windows 如需商业代码签名，应在换牌完成后签名；Android 由工具维护每个品牌的独立签名身份。
- Firebase、Google 登录、Play Integrity、应用商店许可、OAuth 回调等绑定“包名 + 证书”的第三方服务，不能由通用换牌自动重新配置。
- 隐藏“关于”只移除应用内入口和页面，不免除分发者继续携带必要开源许可证、NOTICE 或第三方声明的义务。
- 只应导入自己构建或来自可信渠道的客户端安装包。

## 自动化命令

命令行仍使用同一套参数，不需要传平台或模式：

```powershell
VNT_一键品牌换牌工具.exe --self-test --output D:\Temp\self-test
VNT_一键品牌换牌工具.exe --inspect --input D:\BasePackage.apk --output D:\Temp\inspect
VNT_一键品牌换牌工具.exe --pack --input D:\BaseSetup.exe --name 联网工具 --save D:\Output\联网工具.exe
VNT_一键品牌换牌工具.exe --pack --input D:\BasePackage.apk --name 联网工具 --icon D:\logo.png --hide-about --save D:\Output\联网工具.apk
VNT_一键品牌换牌工具.exe --pack --input D:\BasePackage.apk --name 可升级版 --remove-update false --save D:\Output\可升级版.apk
```

不传 `--remove-update` 时默认移除升级；只有显式传入 `--remove-update false` 或 `--remove-update 0` 才保留。运行日志和 SHA-256 校验文件会与输出一起生成；如显式传入 `--log`，日志文件必须使用 `.log` 扩展名，避免覆盖 EXE、APK 或校验旁车。

## 开发构建

运行 `build.ps1`。构建机需要 .NET Framework 编译器、Inno Setup 6 和固定版本 Android Build Tools 36.0.0；脚本会固定下载并校验 APKTool 3.0.2 与 Eclipse Temurin 17.0.19+10，再把全部运行组件嵌入单个 EXE。最终工具的使用者不需要这些环境。

内置第三方组件及许可证：

- Inno Setup：随官方 `license.txt` 内置。
- electron/rcedit 2.0.0：MIT License 随工具内置。
- APKTool 3.0.2：Apache License 2.0 随工具内置。
- Eclipse Temurin JRE 17.0.19+10：随精简运行时的 legal 文件内置。
- Android Build Tools：zipalign、apksigner 及对应 NOTICE 随工具内置。

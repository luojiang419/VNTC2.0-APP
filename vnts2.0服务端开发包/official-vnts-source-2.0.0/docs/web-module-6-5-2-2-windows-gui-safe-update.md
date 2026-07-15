# Web 模块 6.5.2.2：Windows GUI 安全更新已有服务

## 背景

6.5.2.1 已让 GUI 识别其他目录中的同名服务，但真实启动测试发现 `C:\ProgramData\VNTS2\vnts2.exe` 是 2026-05-09 的旧程序：4,906,496 字节，SHA-256 `E7A8DC0956BA6D39F2C0C23955D0AF22B754BE91C15B972E5864E63255B3FF83`。该程序的 CLI 不包含 Windows Service 参数，因此 SCM 无法启动它。仅“启动已有服务”不能完成升级。

## 目标

在不削弱同名服务路径保护的前提下，为 GUI 提供显式确认的安全更新：保留配置和运行数据，备份旧程序，用当前发布包 EXE 更新已有服务；失败时恢复旧程序和原 ImagePath。

## 实现

新增 `windows-deploy/update-vnts2-service.ps1`：

1. 校验管理员权限、服务名、服务存在性和可解析 ImagePath。
2. 拒绝源/目标为同一文件，拒绝缺失配置。
3. 服务运行时先正常停止。
4. 将旧 EXE 复制到 `.backups/vnts2.exe.pre-update-*.bak` 并校验 SHA-256。
5. 将新 EXE 复制到同目录临时文件并校验 SHA-256，使用 `File.Replace` 同卷替换。
6. 委托既有安装脚本规范化 ImagePath、ACL、恢复策略并启动。
7. 任一步失败时恢复旧 EXE 和原 ImagePath；原服务此前运行时尝试恢复运行。
8. 临时替换文件始终清理，正式旧程序备份保留。

GUI 对 `ExistingDeployment` 显示“更新并启动服务”。点击后先显示 Yes/No 确认框，默认按钮为 No；只有选择 Yes 才调用更新脚本。配置、数据库、密钥、日志和备份不删除。

## 发布包

`update-vnts2-service.ps1` 加入严格发布白名单。MANIFEST 从 16 个负载增加到 17 个，SHA256SUMS 覆盖 17 个负载和 MANIFEST。

## 真实验证

- 使用默认旧 EXE 的副本创建随机隔离服务，更新到最终 Release：旧、新和备份哈希全部匹配。
- 更新后服务进入 `Running`，运行端口诊断 `PASS`，真实 HTTP 返回 `200`。
- 使用 `cmd.exe` 作为无效更新源触发启动失败：旧 EXE、原 ImagePath 和 `Stopped` 状态全部恢复。
- 最终发布目录 GUI 实际识别 `ExistingDeployment`，注册配置路径为 `C:\ProgramData\VNTS2\config.toml`，动作是 `UpdateExistingService`。
- 最终 WinForms 窗口实际显示，标题正确且 `Responding=True`。
- 默认真实 `vnts2` 未自动迁移，保持 `Stopped` 和原 ImagePath；只有用户在 GUI 中明确确认才会更新。

## 质量门

- PowerShell 5.1/7：服务、GUI、发布包契约全部通过。
- `cargo fmt --all -- --check`、`cargo check --locked --all-targets`、`cargo test --locked`（86/86）、`cargo clippy --locked --all-targets -- -A clippy::never_loop` 通过。
- `cargo audit` 无漏洞，仅允许的 `spin 0.9.8` yanked 提示；`cargo deny check licenses sources` 通过。
- Release 使用 `C:\Program Files\NASM\nasm.exe`。
- ZIP 重复构建哈希一致。

## 最终产物

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `target/release/vnts2.exe` | 7,278,592 | `EA5570AFEAA99A69991A665CAECC918C9DE71F5C424ACD2A73F94AF288286942` |
| `dist/vnts2-2.0.0-windows-x64.zip` | 3,832,193 | `0E04D04FAA60CAB5F622B52BC8BAFB349CA04825F0F50E9E1BE5A99D5D9B1685` |

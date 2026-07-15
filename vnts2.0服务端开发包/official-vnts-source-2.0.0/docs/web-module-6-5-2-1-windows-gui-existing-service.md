# Web 模块 6.5.2.1：Windows GUI 已有服务路径识别修复

## 问题

用户从正式发布目录启动 `VNTS2-Manager.cmd` 后点击“一键安装并启动”，系统已有的默认服务 `vnts2` 指向 `C:\ProgramData\VNTS2`，而 GUI 将当前解压目录传给安装脚本。安装脚本为防止劫持同名服务，正确拒绝了不同 ImagePath 的覆盖，但 GUI 没有把这种状态转换为“管理已有服务”，因此显示为安装失败。

问题发生时默认服务保持 `Stopped`、`Automatic`、`LocalSystem`，ImagePath 为：

```text
"C:\ProgramData\VNTS2\vnts2.exe" --service --conf "C:\ProgramData\VNTS2\config.toml"
```

## 最小修复

安装脚本的路径保护不变，只调整 GUI 上下文：

1. `Get-Vnts2ManagerDeploymentMode` 将服务分为 `NotInstalled`、`CurrentDeployment` 和 `ExistingDeployment`。
2. 同名服务位于其他目录时，状态显示“已有部署”，安装按钮改为“启动已有服务”。点击后委托 `start-vnts2-service.ps1`，不调用安装脚本，也不改写 ImagePath。
3. 配置编辑和 Web 控制台使用 Windows 服务注册的 `ConfigPath`。服务名改变后会重新读取状态，避免沿用旧服务的配置路径。
4. 已安装服务的配置文件缺失时不会自动从当前包复制模板，防止跨部署写入。
5. `-ValidateOnly` 输出实际默认服务的部署模式、配置路径和按钮动作，便于发布包自动验收。

## 文件

- `windows-deploy/vnts2-manager.ps1`
- `windows-deploy/tests/windows-gui-manager.Tests.ps1`
- `windows-deploy/README.md`
- `windows-deploy/README-PACKAGE.md`

## 验证

- 最终发布目录直接执行 `vnts2-manager.ps1 -ValidateOnly`：识别 `ExistingDeployment`，配置路径为 `C:\ProgramData\VNTS2\config.toml`，动作是 `StartExistingService`。
- 双击入口启动真实 WinForms 进程：窗口标题正确、进程响应正常；企业桌面控制接口无法枚举 PowerShell WinForms 窗口，返回环境接口限制，因此交互语义使用真实状态模型、窗口进程和 SCM 测试交叉验证。
- 最终包随机隔离服务真实安装、幂等安装、启动、状态、端口诊断、停止、异常退出语义和卸载通过；默认 `vnts2` 状态与 ImagePath 未变化。
- 额外真实 HTTP 验收返回 `200`。
- PowerShell 5.1/7 GUI、服务和发布包契约通过。
- `cargo fmt --all -- --check`、`cargo check --locked --all-targets`、`cargo test --locked`（86/86）、`cargo clippy --locked --all-targets -- -A clippy::never_loop`、`cargo audit`、`cargo deny check licenses sources` 全部通过；仅保留既有告警和允许的 `spin 0.9.8` yanked 提示。
- Release 使用 `C:\Program Files\NASM\nasm.exe`。

## 最终产物

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `target/release/vnts2.exe` | 7,278,592 | `91EFFD6A0E18B36493471B16A4CCDB8E09BFF7CAD0FCC5894A3FBB2DC65490CE` |
| `dist/vnts2-2.0.0-windows-x64.zip` | 3,830,075 | `E80ADB209FB8F02261B775A8DF612EBD066BABA0B03FF193F8706A49775DABFE` |

重复构建 ZIP 哈希一致。

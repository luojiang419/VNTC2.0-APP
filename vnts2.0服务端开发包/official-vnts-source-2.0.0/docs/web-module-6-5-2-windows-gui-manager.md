# Web 模块 6.5.2：Windows GUI 服务管理器

## 1. 背景与目标

VNTS 2.0 已有服务启动后的内嵌 Web 管理界面，但 Windows 服务安装、配置、启停和诊断仍需要命令行脚本。为了让普通 Windows 用户快捷使用，本模块在离线 ZIP 中增加原生桌面管理器。

本模块只实现 GUI 和发布集成；从 ZIP 安装随机隔离服务的完整 SCM 端到端验收顺延为 6.5.3。

## 2. 技术选择

使用系统自带 Windows PowerShell 5.1 和 WinForms：

- Windows 10/11 无需安装额外桌面运行库；
- 可直接复用模块 6.4 已验证的 PowerShell 服务脚本；
- GUI 不复制 SCM、ACL、超时、失败恢复或诊断逻辑；
- `VNTS2-Manager.cmd` 可直接双击，并隐藏中间命令行窗口。

## 3. 用户界面

窗口标题为“VNTS 2.0 Windows 服务管理器”，提供服务名输入、状态区域、操作输出和 8 个快捷动作：

1. 初始化/编辑配置；
2. 一键安装并启动；
3. 启动服务；
4. 停止服务；
5. 运行诊断；
6. 打开 Web 控制台；
7. 卸载服务；
8. 清空输出。

状态区域展示安装状态、SCM 状态、进程 ID、运行账户、程序路径和配置路径。所有操作在窗口内显示带时间的结果或错误信息。

## 4. 权限与委托边界

GUI 启动时检查管理员身份；非管理员通过 `Start-Process -Verb RunAs` 重新启动系统 Windows PowerShell，并触发标准 UAC。用户取消 UAC 时只显示提示，不执行服务操作。

GUI 只调用以下脚本：

- `install-vnts2-service.ps1`
- `start-vnts2-service.ps1`
- `stop-vnts2-service.ps1`
- `status-vnts2-service.ps1`
- `diagnose-vnts2-service.ps1`
- `uninstall-vnts2-service.ps1`

GUI 源码不直接调用 `sc.exe`、`New-Service`、`Start-Service`、`Stop-Service` 或 `Remove-Service`，因此服务名校验、ImagePath、ACL、幂等、超时和 SCM 退出语义仍只有一份实现。

## 5. 配置与数据安全

- “初始化/编辑配置”仅在 `config.toml` 不存在时复制 `config.example.toml`。
- 已有配置永不覆盖，只用记事本打开。
- 安装前若没有 `config.toml`，GUI 明确阻止安装并引导用户先确认配置。
- 打开 Web 控制台时，通过共享脱敏解析器只读取有效 `web_bind`。
- 只允许 `127.0.0.1`、`localhost` 或 `[::1]`，并校验端口为 1–65535。
- 卸载前使用默认焦点为“否”的确认框，并明确配置、数据库、密钥和日志会保留。

## 6. GUI 契约测试

`vnts2-manager.ps1 -ValidateOnly` 跳过提权和服务查询，但实际加载 WinForms、创建完整窗口和控件，然后返回窗口模型。该模式只用于自动化验证，不显示窗口或修改系统状态。

`windows-gui-manager.Tests.ps1` 验证：

- PowerShell 语法；
- 窗口标题、默认服务名和 8 个动作顺序；
- 6 个服务脚本委托全部存在；
- UAC、配置模板和 Web 回环解析入口存在；
- GUI 不直接实现 SCM 写操作；
- 双击启动器使用 `%~dp0`、进程级 Bypass 和隐藏窗口。

Windows PowerShell 5.1 与 PowerShell 7 均实际构建窗口模型并通过。最终 ZIP 还被解压到带空格随机临时目录，包内 GUI 在两种引擎下得到完全相同模型，证明不依赖开发工作区。

## 7. 发布包集成

GUI 增加两个白名单负载：

- `VNTS2-Manager.cmd`
- `vnts2-manager.ps1`

MANIFEST 负载从 14 个增加到 16 个；加入 `MANIFEST.json` 和 `SHA256SUMS.txt` 后，ZIP 共 18 个文件。

加入较大的 GUI 脚本后，PowerShell 5.1 的 .NET Framework 与 PowerShell 7 的 .NET 10 `ZipArchive` 产生不同 ZIP 元数据/压缩字节。为避免自写 ZIP 格式，生成脚本将系统 Windows PowerShell 5.1 固定为规范 ZIP 写入器：PowerShell 7 调用时安全转义参数并委托 5.1，最终仍返回相同结果对象。这样保留压缩率，同时保证两种调用入口输出相同字节。

## 8. 最终产物

| 产物 | 字节 | SHA-256 |
| --- | ---: | --- |
| `target/release/vnts2.exe` | 7,278,592 | `FF3655D44A490232F1E85EB5333C91D891B067E5B6BE1598B50FCC1E1DAFAE19` |
| `dist/vnts2-2.0.0-windows-x64.zip` | 3,829,165 | `6ACACB56FE9B1AF6969D165A8D88C0D2378E15B524ADA25117067AC258710358` |

Release 全量重新链接后哈希变化。只读 PE 审计确认 COFF 时间戳由 `2026-07-14T12:01:41Z` 更新为 `2026-07-14T12:36:59Z`；本模块没有修改 Rust 源码。立即重复构建不重新链接，哈希保持稳定。6.5 的 ZIP 确定性定义为“同一 Release 输入生成同一 ZIP”，不宣称 MSVC Release 跨重新链接字节可重复。

## 9. 验证结果

- Windows PowerShell 5.1 WinForms：可用。
- PowerShell 7 WinForms：可用。
- PS5/PS7 服务、GUI、发布三组契约：全部通过。
- 最终 ZIP 解压后 GUI 模型：PS5/PS7 一致，8 个动作。
- PS5 连续生成、PS5/PS7 调用：同一 Release 输入下 ZIP 同哈希。
- fmt/check：通过。
- test：86/86 通过。
- clippy：既有 `never_loop` 显式允许后通过，其余为既有告警。
- cargo audit：无漏洞，仅允许的 `spin 0.9.8` yanked 提示。
- cargo deny licenses/sources：通过。
- Release：优先使用 `C:\Program Files\NASM\nasm.exe`。
- `git diff --check`：通过，仅既有 CRLF 提示。
- 新增/修改 PowerShell 文件：UTF-8 BOM。
- GUI 临时目录、包契约目录和临时服务：0。
- 默认 `vnts2` 服务保持原状态和 ImagePath。
- 旧 `windows-deploy/vnts2.exe` 与 `config.toml` 哈希未变化。
- `target`：6.363 GiB，低于 20 GiB，不清理缓存。

## 10. 下一步

模块 6.5.3 从最终 GUI ZIP 校验并解压，生成隔离测试配置，再用随机 `vnts2-package-e2e-*` 服务名完成真实安装、启动、状态、诊断、停止和卸载。默认服务必须前后不变；该阶段不进入 6.6。

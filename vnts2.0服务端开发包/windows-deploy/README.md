# VNTS 2.0 Windows 部署目录

这个目录是 Windows 版本的完整便携部署单元：程序和管理脚本位于根目录，配置、日志、数据库、密钥和备份统一位于同级 `data` 目录。

## 目录内容

- `vnts2.exe`
  - Windows 版服务端二进制
- `data/`
  - 运行数据根目录；首次通过 GUI 配置或安装时自动创建 `data/config.toml`
- `install-vnts2-service.ps1`
  - 安装并注册 Windows 服务
- `initialize-vnts2-console.ps1`
  - 增强控制台首次启动引导；仅在配置不存在时创建回环 API 配置，并幂等安装、启动同目录服务
- `start-vnts2-service.ps1`
  - 启动 Windows 服务
- `stop-vnts2-service.ps1`
  - 停止 Windows 服务
- `status-vnts2-service.ps1`
  - 查询 SCM 状态、账户、进程和启动命令
- `diagnose-vnts2-service.ps1`
  - 检查 ImagePath、文件、ACL、日志和监听端口，不输出密码、token 或密钥内容
- `uninstall-vnts2-service.ps1`
  - 卸载 Windows 服务
- `build-vnts2-windows-package.ps1`
  - 生成包含 `VNTS2-Manager.exe` 的轻量版 staging、ZIP 与 SHA-256 清单
- `build-vnts2-console-package.ps1`
  - 构建并生成包含完整 Flutter 运行库和 `VNTS2-Console.exe` 的增强版 staging、ZIP 与 SHA-256 清单
- `config.example.toml`
  - 不含有效密码、token、密钥或证书路径的发布配置模板
- `README-PACKAGE.md`
  - 轻量发布包内使用的安装与安全说明
- `README-CONSOLE-PACKAGE.md`
  - 增强发布包内使用的安装与安全说明
- `VNTS2-Manager.exe`
  - 正式发布包中的原生 C# WinForms 客户入口
- `build-vnts2-manager-exe.ps1`
  - 使用系统 .NET Framework x64 C# 编译器构建 GUI EXE
- `gui/Vnts2Manager.cs`
  - 原生窗口、状态展示、确认流程和后台服务脚本调用
- `vnts2-manager.ps1` / `VNTS2-Manager.cmd`
  - 仅保留为历史开发入口，不进入正式发布包

GUI 检测到同名服务位于其他目录时，会显示原程序/配置路径，并将主操作切换为“迁移并启动服务”。只有用户明确确认后，GUI 才会通过 `update-vnts2-service.ps1 -MigrateExistingData` 校验并备份旧文件，把运行数据迁入当前目录的 `data`，再更新服务 ImagePath；取消确认不会写入。需要并行安装时应使用未占用的独立服务名。

已安装服务的配置尚未包含 `web_bind` 时，点击“Web 控制台”会先显示确认框。确认后 GUI 仅启用 `127.0.0.1:29871`，生成 24 位强密码（已有合格凭据则保留），在配置目录的 `.backups` 中备份原配置，原子写入 TOML 根级设置并重启服务；随后显示可复制的登录信息。密码不会写入 GUI 操作日志。

## 前台调试运行

在当前目录执行：

```powershell
.\vnts2.exe --conf .\data\config.toml
```

说明：

- 进程会自动把工作目录切到 `data` 配置所在目录。
- 日志默认输出到 `.\data\logs\vnts2.log`。
- 若 `config.toml` 中启用了 `web_bind`，内置 Web 管理端也会一起启动。

## 安装为 Windows 服务

请使用管理员 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-vnts2-service.ps1
```

默认服务名为 `vnts2`，启动类型为 `Automatic`。

安装会将便携根目录及 `data` 权限收紧为仅 SYSTEM 与 Administrators 完全控制。正式使用时请保留整个目录结构；迁移到新路径后通过 GUI 重新安装即可更新服务注册路径。

安装完成后可在“服务”管理器中看到 `VNTS 2.0 Service`，也可以使用脚本控制：

```powershell
.\start-vnts2-service.ps1
.\status-vnts2-service.ps1
.\diagnose-vnts2-service.ps1
.\stop-vnts2-service.ps1
.\uninstall-vnts2-service.ps1
```

所有写操作都要求管理员 PowerShell。启动、停止和卸载均为幂等操作，默认等待 30 秒进入确定状态，不会强制终止进程。

隔离测试或并行实例可以显式指定服务名；安装脚本会把相同名称写入隐藏的 Rust SCM 参数：

```powershell
.\install-vnts2-service.ps1 -ServiceName "vnts2-test" -SkipStart
.\start-vnts2-service.ps1 -ServiceName "vnts2-test"
.\diagnose-vnts2-service.ps1 -ServiceName "vnts2-test"
.\stop-vnts2-service.ps1 -ServiceName "vnts2-test"
.\uninstall-vnts2-service.ps1 -ServiceName "vnts2-test"
```

卸载服务不会删除 `data` 中的配置、数据库、密钥、证书、日志或 `.backups`。

## 生成 Windows 双发布线

默认构建只从官方源码目录的当前 Release 读取二进制，并输出到独立 `dist` 目录，不会改动便携根目录：

```powershell
.\build-vnts2-windows-package.ps1
```

以上命令生成面向低配服务器的轻量包，入口保持为 `VNTS2-Manager.exe`。

生成面向高配置主机的增强包：

```powershell
.\build-vnts2-console-package.ps1
```

增强脚本会先在纯 ASCII 路径的 `VntsConsole2.0` 工程执行 Windows Release 构建，再按严格白名单复制 Flutter 运行库、`VNTS2-Console.exe`、同一个 `vnts2.exe` 和运维脚本。增强 staging 中不会混入轻量入口，两条发布线互不替换。

增强包完整解压后可直接运行 `VNTS2-Console.exe`。增强版默认使用独立服务 `vnts2-console`、独立管理端口 `127.0.0.1:39871`、独立隧道端口 `39872`，并只读写增强版解压目录内的 `data`；不会迁移或覆盖轻量版 `vnts2` 服务及其数据。首次没有增强版 `data/config.toml` 时，控制台自动生成随机一次性引导配置、安装并启动增强服务，然后显示全屏首次设置门禁；管理员设置自己的账号和密码并验证成功后才能进入。已有增强版配置和凭据不会被覆盖。API 密码不限制长度，但不能为空、不能为 `admin`、不能与账号相同。

需要在构建成功后同步更新便携根目录的 `vnts2.exe` 和 `VNTS2-Manager.exe` 时，显式执行：

```powershell
.\build-vnts2-windows-package.ps1 -SyncPortableRoot
```

同步前会将不同的旧二进制保存到 `data\.backups`，采用临时文件替换并在替换前后校验 SHA-256；永远不会覆盖 `data\config.toml` 或其他运行数据。

输出包括：

- `dist\vnts2-2.0.0-windows-x64\` staging 目录；
- 同名 ZIP；
- ZIP 外部 `.sha256` 文件；
- 包内 `MANIFEST.json` 和 `SHA256SUMS.txt`。

增强版对应输出为 `dist\vnts2-console-2.0.0-windows-x64\`、同名 ZIP 和 `.sha256`。

发布后可在管理员 PowerShell 中执行真实解压目录烟雾（会创建并清理随机隔离服务）：

```powershell
.\tests\windows-console-distribution-smoke.ps1 `
  -ZipPath .\dist\vnts2-console-2.0.0-windows-x64.zip
```

烟雾覆盖解压、安装、启动、认证仪表盘、配置备份与重启、诊断、增强控制台进程启动、停止和卸载。迁移与失败恢复继续由 `windows-service-e2e.Tests.ps1` 覆盖。

增强版零安装链路另有 GUI 真实启动烟雾：

```powershell
.\tests\windows-console-zero-install-smoke.ps1 `
  -ZipPath .\dist\vnts2-console-2.0.0-windows-x64.zip
```

它验证全新目录由 GUI 自动安装和启动服务、首次设置标记与随机引导凭据、短密码生效、旧引导凭据失效，以及测试服务卸载清理。

构建采用固定 ZIP 时间戳、固定条目顺序和 UTF-8 无 BOM 元数据；只复制白名单文件，不会携带真实配置、数据库、日志、密钥、证书、锁文件或历史备份。

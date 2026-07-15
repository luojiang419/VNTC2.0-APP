# Web 模块 6.4.1：Windows 服务安装与卸载

## 目标与边界

本模块只收敛 Windows 服务的安装、重复安装和卸载契约，不进入启动、停止、状态、诊断页面或交付 ZIP。

运行时继续使用既有入口：

```text
vnts2.exe --service --conf <绝对配置路径>
```

服务名默认 `vnts2`，显示名默认 `VNTS 2.0 Service`，启动类型为自动，运行账户为 `LocalSystem`。

## 只读审计结论

- `src/main.rs` 在解析配置路径后把工作目录切到配置文件目录，再初始化日志并连接 SCM。
- `src/windows_service.rs` 固定注册服务名 `vnts2`，接受 Stop/Shutdown，并通过 oneshot 通知应用退出。
- 配置、`network_control.db`、相对密钥/证书和 `logs` 都以配置文件目录为运行数据根目录。
- 旧安装脚本没有管理员权限和原生命令退出码检查，同名服务一律报错，卸载依赖固定休眠。
- 本机旧部署目录允许普通 Users 写入，而服务运行账户是 LocalSystem；普通用户若可替换服务二进制，会形成本地提权风险。
- 旧 `New-Service` 安装结果可能在 ImagePath 中留下双重引号，需要在重复安装时兼容识别并重新规范化。
- Rust 服务当前在应用初始化完成前上报 Running，部分启动失败仍会 panic；这些运行时语义与启停/诊断一起留给 6.4.2，避免扩大本模块。

## 安装契约

`install-vnts2-service.ps1` 必须满足：

1. 仅允许在 Windows 管理员 PowerShell 中运行。
2. 服务名只能包含字母、数字、点、下划线和连字符，最长 80 字符。
3. `TargetDir` 中必须存在普通文件 `vnts2.exe` 和 `config.toml`。
4. 服务启动命令中的可执行文件和配置路径都使用完整双引号，配置路径为绝对路径。
5. 同名服务不存在时创建自动启动的 LocalSystem 独立进程服务。
6. 同名服务存在且规范化后的 ImagePath、服务账户均相同时，重复执行成功并重新校验服务配置。
7. 同名服务指向其他路径或使用其他账户时拒绝覆盖。
8. 冲突检查通过后，服务目录关闭继承，只保留 SYSTEM 与 Administrators 的完全控制权限；文件和子目录继承该权限。
9. 使用 `sc.exe config` 固化 ImagePath、自动启动和正常错误控制；描述、失败恢复和 failure flag 的每一次调用都检查退出码。
10. 默认安装后启动并等待最多 30 秒进入 Running；`-SkipStart` 只安装不启动。

## 卸载契约

`uninstall-vnts2-service.ps1` 必须满足：

1. 使用与安装相同的 Windows、管理员和服务名校验。
2. 服务不存在时成功返回，保证重复卸载幂等。
3. 服务未停止时发送正常 Stop 控制并等待最多 30 秒；不强制终止进程。
4. 仅在确认 Stopped 后执行 `sc.exe delete`，检查退出码，并等待服务对象消失。
5. 不删除配置、数据库、密钥、证书、日志或 `.backups`。

## 文件结构

- `windows-deploy/vnts2-service-common.ps1`：权限、服务名、ImagePath、`sc.exe` 和确定状态等待的共享函数。
- `windows-deploy/install-vnts2-service.ps1`：安装与相同配置重复安装。
- `windows-deploy/uninstall-vnts2-service.ps1`：优雅停止与幂等卸载。
- `windows-deploy/tests/windows-service-install-uninstall.Tests.ps1`：PowerShell 5.1/7 语法、路径、旧引号兼容、输入校验和临时 NTFS ACL 契约测试。

所有本阶段改动脚本使用 UTF-8 BOM，确保包含中文时 Windows PowerShell 5.1 与 PowerShell 7 均能正确解析。

## 验收标准

- 契约测试不创建、启动、停止、修改或删除真实 Windows 服务。
- PowerShell 5.1 与 PowerShell 7 的契约测试均通过。
- 旧双重引号 ImagePath 可被识别为同一路径；不同路径不会被当作幂等安装。
- 临时目录 ACL 测试确认关闭继承且只保留 SYSTEM/Administrators。
- 既有 Rust 测试、静态检查、安全审计和 release 构建全部回归通过。

## 后续 6.4.2

- 更新 start/stop 脚本为管理员校验、幂等操作和确定超时。
- 新增 status/diagnose，检查 SCM 状态、ImagePath、账户、启动类型、配置/二进制/数据目录、ACL、日志和端口。
- 修正 Rust SCM StartPending/Running/StopPending/Stopped 的时序及非 panic 退出语义。
- 完成真实临时服务的端到端安装、启动、状态、停止和卸载验收。

## 本阶段验证结果

- PowerShell 5.1 / PowerShell 7 契约测试：通过。
- UTF-8 BOM：四个本阶段脚本均为 `EFBBBF`。
- 临时 NTFS ACL：关闭继承，只包含 SYSTEM 与 Administrators，测试后已清理。
- 真实 `vnts2` 服务：全程保持 Stopped，ImagePath/账户/启动类型未改变。
- Rust：fmt、check、82/82 test 通过。
- clippy：当前 Rust 1.95 对既有 `network_state_provider.rs:1196` 报 `clippy::never_loop` deny；显式允许该既有 lint 后通过，其余为既有告警，本模块未顺带修改无关逻辑。
- audit：无漏洞，仅允许的 `spin 0.9.8` yanked 警告。
- deny licenses/sources、`git diff --check`：通过。
- release：首个 NASM 为 `C:\Program Files\NASM\nasm.exe`；重复构建哈希一致。
- `vnts2.exe`：7,270,400 字节，SHA-256 `A328330906B9209DC85A8612836BDBD72ACB46B78262AC5D0F538995EF8321FB`。

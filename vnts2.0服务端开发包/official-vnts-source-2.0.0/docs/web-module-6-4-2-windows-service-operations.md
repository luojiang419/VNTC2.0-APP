# Web 模块 6.4.2：Windows 服务运维、诊断与 SCM 生命周期

## 目标与边界

本模块完成 Windows 服务的启动、停止、状态、诊断和 Rust SCM 生命周期闭环，并对 6.4.1 的安装命令补齐自定义服务名契约。

本模块不创建交付 ZIP，不复制 release 到正式分发目录，不进入 6.5。

## 命令契约

安装后的 ImagePath 固定为：

```text
"<absolute-vnts2.exe>" --service --service-name "<service-name>" --conf "<absolute-config.toml>"
```

- `--service`、`--service-name` 均为隐藏参数，不出现在普通帮助中。
- `--service-name` 只能与 `--service` 同时使用。
- 服务名必须为 1–80 字节 ASCII，只允许字母、数字、点、下划线和连字符。
- 未显式指定服务名时仍使用 `vnts2`，兼容旧 SCM 配置。
- 安装脚本使用 `Win32_Service.Change` 规范带空格路径，避免 Windows PowerShell 5.1 向 `sc.exe config` 封送嵌套引号时破坏 ImagePath。
- 旧的 `--service --conf` ImagePath 只在默认 `vnts2` 服务上被规范化为同一命令；自定义服务名不会错误继承默认名。

## Rust SCM 生命周期

### 启动

1. `service_dispatcher` 使用命令行传入的服务名连接 SCM。
2. 注册控制回调并上报 StartPending，等待提示为 30 秒。
3. 加载配置；初始化数据库/身份；绑定 TCP、WebSocket、QUIC、peer、WireGuard。
4. HTTP 监听器完成真实 bind 后通过 oneshot 返回启动结果。
5. 所有同步启动步骤成功后发送应用级 ready 信号。
6. SCM 收到 ready 后才上报 Running，并开始接受 Stop/Shutdown。

配置不存在、TOML 无效、证书失败、端口冲突或监听启动失败均返回 `anyhow::Error`，不再从这条路径 panic。

### 停止与失败

- Stop/Shutdown 回调先上报 StopPending，再发送 shutdown oneshot。
- HTTP 与 WireGuard 使用既有 cancellation token 完成退出，Tokio runtime 随服务主函数销毁其余监听任务。
- 正常停止上报 Stopped + Win32 0。
- 启动或运行失败上报 Stopped + ServiceSpecific 1；SCM 对应 Win32 错误为 1066。
- 错误详情进入 `logs/vnts2.log`，服务状态只保留稳定数值，不向 SCM 泄露配置内容。

## PowerShell 运维脚本

### 启动与停止

- start/stop 都要求 Windows 管理员、合法服务名，并接受 1–300 秒超时。
- Running/Stopped 重复执行成功。
- StartPending/StopPending 等待确定状态，不依赖固定休眠。
- stop 发送正常 Stop 控制，不使用 `-Force` 或进程终止。

### 状态

`status-vnts2-service.ps1` 为只读命令，输出：

- Installed、State、StartMode、StartName；
- ProcessId、ExitCode；
- 解析后的 ExecutablePath、ConfigPath；
- SCM 原始 PathName。

服务不存在时返回 `Installed=false`、`State=NotInstalled`，不把正常查询当成异常。

### 诊断

`diagnose-vnts2-service.ps1` 输出 PASS/WARN/FAIL 检查项：

- SCM 状态、进程号和退出码；
- ImagePath 结构及其中的服务名；
- LocalSystem 账户和自动启动类型；
- 可执行文件存在性、长度和 SHA-256；
- 配置文件存在性；
- 仅提取允许的 `*_bind` 地址；
- 服务目录是否关闭继承、是否存在 SYSTEM/Administrators 之外的 Allow 规则；
- 日志文件大小与更新时间，不输出日志正文；
- Running 进程的实际 TCP/UDP 监听端口。

诊断不会输出 password、server_token、WireGuard 主密钥、私钥或配置全文。存在 FAIL 时抛出错误并返回非零进程码。

## 文件结构

- `src/main.rs`：隐藏 CLI、ready 信号、非 panic 启动链。
- `src/windows_service.rs`：动态服务名、SCM 状态机和 service-specific 退出码。
- `src/http/web_server.rs`：HTTP bind 成功/失败启动信号。
- `windows-deploy/vnts2-service-common.ps1`：共享命令、解析、配置 bind 脱敏和确定等待。
- `windows-deploy/install-vnts2-service.ps1`：写入动态服务名并用 CIM 规范 ImagePath。
- `windows-deploy/start-vnts2-service.ps1` / `stop-vnts2-service.ps1`：幂等启停。
- `windows-deploy/status-vnts2-service.ps1` / `diagnose-vnts2-service.ps1`：状态和诊断。
- `windows-deploy/tests/windows-service-install-uninstall.Tests.ps1`：无 SCM 写入的双版本契约测试。
- `windows-deploy/tests/windows-service-e2e.Tests.ps1`：隔离临时服务真实闭环。

## 端到端验收

真实测试使用随机 `vnts2-e2e-*` 服务名和 `%TEMP%\VNTS2 Service Test <GUID>` 目录：

1. 复制 release、配置和脚本到临时目录。
2. 安装但不启动，再重复安装验证幂等。
3. status 验证 Stopped、动态服务名和带空格路径。
4. 启动两次并验证 Running/ProcessId。
5. diagnose 验证 SCM、ACL、配置 bind、日志和实际 TCP/UDP 端口。
6. 停止两次并验证 Stopped。
7. 关闭恢复重试、写入无效 TOML，验证启动失败、Win32 1066 和 ServiceSpecific 1。
8. 卸载两次并验证 NotInstalled。
9. 对默认 `vnts2` 服务的状态与 ImagePath 做前后对比。
10. `finally` 只允许删除名称匹配的临时服务和位于系统临时目录、具有固定前缀的目录。

## 验收标准

- PowerShell 5.1/7 契约测试通过，全部脚本保持 UTF-8 BOM。
- Rust 单元/集成测试新增动态服务名、非法服务名和缺失配置不 panic 契约。
- 临时服务完整闭环通过，默认服务不变，无临时服务或目录残留。
- fmt/check/test/clippy/audit/deny/diff/release 全部通过。

## 本阶段验证结果

- PowerShell 5.1 / 7 契约与真实 E2E：全部通过。
- Rust：fmt、check、86/86 test 通过。
- clippy：Rust 1.95 既有 `clippy::never_loop` 显式允许后通过，其余为既有告警。
- audit：无漏洞，仅允许的 `spin 0.9.8` yanked 警告。
- deny licenses/sources、`git diff --check`：通过。
- release：首个 NASM 为 `C:\Program Files\NASM\nasm.exe`；重复构建哈希一致。
- `vnts2.exe`：7,278,592 字节，SHA-256 `DC77B17820CF9826C8443D9FAA46E233D0A3B56A1CD717629E43200B1F8065AF`。
- 临时服务和目录均为 0 残留；默认 `vnts2` 保持 Stopped 且 ImagePath 不变。

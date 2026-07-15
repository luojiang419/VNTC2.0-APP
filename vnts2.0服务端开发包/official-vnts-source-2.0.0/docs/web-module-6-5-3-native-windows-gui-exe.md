# Web 模块 6.5.3：原生 Windows GUI EXE

## 目标

将客户入口从 `VNTS2-Manager.cmd` / PowerShell WinForms 脚本升级为真正的 `VNTS2-Manager.exe`。正式发布包只推荐并只包含 EXE 窗口入口；PowerShell 脚本保留为隐藏的后台服务运维组件。

## 技术方案

- C# WinForms，Windows 自带 .NET Framework 运行时。
- x64、`winexe` Windows GUI 子系统，不创建控制台窗口。
- 清单使用 `requireAdministrator` 和 Common Controls v6。
- 窗口、状态卡片、按钮、日志区、确认框全部由 C# 实现。
- 后台 PowerShell 使用 `CreateNoWindow=true`、隐藏窗口、编码命令和 UTF-8 重定向。
- 不启动或嵌套 `vnts2-manager.ps1`。
- 服务写操作继续委托模块 6.4/6.5.2.2 已验证脚本。

## GUI 功能

1. 初始化或编辑有效配置。
2. 当前目录安装并启动；检测已有部署时明确确认安全更新。
3. 启动服务。
4. 停止服务。
5. 运行诊断。
6. 打开回环 Web 控制台。
7. 确认后卸载服务。
8. 清空输出。

窗口使用顶部品牌区、状态卡片、快捷操作区和等宽日志区；服务名变更后状态标记为待刷新。配置和更新继续遵守跨部署保护、旧程序备份与失败回滚规则。

## 构建与发布

- `gui/Vnts2Manager.cs`：原生 GUI 源码。
- `gui/VNTS2-Manager.manifest`：管理员权限与系统兼容清单。
- `build-vnts2-manager-exe.ps1`：调用系统 .NET Framework x64 C# 编译器。
- `tests/windows-native-gui-manager.Tests.ps1`：PE、版本、实现、清单和脚本委托契约。

正式包删除 `VNTS2-Manager.cmd` 和 `vnts2-manager.ps1`，新增 `VNTS2-Manager.exe`。MANIFEST 保持 16 个白名单负载。

## 验证

- PE `Machine=0x8664`，Subsystem 为 Windows GUI。
- 文件/产品版本 `2.0.0.0` / `VNTS 2.0`。
- `--validate-only`：`Implementation=CSharpWinForms`、`ExecutableGui=true`、`UsesPowerShellGui=false`、8 项操作。
- 最终 `dist` EXE 实际启动：进程名 `VNTS2-Manager`，窗口标题正确，`Responding=True`。
- 企业桌面捕获接口仍返回 `0x80004002`，无法抓取截图/控件树；未绕过策略。进程窗口、PE 契约和服务 E2E交叉验证通过。
- 随机服务 Running 后，由最终 EXE 自身读取到相同状态和 PID；随后端口诊断、失败退出语义、停止和卸载全部通过。
- PowerShell 5.1/7 服务、旧 GUI、原生 GUI 和发布包契约全部通过。
- Rust fmt/check/test 86/86/clippy/audit/deny/release 通过，仅既有告警和允许的 `spin 0.9.8` yanked 提示。
- Release 使用 `C:\Program Files\NASM\nasm.exe`。
- ZIP 重复构建哈希一致；临时服务、目录和 GUI 进程为 0。

## 签名状态

本机证书存储中没有带私钥的 Authenticode 代码签名证书，因此 EXE 当前为 `NotSigned`。功能与安全测试不受影响；面向外部客户建立“已验证发布者”信誉需要后续提供企业 EV/OV 代码签名证书并加入签名和验签步骤，不应使用自签名证书冒充正式发布。

## 最终产物

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `dist/vnts2-2.0.0-windows-x64/VNTS2-Manager.exe` | 28,672 | `1DC868353C99A4E42E05B892914163EB2D5F1FD386AF37691CB66BA727DF9284` |
| `target/release/vnts2.exe` | 7,278,592 | `65C274C652247DE3C1EB4594AB9E7FBFDFBA9EF3E46A9EF8753E0FFE40D78A65` |
| `dist/vnts2-2.0.0-windows-x64.zip` | 3,840,022 | `8BFF5EF10474EC809446BBC66C916966ED71BA119CA4764267A5CC0F3EFE50B1` |

# Web 模块 6.5.3.1：原生 GUI 安全启用 Web 控制台

## 目标

修复已安装服务沿用旧配置、没有显式 `web_bind` 时，原生 GUI 点击“Web 控制台”只能报错的问题。修复必须保留“省略 `web_bind` 即禁用 Web”的服务端安全语义，不允许静默开放远程监听。

## 根因

`ConfigFile::default()` 虽然包含回环默认地址，但 TOML 反序列化旧配置时，缺少的 `Option` 字段为 `None`。服务端因此不会启动 HTTP 监听。原生 GUI 旧实现只读取显式 `web_bind`，字段不存在便抛出“配置尚未启用 web_bind”，该提示与真实运行状态一致，但缺少面向客户的一键安全启用流程。

## 最小实现

- 点击“Web 控制台”时先读取已安装服务注册的真实配置路径。
- 若已有 `web_bind`，继续校验其只能是 IPv4/IPv6 回环地址，然后打开浏览器。
- 若未配置，显示默认选择“否”的确认框；只有用户确认后才写配置。
- 固定启用 `127.0.0.1:29871`，不开放 LAN/WAN 地址。
- 保留已有非空用户名；已有密码非空且不等于 `admin`/用户名时继续使用，否则通过 `RNGCryptoServiceProvider` 生成 24 位密码。
- 新设置必须写在首个 `[table]` 前，确保 `web_bind`、`username`、`password` 属于 TOML 根级，兼容旧配置末尾的 `[custom_nets]`。
- 在配置目录 `.backups` 创建 `config.toml.pre-web-*.bak`，使用同目录临时文件和 `File.Replace` 原子替换。
- 重启服务并等待 TCP 端点开始监听；任何失败均恢复原配置和原服务状态。
- 成功后使用独立 WinForms 对话框展示地址、用户名和密码，密码仅在用户点击时复制，不进入 GUI 操作日志。

## 关键前后对比

修改前：

```text
点击 Web 控制台
  -> 配置没有 web_bind
  -> 报错并结束
```

修改后：

```text
点击 Web 控制台
  -> 用户确认安全启用
  -> 备份配置
  -> 根级写入 loopback + 强凭据
  -> 重启并等待监听
  -> 展示凭据
  -> 打开浏览器
```

构建脚本同时改为在 `%TEMP%\vnts2-manager-build-*` ASCII 路径中调用 .NET Framework C# 编译器，并直接传递参数值，修复 PowerShell 7 对旧 `csc.exe` 的带引号中文路径兼容问题；临时目录在 `finally` 中删除。

## 测试

- 原生 EXE 契约验证加密安全随机数、回环限制、原子替换、独立备份、凭据窗口和密码不写日志。
- E2E 从没有 `web_bind` 且包含 `[custom_nets]` 的配置启动随机 Windows 服务。
- 由正式 `VNTS2-Manager.exe --enable-web-only` 调用与 GUI 相同的实现。
- 验证三项设置位于 TOML 根级、备份存在、服务恢复 Running。
- 真实请求首页并得到 HTTP 200，再用生成凭据请求 `/api/login` 并取得 token。
- 根目录构建与最终 `dist` 包各完成一次完整隔离服务 E2E；随机服务和临时目录均清理。
- 最终 GUI 窗口真实启动，标题为 `VNTS 2.0 Windows 服务管理器`，`Responding=True`，并正常关闭。

## 质量门禁

- Windows GUI、原生 GUI、服务脚本、发布包契约在 PowerShell 7 与 5.1 下通过。
- Rust `fmt`、`check`、86/86 测试通过。
- Rust 1.95 对既有 `network_state_provider.rs` 的 `clippy::never_loop` 为 deny；按项目既有约定执行 `cargo clippy --locked --all-targets -- -A clippy::never_loop` 后通过，其余为既有告警，本模块未改 Rust 业务源码。
- `cargo audit` 无安全漏洞，仅有允许的 `spin 0.9.8` yanked 警告。
- `cargo deny check licenses sources` 通过。
- Release 使用 `C:\Program Files\NASM\nasm.exe` 并构建通过。

## 发布产物

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `windows-deploy/dist/vnts2-2.0.0-windows-x64/VNTS2-Manager.exe` | 36,864 | `92192215DB35448AAF221EF76701919172B853D3A84D1A8440458CD694FC416E` |
| `target/release/vnts2.exe` | 7,278,592 | `BB2762B524B32527A79D17C9EC2FFF0C7CDD7B170D0156DB8BF3D4C9DDA93296` |
| `windows-deploy/dist/vnts2-2.0.0-windows-x64.zip` | 3,844,202 | `81397B24AAFD6E04912661BE4C692014719D82A2BC379275C6E675005DF78F00` |

`VNTS2-Manager.exe` 仍为 `NotSigned`；本机没有正式 Authenticode 证书，本模块未生成自签名发布证书。

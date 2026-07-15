# Web 模块 6.5.1：Windows 可重复发布包

## 1. 目标与边界

本模块只实现 Windows x64 交付目录、ZIP、文件清单和 SHA-256 校验，不执行解压后的真实 Windows 服务安装验收。真实 SCM 验收留给 6.5.2。

目标：

1. 从当前 `target/release/vnts2.exe` 生成独立 staging，不覆盖开发目录中的旧二进制或运行配置。
2. 使用严格文件白名单，排除密码、token、密钥、证书、数据库、日志、锁和历史备份。
3. 固定 ZIP 条目顺序、条目时间戳和元数据编码，使 PowerShell 5.1 与 7 生成相同结果。
4. 提供机器可读 `MANIFEST.json`、标准 `SHA256SUMS.txt` 和 ZIP 外部 `.sha256`。

## 2. 修改前审计

`windows-deploy` 原有两个文件不能直接作为正式发布输入：

| 文件 | 字节 | SHA-256 | 结论 |
| --- | ---: | --- | --- |
| `windows-deploy/vnts2.exe` | 4,906,496 | `E7A8DC0956BA6D39F2C0C23955D0AF22B754BE91C15B972E5864E63255B3FF83` | 旧产物，仅保留兼容，不覆盖 |
| `windows-deploy/config.toml` | 182 | `31D9DE12E8AC2AAED93B4E11384724FF0D407206255DD06CC8DEDFDFCEF1A141` | 运行配置，不作为发布模板 |

当前 Release、第三方声明和前端许可证分别从官方源码目录的 `target/release`、`NOTICE` 和 `static/licenses` 读取。

## 3. 发布白名单

生成脚本只复制以下 14 个负载文件：

- `vnts2.exe`
- `config.example.toml`
- 包内 `README.md`
- `NOTICE`
- 安装、卸载、启动、停止、状态、诊断和共享脚本
- `licenses/fontawesome.txt`
- `licenses/tailwindcss.txt`
- `licenses/vue.txt`

脚本随后生成 `MANIFEST.json` 和 `SHA256SUMS.txt`，最终 ZIP 共 16 个文件。构建脚本、测试、真实 `config.toml`、数据库、日志、密钥、证书、锁文件和 `.backups` 不在复制路径中。

## 4. 配置与秘密边界

发布包只带 `config.example.toml`。模板默认：

- 启用 TCP、QUIC、WebSocket 和持久化；
- 不启用 Web 管理端，因此不存在有效管理密码；
- 不启用 WireGuard，因此不存在有效主密钥路径；
- 不启用多服务器互联，因此不存在有效 `server_token`；
- 相关敏感项仅以注释示例出现。

安装前必须显式复制模板为 `config.toml`。启用 Web、WireGuard 或 peer server 时，由管理员在部署目录中写入真实秘密，秘密不会回流到发布 ZIP。

## 5. 可重复生成设计

`build-vnts2-windows-package.ps1` 的确定性约束：

1. 包名固定为 `vnts2-<version>-windows-x64`。
2. 文件按 `/` 规范化相对路径排序。
3. JSON 与校验清单使用 UTF-8 无 BOM 和 LF。
4. ZIP 每个条目的时间戳固定为 `2000-01-01T00:00:00Z`。
5. ZIP 条目顺序与 staging 排序一致，外部属性固定为 0。
6. MANIFEST 不写生成时间、主机名、绝对路径或随机值。

删除旧输出前，脚本验证目标的父目录必须等于指定输出目录，并拒绝重解析点，避免递归清理越界。

## 6. 清单语义

- `MANIFEST.json`：记录包名、版本、平台、架构，以及 14 个白名单负载文件的相对路径、长度和 SHA-256。
- `SHA256SUMS.txt`：覆盖 14 个负载文件和 `MANIFEST.json`，不自引用。
- `vnts2-2.0.0-windows-x64.zip.sha256`：位于 ZIP 外，记录完整 ZIP 的 SHA-256。

## 7. 自动化验证

`windows-package-build.Tests.ps1` 使用带空格的随机临时目录和固定伪二进制验证：

- PowerShell 语法与严格白名单；
- 相同输入重复生成 ZIP 哈希一致；
- 修改输入文件时间戳不影响 ZIP；
- MANIFEST 的长度和哈希逐项正确；
- SHA256SUMS 格式、引用和哈希逐项正确；
- ZIP 条目与 staging 完全一致；
- 模板没有有效敏感配置项；
- 旧 `windows-deploy/vnts2.exe` 和 `config.toml` 哈希不变；
- 临时目录只在系统临时根下按受限前缀清理。

真实 Release 还额外验证了 PowerShell 5.1 重复生成、5.1/7 跨引擎生成，以及解压后 16 个文件逐项哈希一致。

## 8. 最终产物

| 产物 | 字节 | SHA-256 |
| --- | ---: | --- |
| `target/release/vnts2.exe` | 7,278,592 | `BB483893EF5C3DA407F33E3DBC3C59420A43BFF40038D00E0E4377200E1AB0E1` |
| `dist/vnts2-2.0.0-windows-x64.zip` | 3,899,263 | `28B312A8C48052AEB8BB193815CD2681B8B97992C62BAA61877F7188C633A702` |

全量门禁后 Release 发生重新链接，哈希由阶段开始时的 `DC77B1...` 更新为上表值；045 创建后没有官方源码文件被写入，随后连续构建哈希稳定。最终 staging 与 ZIP 均使用重新构建后的二进制。

## 9. 验证结果

- PowerShell 5.1/7 服务契约：通过。
- PowerShell 5.1/7 发布契约：通过。
- PowerShell 5.1 重复生成：同哈希。
- PowerShell 5.1/7 跨引擎生成：同哈希。
- 解压后文件清单与逐文件哈希：一致。
- `cargo fmt --all -- --check`：通过。
- `cargo check --all-targets`：通过。
- `cargo test --all-targets`：86/86 通过。
- Clippy：既有 `never_loop` 显式允许后通过，其余为既有告警。
- `cargo audit`：无漏洞，仅允许的 `spin 0.9.8` yanked 提示。
- `cargo deny check licenses/sources`：通过。
- Release：优先使用 `C:\Program Files\NASM\nasm.exe`。
- `git diff --check`：通过，仅既有 CRLF 提示。
- 临时契约目录、解压目录和临时服务：0。
- `target`：6.363 GiB，低于 20 GiB，不清理缓存。

## 10. 下一步

模块 6.5.2 从最终 ZIP 解压到隔离临时目录，校验清单后生成测试配置，并用随机服务名完成真实安装、启动、状态、诊断、停止和卸载。该阶段仍不得修改默认 `vnts2` 服务或进入 6.6。

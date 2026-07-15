# WireGuard 模块 3.2：服务端身份立即轮换

## 范围

本模块提供维护窗口内的 WireGuard 服务端 X25519 身份轮换。轮换完成后数据库只保留新身份，旧服务端公钥立即失效；不提供旧/新身份宽限期、回滚身份或并行 UDP 端口。

当前项目尚未实现正式 WireGuard UDP 监听和客户端，因此本阶段只建立可验证的停机轮换能力，不启动任何网络监听，也不修改 peer、路由、MTU、Web 页面或客户端代码。

## 前置条件

- 配置必须显式启用 `persistence = true`。
- 配置必须包含已有的 `wireguard_master_key_file`。
- `network_control.db` 和其中的 WireGuard 服务端身份必须已经存在。
- VNTS 服务必须停止；正常服务与轮换命令共用 `network_control.db.lock` 独占锁。
- 主密钥文件仍为模块 3.0 定义的严格 32 字节二进制文件。

## 命令

```powershell
vnts2.exe `
  --conf C:\ProgramData\vnts2\config.toml `
  --rotate-wireguard-identity
```

身份轮换与主密钥轮换互斥，不能同时传入：

```text
--rotate-wireguard-master-key <NEW_KEY_FILE>
--rotate-wireguard-identity
```

轮换模式不允许隐式创建默认配置，也不能由 Windows Service Control Manager 服务模式执行。

## 原子切换模型

轮换按以下顺序执行：

1. 获取数据库进程独占锁，拒绝与正在运行的 VNTS 服务并发。
2. 从配置读取当前主密钥文件，以当前主密钥认证解密旧身份。
3. 使用操作系统随机源生成新的 X25519 静态身份。
4. 保持 `format_version` 和 `encryption_key_version` 不变，以新随机 nonce 和同一主密钥加密新私钥。
5. 执行单条 SQLite `UPDATE`，`WHERE` 匹配完整旧格式版本、主密钥版本、nonce、密文、公钥和时间戳。
6. 只有影响一行才视为成功；记录已变化或任何错误都会拒绝覆盖。

身份轮换不等于主密钥轮换。它改变 X25519 私钥和公钥，但继续使用同一个加密主密钥，因此 `encryption_key_version` 不递增。

## 输出编码

成功输出包括：

- 旧公钥和新公钥的 32 字节十六进制值，用于与数据库及服务日志核对；
- 新公钥的标准带填充 Base64 值，可用于 WireGuard 客户端配置中的服务端 `PublicKey`。

示意输出：

```text
WireGuard server identity rotated; old public key <HEX>; new public key <HEX>
New WireGuard client public key (Base64): <BASE64>
Update every WireGuard client with the new server public key before restarting VNTS
```

## 运维步骤

1. 记录轮换前公钥并停止 VNTS 服务。
2. 备份当前配置、主密钥文件和数据库；备份的访问权限应与主密钥一致。
3. 执行 `--rotate-wireguard-identity`，保存命令输出。
4. 把所有 WireGuard 客户端所配置的服务端公钥更新为输出的 Base64 新公钥。
5. 启动 VNTS，确认日志中的十六进制公钥等于命令输出的新十六进制公钥。
6. 客户端支持和正式 UDP 运行时完成后，再执行握手与数据面验收。

当前没有正式 UDP 监听或已部署的项目内 WireGuard 客户端，因此第 4、6 步暂时属于未来接入契约。

## 失败与恢复

- 服务仍在运行：独占锁失败，数据库不变。
- 配置、数据库、身份记录或主密钥缺失：命令失败，数据库不变。
- 主密钥错误或密文认证失败：命令失败关闭，不生成替代记录。
- 完整旧记录 CAS 不匹配：拒绝覆盖并报告并发变化。
- 命令成功后不存在应用级旧身份回滚；恢复旧公钥只能从轮换前受控备份恢复完整数据库与匹配主密钥，并承担恢复点之后其他数据库变更丢失的风险。

应用层不会保留旧身份，但 SQLite 历史页、WAL、外部备份和底层存储介质可能仍存在旧密文。本模块不宣称提供法证级安全擦除；旧密文的实际风险仍取决于主密钥是否同时泄露。

## 验收

- CLI 强制要求显式配置，并与主密钥轮换互斥。
- 在线轮换被进程锁拒绝，停机轮换成功。
- 旧、新 X25519 公钥不同，数据库仍只有一个身份记录。
- 当前主密钥能恢复新身份，错误主密钥或失败轮换不改变旧记录。
- 主密钥版本保持不变，随机 nonce 和密文发生变化。
- 配置文件和主密钥文件内容不被命令修改。
- 新公钥同时提供十六进制审计值和标准 WireGuard Base64 值。

## 本阶段验证结果

- `cargo fmt --all -- --check`：通过。
- `cargo check --locked --all-targets`：通过，仅保留仓库既有 2 组 `dead_code` 警告。
- `cargo test --locked`：41/41 通过（33 项单元测试、6 项 BoringTun 集成测试、1 项身份轮换进程测试、1 项主密钥轮换进程测试）。
- `cargo clippy --locked --all-targets -- -A clippy::never_loop`：通过；21 条均为既有提示，本模块新增提示为 0。
- `cargo audit`：扫描 366 个锁定依赖，无漏洞；仅保留允许的既有 `spin 0.9.8` yanked 提示。
- `cargo deny check licenses sources`：`licenses ok, sources ok`。
- `git diff --check`：通过。
- Windows release 构建确认官方 `C:\Program Files\NASM\nasm.exe` 优先。
- release 产物：`target/release/vnts2.exe`，5,876,224 字节，SHA-256 `F5033D3B6E960CA5D231DDF68C97AA40287FD62F834BBCBDE6F6206C82C3E620`。

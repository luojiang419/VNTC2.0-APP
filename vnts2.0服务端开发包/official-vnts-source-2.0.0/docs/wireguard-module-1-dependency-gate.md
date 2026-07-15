# WireGuard 模块 1：依赖验证与协议冻结

## 范围

本模块只验证 BoringTun 依赖并冻结 VNT/WireGuard 互通所需的追加协议。它不包含数据库、WireGuard UDP 监听、路由转发、管理 API 或密钥持久化。

## 依赖冻结

- crate：`boringtun`
- 精确版本：`0.7.1`
- Cargo 配置：`default-features = false`
- crates.io 发布时间：2026-05-01
- 官方 tag：`boringtun-0.7.1`
- tag 提交：`253f7afb2b3df9e952065d10bf2af19913cb176b`
- 许可证：BSD-3-Clause，完整再分发声明见仓库 `NOTICE`
- 上游仓库：https://github.com/cloudflare/boringtun
- crates.io：https://crates.io/crates/boringtun/0.7.1

截至 2026-07-13，上游仓库未归档，默认分支为 `master`，2026-06 仍有提交。`master` 已领先 `0.7.1` tag，且存在继续重构的开放变更，因此只允许使用精确发布版本，不允许 Git/master 依赖。

## 协议冻结

- `NodeType.VNT = 0`
- `NodeType.WIREGUARD = 1`
- `RegRequestMsg.allow_wire_guard = 10`
- `ClientSimpleInfo.node_type = 3`
- `rpc.ClientInfo.node_type = 8`
- `MsgType.WireGuardRelay = 18`
- `WireGuardRelay` payload 为原始 IPv4 包；该语义仅在后续桥接模块实现。

所有字段均为追加。旧客户端未发送字段时，Proto3 默认值分别为 `false` 与 `VNT(0)`。服务端在正式桥接实现前不得向未声明 `allow_wire_guard=true` 的会话发送 `WireGuardRelay`。

## 技术门测试

`tests/boringtun_gate.rs` 覆盖：

- WireGuard 握手与双向 IPv4 收发；
- 匿名握手恢复发起方静态公钥，为按公钥分派 peer 提供依据；
- 握手限速触发 cookie reply，缺少源地址时拒绝；
- transport counter 重放拒绝；
- 已建立会话在 UDP 源地址变化后继续解密；
- 单会话 4096 包有界压力循环。

这些测试证明 0.7.1 的核心公共 API 满足后续原型需要，但不替代模块 2 的真实 UDP、并发、多 peer、MTU、长期运行和故障注入验证。

## 模块 1 首轮依赖门结论（历史状态）

### 已通过

- `cargo test --locked`：13 项测试全部通过，其中协议/golden 7 项，BoringTun 技术门 6 项。
- `cargo fmt --all --check`：通过。
- `cargo check --locked --all-targets`：通过，只有仓库既有 `dead_code` 警告。
- `cargo clippy --locked --all-targets -- -A clippy::never_loop`：完成；保留 23 条仓库既有 lint 警告，新增代码没有遗留独有告警。
- `cargo deny check licenses sources`：`licenses ok, sources ok`。
- `cargo build --release --locked`：Windows 本机构建通过，产物 `target/release/vnts2.exe`，大小 4,907,008 字节，SHA-256 `F3E617D5AEDD252217BFA27A7A9BC9ABE0C65F6567747B711BA4282EB3961EC4`。该产物仅用于本模块兼容检查，不改变首版 Linux 正式发布目标。
- BoringTun 依赖树确认仅启用空的默认 feature 集，未启用 `device`、`ffi-bindings`、`jni-bindings` 或 `mock-instant`。
- 当前 Lockfile 与修改前 `024` 备份的 RustSec 结果一致：均为 9 个漏洞、4 个允许警告；BoringTun 及其新增传递依赖没有新增命中。

### 全仓安全阻塞

`cargo audit` 仍失败，以下问题均已存在于模块 1 修改前的 Lockfile：

- `bytes 1.11.0`：RUSTSEC-2026-0007；
- `quinn-proto 0.11.13`：RUSTSEC-2026-0037、RUSTSEC-2026-0185；
- `rsa 0.9.9`：RUSTSEC-2023-0071，审计库标记为暂无修复版本；
- `rustls-webpki 0.103.8`：RUSTSEC-2026-0049、0098、0099、0104；
- `time 0.3.44`：RUSTSEC-2026-0009；
- 另有 `rustls-pemfile` unmaintained，以及 `anyhow`、`rand 0.8/0.9` 的健全性警告。

### 模块 1 当时判定

`boringtun 0.7.1` 的增量技术门和许可证门通过，可以保留该精确依赖与协议冻结改动；VNTS 2.0 的全仓发布安全门失败。在完成既有依赖漏洞处置并重新通过 `cargo audit` 之前，不进入模块 2 的数据库或正式桥接实现。

## 模块 1.1：既有依赖安全收口

### 范围与原则

本阶段只处置模块 1 发现的既有 RustSec 问题，不修改 WireGuard 协议冻结值，不新增表、SQL、UDP 监听、密钥持久化或正式桥接。所有安全修复均使用定点版本或收窄未使用功能，不使用 advisory ignore。

### 可升级依赖

- `bytes 1.11.0 -> 1.11.1`，修复 RUSTSEC-2026-0007；
- `quinn-proto 0.11.13 -> 0.11.15`，修复 RUSTSEC-2026-0037、RUSTSEC-2026-0185；
- `rustls-webpki 0.103.8 -> 0.103.13`，修复 RUSTSEC-2026-0049、0098、0099、0104；
- `time 0.3.44 -> 0.3.47`，修复 RUSTSEC-2026-0009；
- `anyhow 1.0.100 -> 1.0.103`，修复 RUSTSEC-2026-0190；
- `rand 0.9.2 -> 0.9.3`，修复 RUSTSEC-2026-0097。

### RSA / JSON Web Token 处置

实际调用分析确认，HTTP 登录与鉴权仅使用 `Header::default()`、`EncodingKey::from_secret`、`DecodingKey::from_secret` 和 `Validation::default()`，即共享密钥 HS256；没有 RSA 密钥加载、RSA 签名或 RSA 解密调用。

`rsa 0.9.9` 由 `jsonwebtoken` 的全算法 `rust_crypto` 功能间接引入，且 RUSTSEC-2023-0071 无直接修复版本。最小安全处置为保留 `jsonwebtoken 10.2.0` API，设置 `default-features = false` 并切换到 `aws_lc_rs` 后端。新增回归测试固定验证 HS256 算法及共享密钥编码/解码契约；`rsa` 已从 Lockfile 删除。

Windows 本机构建 AWS-LC 需要 NASM；本阶段安装并使用官方 NASM 3.02，debug 与 release 均已在项目原路径构建通过。

### 未使用依赖路径收窄

- 使用 `rustls::pki_types::pem::PemObject` 替换停止维护的 `rustls-pemfile`，继续支持证书链以及 PKCS#1、PKCS#8、SEC1 私钥，保留“未找到有效私钥”的错误语义；`rustls-pemfile` 已从 Lockfile 删除。
- 项目数据库代码只使用 SQLite，三个 `FromRow` 派生没有实际调用。移除未使用派生后，将顶层 `sqlx` 聚合包收窄为精确同版本的 `sqlx-core = 0.8.6` 与 `sqlx-sqlite = 0.8.6`，从 Lockfile 删除未运行的宏、MySQL、PostgreSQL、旧 `rand 0.8` 与 RSA 路径。表结构、SQL 文本、连接池类型及运行时行为未改变。

### 最终验证

- `cargo fmt --all --check`：通过；
- `cargo check --locked --all-targets`：通过，保留仓库既有 2 组 `dead_code` 警告；
- `cargo test --locked`：14 项全部通过，其中原有 13 项全部保留，新增 1 项 HS256 契约测试；
- `cargo clippy --locked --all-targets -- -A clippy::never_loop`：完成，保留 23 条仓库既有告警，本阶段没有遗留独有告警；
- `cargo audit`：联网更新到 1160 条 advisory 后通过，扫描 366 个锁定依赖，无漏洞、无允许警告；
- `cargo deny check licenses sources`：`licenses ok, sources ok`，仅保留既有未命中 `BSD-1-Clause` allow 项提示；
- `cargo build --release --locked`：通过；产物 `target/release/vnts2.exe`，大小 5,740,032 字节，SHA-256 `CB356EF0966B1D33913582277835F2ABCE59B53892691A52FE626ECE7C1DD01D`。

### 当前判定

模块 1.1 的全仓发布安全门通过，模块 2 的 RustSec 阻塞已解除。仍须在用户确认后才能进入模块 2；本阶段没有提前实施数据库模型或正式桥接。

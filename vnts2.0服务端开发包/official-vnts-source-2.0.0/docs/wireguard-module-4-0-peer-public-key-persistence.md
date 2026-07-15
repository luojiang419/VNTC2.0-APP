# WireGuard 模块 4.0：peer 公钥持久化

## 范围

本模块建立正式 WireGuard peer 的持久化身份模型，为后续匿名握手分派、UDP 运行时和管理页面提供唯一数据源。本阶段只实现 SQLite schema 和数据库操作，不增加 HTTP 路由、Web 页面、UDP 监听、PSK、路由、MTU 或客户端逻辑。

模块 2.2 的 `peer_id` 继续作为网络内不透明稳定标识，不从公钥派生，也不放入 URL 路径。WireGuard 客户端公钥在整台服务端范围内唯一，因为匿名握手首先只能恢复发起方静态公钥；如果同一公钥映射到多个网络，运行时无法安全、确定地选择 peer。

## schema v3

```sql
CREATE TABLE IF NOT EXISTS wireguard_peers (
    network_code TEXT NOT NULL,
    peer_id TEXT NOT NULL CHECK(length(peer_id) > 0),
    public_key BLOB NOT NULL CHECK(length(public_key) = 32),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(network_code, peer_id),
    UNIQUE(public_key)
);
```

字段契约：

- `(network_code, peer_id)`：网络内唯一 peer 身份，与现有 IP 占用主键一致。
- `public_key`：严格 32 字节 X25519 公钥 BLOB，全服务器唯一。数据库层不保存 Base64 文本；后续 API 负责标准 WireGuard Base64 编解码。
- `enabled`：只控制未来是否接受该 peer 的新握手；禁用不会释放 IP 或删除配置。
- `created_at`、`updated_at`：Unix 秒时间戳，由调用方提供。
- 公钥创建后没有普通更新入口；公钥轮换必须在后续模块定义显式安全操作。

本阶段不增加 PSK 字段。既有 `ip_allocations` 中只有 `peer_id`、没有可推导公钥的记录全部原样保留，迁移不会伪造 peer、公钥或删除 IP。

## 不使用 SQLite 外键

现有网络保存使用 `INSERT OR REPLACE`。SQLite 的 REPLACE 语义包含删除再插入，如果现在添加 `wireguard_peers.network_code` 外键，网络更新可能错误触发限制或级联行为。

因此 schema v3 不添加外键，完整性由以下入口保证：

- peer 创建使用单条 `INSERT ... SELECT ... WHERE EXISTS`，只有网络已存在才插入；
- 网络编辑和删除调用统一资源占用检查；即使 peer 没有 IP，存在启用或禁用 peer 时也拒绝操作；
- peer 硬删除和 IP 释放在同一个 SQLite 事务内完成。

后续如果要启用外键，必须先把网络保存从 `INSERT OR REPLACE` 改为不会删除行的 UPSERT，并单独迁移和验收。

## 数据库操作

模块提供以下持久化入口：

- 创建 peer：要求网络存在，拒绝重复 `(network_code, peer_id)` 或全局重复公钥；不提供静默 upsert。
- 按网络列出：按 `peer_id` 稳定排序。
- 按公钥查找：最多返回一个 peer，为未来匿名握手分派提供入口。
- 设置启停：只修改 `enabled` 和 `updated_at`，保留 IP。
- 硬删除：同一事务删除 peer 记录及 `(network_code, peer_id)` 对应的 WireGuard IP 占用，并分别返回实际删除结果。

这些入口要求数据库已经初始化，不在 `persistence = false` 时返回假成功。

## 删除和回滚

硬删除事务顺序为：

1. 删除 `wireguard_peers` 中的目标记录；
2. 删除 `ip_allocations` 中对应的 `wireguard_peer` 占用；
3. 提交事务。

任一步失败都会回滚两项修改。测试使用 SQLite `BEFORE DELETE` 失败触发器阻止第二步，真实证明第一步也会回滚，peer 和 IP 均保持不变。

删除入口也会释放同一标识下的既有孤立 IP 占用，即使还没有正式 peer 记录；这为后续管理 API 提供显式清理路径，但迁移本身不会主动清理。

## 验收范围

- v2→v3 迁移保留既有 WireGuard peer IP，占用不会自动生成 peer。
- 迁移重复执行幂等，`PRAGMA user_version = 3`。
- 同一 `peer_id` 可在不同网络绑定不同公钥。
- 同一公钥不能绑定到任何第二个 peer 或网络。
- 非 32 字节公钥被 schema 拒绝。
- 不存在的网络不能创建 peer。
- 禁用 peer 后记录和 IP 均保留。
- 无 IP peer 也会阻止网络编辑和删除。
- 硬删除同时移除 peer 与 IP；第二步失败时两者均回滚。

## 本阶段验证结果

- 数据库专项测试：9/9 通过，其中 4 项为本模块新增迁移/peer 测试。
- `cargo fmt --all -- --check`：通过。
- `cargo check --locked --all-targets`：通过，仅保留仓库既有 2 组 `dead_code` 警告。
- `cargo test --locked`：45/45 通过（37 项单元测试、6 项 BoringTun 集成测试、2 项真实轮换进程测试）。
- `cargo clippy --locked --all-targets -- -A clippy::never_loop`：通过；21 条均为既有提示，本模块新增提示为 0。
- `cargo audit`：扫描 366 个锁定依赖，无漏洞；仅保留允许的既有 `spin 0.9.8` yanked 提示。
- `cargo deny check licenses sources`：`licenses ok, sources ok`。
- `git diff --check`：通过。
- Windows release 构建确认官方 `C:\Program Files\NASM\nasm.exe` 优先。
- release 产物：`target/release/vnts2.exe`，5,880,832 字节，SHA-256 `E445C82EDE5159D94CDABF5FBE9C60B430AA68A5EB2B120748A096E0E71ED2D4`。

# WireGuard 模块 2：数据库迁移与统一 IP 占用模型

## 模块边界

本模块只建立 VNT 设备与 WireGuard peer 共用的数据库 IP 占用约束，并让现有内存分配器识别已持久化的 WireGuard 预留地址。本模块不包含 UDP 监听、WireGuard 握手、数据桥接、路由转发、密钥持久化、管理 API 或客户端实现。

## 统一占用表

SQLite schema 版本提升为 `1`，新增 `ip_allocations`：

```sql
CREATE TABLE ip_allocations (
    network_code TEXT NOT NULL,
    ip TEXT NOT NULL,
    owner_type TEXT NOT NULL CHECK(owner_type IN ('vnt_device', 'wireguard_peer')),
    owner_id TEXT NOT NULL CHECK(length(owner_id) > 0),
    PRIMARY KEY(network_code, owner_type, owner_id),
    UNIQUE(network_code, ip)
);
```

- `(network_code, ip)` 是统一排他约束：同一网络内，一个 IP 只能属于一个 VNT 设备或一个 WireGuard peer。
- `(network_code, owner_type, owner_id)` 使同一个所有者在同一网络最多保留一个 IP。
- WireGuard 所有者只保存不透明的 `peer_id`。本阶段不定义其生成规则，也不保存公钥、私钥或预共享密钥。
- 不同网络可复用同一 IPv4 地址，保持现有多网络语义。

## 旧库迁移与兼容

迁移在单个 SQLite 事务中执行：

1. 以 `CREATE TABLE IF NOT EXISTS` 创建统一占用表。
2. 保留已有 WireGuard 占用，重建所有 `vnt_device` 占用并从非空 `devices.ip` 回填。
3. 重建 `devices` 的 INSERT、UPDATE、DELETE 触发器。
4. 成功后设置 `PRAGMA user_version = 1` 并提交。

迁移可重复执行。若旧库在同一网络中已有重复设备 IP，或旧设备 IP 与已存在的 WireGuard 占用冲突，唯一约束会使整个迁移事务回滚，服务端不会静默丢弃或任意选择所有者。

`devices.ip` 继续保留，旧代码无需改写。三个触发器保证：

- 新增带 IP 的设备时同步创建占用；
- 设备换 IP 时先移除旧占用并创建新占用；
- 设备释放 IP、删除设备或按网络批量删除设备时同步移除占用。

触发器属于原设备写语句的同一事务。目标 IP 已被占用时，设备写入及触发器中的中间变更会整体回滚。

## WireGuard peer 数据库接口

数据库层新增以下阶段性接口：

- `reserve_wireguard_peer_ip(network_code, peer_id, ip)`：创建或更新 peer 的 IP 占用；冲突时失败。
- `release_wireguard_peer_ip(network_code, peer_id)`：释放 peer 占用。
- `load_wireguard_peer_ip_allocations(network_code)`：加载网络内全部 peer 预留地址。

前两个接口暂未接入管理 API，并以 `dead_code` 定点允许标记明确阶段边界。后续模块接入时必须同时更新活动中的 `NetworkState`，不能只改数据库。

## 内存分配兼容

`NetworkState` 初始化时除加载旧 `devices` 外，还加载 `wireguard_peer` 占用：

- 自动分配跳过 peer 已占用地址；
- 客户端指定 peer 已占用地址时返回明确的 IP 重复错误；
- 带 peer 预留的网络不会被当作完全空闲状态回收。

数据库仍是跨所有者的最终唯一性防线；内存避让用于在进入持久化前给现有注册流程提供一致行为。

## 验证范围

模块测试覆盖：

- 旧 `devices.ip` 回填与重复迁移；
- 歧义旧库数据的事务回滚；
- peer 先占用、设备后申请，以及设备先占用、peer 后申请；
- 设备冲突换 IP 的原子回滚；
- 设备更新/释放触发器与 peer 释放；
- 不同网络复用同一 IP；
- 自动分配避让 WireGuard peer 预留 IP。

最终结果：本阶段新增 5 项专项测试，连同既有测试共 19 项全部通过；格式、全目标编译、Clippy、联网 RustSec、许可证/来源门禁和 Windows release 构建均通过。release 产物 SHA-256 为 `2EFCCB2FD7E4C780DEF8E1E071B436868EC555E3551BC640C429D97A80EF2DD5`。

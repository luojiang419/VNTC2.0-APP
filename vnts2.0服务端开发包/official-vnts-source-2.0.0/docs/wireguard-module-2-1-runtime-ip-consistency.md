# WireGuard 模块 2.1：运行时 IP 预留一致性

## 模块边界

本模块只提供 WireGuard peer IP 预留、移动和释放的服务端内部运行时入口，使 SQLite 统一占用表与活动 `NetworkState` 保持一致。本模块不开放管理 API，不定义 peer 密钥，不实现 UDP 监听、握手、正式桥接、路由转发或客户端功能。

## 内部入口

`ControlService` 新增两个 crate 内部方法：

- `reserve_wireguard_peer_ip(network_code, peer_id, ip)`
- `release_wireguard_peer_ip(network_code, peer_id)`

入口只接受已知网络。网络尚未进入活动状态时，先通过现有双重检查锁从数据库构造完整 `NetworkState`，再执行变更，避免只更新数据库而遗漏内存视图。接口暂未接入 HTTP 路由，以定点 `dead_code` 标记保持阶段边界。

## 预留与移动顺序

每个网络使用独立的异步锁串行化 WireGuard IP 变更。预留或移动按以下顺序执行：

1. 校验非空 `peer_id`、目标网段和网关地址。
2. 在 `lease_state` 短锁内检查 VNT 设备及其他 WireGuard peer 冲突，并立即在内存占住目标 IP。
3. peer 移动时暂时同时保留旧 IP 和新 IP。
4. 等待数据库原子 upsert。
5. 数据库成功后移除旧 IP；失败时移除新增占位，恢复修改前状态。

等待数据库期间不会持有 `parking_lot::Mutex`，因此不会让同步数据路径跨越异步等待；旧、新地址同时保留则阻止 VNT 分配器在失败回滚窗口抢占任一地址。

## 释放顺序

释放操作在数据库删除成功前保留内存占用。数据库失败时不改变内存；数据库成功后再移除该 peer 的运行时占用。若数据库或内存任一侧实际存在占用，返回值为 `true`，便于无持久化模式和旧状态恢复时收敛。

## 冲突语义

- 目标 IP 已由 VNT 设备使用：在写数据库前拒绝。
- 目标 IP 已由其他 WireGuard peer 使用：在写数据库前拒绝。
- 数据库发现活动内存未包含的持久化冲突：数据库拒绝，新增内存占位回滚。
- peer 重复预留相同 IP：保持幂等。
- peer 移动 IP：数据库提交前旧、新 IP 均不可被 VNT 使用。

## 验证范围

专项测试覆盖：

- peer 移动等待数据库时旧、新 IP 同时保留；
- 数据库提交后只保留新 IP，并可正常释放；
- 数据库预留失败恢复旧 IP；
- 数据库释放失败保持原内存占用；
- VNT 设备、其他 peer、空 peer ID 和网段外地址在运行时被拒绝。

最终结果：本模块新增 3 项专项测试，连同模块 2 的自动分配避让测试共 4 项运行时测试通过；全仓 16 项单元测试与 6 项 BoringTun 集成测试全部通过。格式、全目标编译、Clippy、RustSec、许可证/来源门禁和 Windows release 构建均通过。release 产物 SHA-256 为 `CF6AD28B96EFC228C3F49A21D5844F0F5C8030A8D063A5D669BA51B095C84D93`。

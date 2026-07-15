# WireGuard 模块 5.0：正式 UDP 监听与多 peer BoringTun 控制面运行时

## 阶段目标与边界

本阶段为 VNTS 服务端增加可选的正式 WireGuard UDP 监听，以及由数据库 peer 元数据驱动的多 peer BoringTun 会话运行时。模块 5.0 只负责握手、会话、认证、限流、endpoint、生命周期和管理面撤销。

本阶段明确不建立 WireGuard 与 VNT 的数据桥接，不增加路由、MTU、Web 页面或客户端能力。即使 BoringTun 成功解密出来源合法的 IPv4 载荷，运行时仍会丢弃该载荷。因此模块 5.0 完成后仍然“尚未建立可用数据路径”；数据桥接属于模块 5.1。

## 配置契约

新增配置：

```toml
# 默认不启用 WireGuard UDP
# wireguard_bind = "0.0.0.0:51820"

# 默认值为 4096
wireguard_max_active_peers = 4096
```

- `wireguard_bind` 是独立的 `Option<SocketAddr>`，不复用 `quic_bind` 或 `server_quic_bind`。
- 旧配置缺少这两个字段时，UDP 监听保持关闭，最大活跃 peer 数使用 4096。
- 只配置 `wireguard_master_key_file` 而不配置 `wireguard_bind` 时，继续只初始化和维护服务端身份。
- 配置 `wireguard_bind` 时，必须同时满足：
  - `persistence = true`；
  - SQLite 数据库初始化成功；
  - 配置了 `wireguard_master_key_file`；
  - 主密钥文件存在、可读且严格为 32 字节；
  - UDP 地址绑定成功。
- 任一条件失败都会使服务启动失败，不降级为无 WireGuard 监听运行。

## 依赖与第三方边界

`boringtun = 0.7.1` 从开发依赖移动到生产依赖，继续使用 `default-features = false`。没有 fork、补丁或修改第三方源码。

运行时只使用 BoringTun 公开 API：

- `RateLimiter::verify_packet`；
- `parse_handshake_anon`；
- `Tunn::new`；
- `Tunn::decapsulate`；
- `Tunn::update_timers`。

BoringTun 0.7.1 的 `handle_verified_packet` 是 `pub(crate)`，生产代码没有绕过其可见性。

## 运行时结构

单个 Tokio UDP 任务独占全部活跃 peer 状态，避免跨任务共享或锁住 `Tunn`：

```text
UDP datagram
  -> 全局 RateLimiter 验证/限流
  -> 匿名握手公钥或 receiver index 分派
  -> 数据库确认 peer 资格（仅首次握手）
  -> 对应 peer 的 Tunn::decapsulate 二次验证
  -> 发送握手/定时器输出
  -> 合格内层载荷仍丢弃
```

管理面通过有界命令通道发送撤销命令，并用 oneshot 确认运行时已经移除会话。UDP 收包、定时器和撤销命令都在同一任务串行处理。

## 全局握手防护与二次校验

运行时创建一个服务端全局 `RateLimiter`，阈值固定为 BoringTun 官方 Device 使用的 100 次握手/秒。每秒调用 `reset_count`。

每个 UDP 数据报在匿名分派前先调用共享 `RateLimiter::verify_packet`：

- 畸形包或 MAC1 失败：无响应丢弃；
- 超过阈值且 MAC2 不满足：向来源地址发送 Cookie Reply；
- 验证通过：才允许解析匿名握手静态公钥或 receiver index。

选定 peer 后，仍通过公开的 `Tunn::decapsulate` 处理原始数据报。每个 `Tunn` 使用共享的独立非限流 verifier（限制为 `u64::MAX`），因此第二次 MAC 校验不会再次计入全局 100 次/秒阈值，也不会绕过首层未知握手 DoS 防护。

## peer 资格、容量和索引

握手发起包通过 `parse_handshake_anon` 恢复发起方静态公钥，然后执行数据库联合查询。只有同时满足以下条件才允许懒创建运行时 peer：

- 公钥已存在于 `wireguard_peers`；
- `enabled = true`；
- `ip_allocations` 中已有该 peer 的 IPv4 预留。

未知、禁用、无 IP 和数据库记录异常的 peer 均无响应丢弃。

活跃 peer 达到 `wireguard_max_active_peers` 时拒绝新的会话，不驱逐现有 peer。每个 peer 使用随机的 24 位 receiver index；碰撞时重新随机，连续 128 次无法得到未占用值时拒绝该新会话。分派键严格使用 `receiver_idx >> 8`，不使用可预测的递增索引。

PSK 和 persistent keepalive 均为 `None`，本阶段不增加公钥更新。

## endpoint 与内层来源校验

receiver index 只能用于找到候选 peer，不能直接触发 endpoint 漫游。只有当数据报已通过全局验证，且该 peer 的 `Tunn::decapsulate` 没有返回错误时，才更新 peer endpoint。

因此以下输入不会更新 endpoint：

- Cookie Reply 流程；
- 未知 receiver index；
- 畸形包；
- MAC 或 AEAD 认证失败包。

BoringTun 解密出的内层来源必须是该运行时 peer 创建时确认的预留 IPv4。来源 IPv4 不匹配和全部 IPv6 明文均拒绝。来源匹配的 IPv4 在本阶段也只完成资格判定，随后丢弃，不写入 VNT 或任何系统接口。

## 定时器、过期与停机

- 每 250ms 对每个活跃 peer 调用 `Tunn::update_timers`。
- 沿用 BoringTun 原生会话接收窗口和定时器，不增加自定义空闲超时。
- `WireGuardError::ConnectionExpired` 后立即从 peer、公钥和 receiver index 三张运行时映射中移除该 peer。
- 停机时取消共享 `CancellationToken`，等待 UDP 任务退出；任务持有的 `UdpSocket` 随后释放。
- 自动测试证明任务退出后同一 UDP 地址可立即重新绑定。

## 管理面同步撤销语义

禁用和删除 peer 继续使用模块 4.1 的网络级更新锁。持锁期间按以下顺序完成：

```text
数据库禁用或删除
  -> 内存 IP 状态更新（删除时）
  -> 向 UDP 运行时发送撤销命令
  -> 等待运行时确认会话已移除
  -> API 返回
```

重复禁用或幂等删除也会确认运行时中不存在该 peer。重新启用只允许后续新握手，不恢复旧会话。

这项语义有意收紧模块 4.0 中“禁用只拒绝新握手”的阶段说明：从模块 5.0 起，禁用和删除都会立即撤销已有运行时会话，并且 API 必须等到撤销确认后才返回。

## 测试覆盖

`tests/wireguard_udp_runtime.rs` 使用真实 VNTS 子进程、HTTP API、SQLite 持久化和 UDP socket 覆盖：

- 旧配置不含新字段仍可启动；
- 缺持久化、数据库、主密钥、有效主密钥或可绑定端口时失败启动；
- 两个已启用且有 IP 的 peer 独立完成真实 UDP 握手；
- 两个 peer 的随机 24 位 receiver index 不相同；
- 未知、禁用和无 IP peer 无响应；
- 容量满时拒绝新 peer 且不驱逐活跃 peer；
- 禁用/删除 API 返回后旧 peer 不能继续握手；
- 重新启用后必须新握手；
- 全局握手压力触发 Cookie Reply；
- IPv4 来源不匹配、IPv6 和本阶段合格 IPv4 数据均不产生数据路径输出。

模块内单元测试另外覆盖随机 index 碰撞重试、认证后 endpoint 漫游、认证失败不漫游、严格内层来源判断，以及取消后端口重绑。

# WireGuard 模块 5.2：VNT 客户端数据面

## 目标与边界

本模块让显式启用 `allowWg` 的 VNT 2.0 客户端能够与模块 5.1 服务端的 WireGuard peer 双向交换原始 IPv4。实现位于 `VntcApp1.0/vendor/vnt-core-2.0.0` 共享核心，因此 `VntcApp1.0` 与 `vntc2.0windows` 使用同一份协议和数据路径。

本阶段不修改 Android 原生 bridge/runtime、聊天、页面、model、版本或构建脚本，不进入 Web、客户端 UI 或部署阶段。

## 冻结行为

| 项目 | 行为 |
| --- | --- |
| 能力开关 | 继续使用已有 `allowWg`，默认关闭；注册字段固定为 proto field 10。 |
| 节点类型 | `VNT=0`、`WIREGUARD=1`；旧服务端/旧消息缺省为 VNT。 |
| Relay 类型 | `RelayProbe=16`、`Quic=17`、`WireGuardRelay=18`、`RelayProbeReply=19`。 |
| 出站选择 | 只有本虚拟网段内、在线且类型为 WireGuard 的目标使用原始 Relay。 |
| 传输方式 | WireGuard Relay 只发服务器，不使用 P2P、QUIC、FEC、压缩或普通 VNT 载荷加密。 |
| 回程入口 | 只有启用能力且来源仍是在线 WireGuard 节点的合格 Relay 可写入 TUN。 |
| 路由范围 | 不把外部子网路由重写成 WireGuard Relay；跨服务器由模块 5.1 服务端处理。 |
| 广播/组播 | WireGuard 节点不进入 P2P 和广播候选；特殊目标不会进入桥接。 |
| 反欺骗 | 外层 src/dst 必须与内层 IPv4 完全一致，内层源必须是服务端声明的 WireGuard IP。 |
| MTU | 内层 IPv4 最大 1420；较小显式值保留，核心默认 1380 保留。 |
| 分片/MSS | 允许已经存在且单片不超限的 IPv4 分片；客户端不分片、不重组、不改 MSS。 |
| 错误语义 | 非法、过大、过期、能力不匹配或节点状态不匹配的包静默丢弃。 |

## 数据流

```text
TUN IPv4
  ├─ 目标为普通 VNT / 网关 / 广播 / 外部路由
  │    └─ 原有 QUIC/P2P/压缩/加密路径（不变）
  └─ 目标为在线 WireGuard 节点
       └─ IPv4 严格校验 → WireGuardRelay(18) → VNTS 服务器直送

VNTS WireGuardRelay(18)
  └─ 能力 + 在线节点类型 + Envelope + IPv4 严格校验
       └─ 以普通 IPv4 载荷写入 TUN
```

## 校验规则

内层包必须满足：长度 20..=1420、IPv4 version=4、IHL 合法、`total_length` 与载荷长度精确一致、源/目标均位于当前虚拟网段，且不能是网络地址、广播、组播或网关。Relay 还必须是非 gateway、非 compressed、非 FEC、TTL 非零，并且外层源/目标与内层一致。

服务端节点列表是路由授权的一部分：WireGuard peer 离线、删除、禁用、IP 改变或服务器连接断开后，客户端不再把旧 IP 识别为可桥接目标；回程同样失败关闭。

## 兼容性

- 未启用 `allowWg` 的客户端仍使用原有 VNT 数据面。
- Proto3 新字段均为追加字段，旧端忽略未知字段，新客户端把缺失 `node_type` 解析为 VNT。
- WireGuard 节点不会触发 P2P 打洞或被当成广播接收方。
- Android 原生运行时未在本阶段修改；现有默认 VPN MTU 为 1400，已低于 1420。Rust 侧仍对所有平台执行 1420 载荷硬上限。

## 验证

- 共享核心 23/23；Rust 适配层 4/4；Flutter 171/171；服务端兼容回归 65/65。
- fmt、check、clippy、Flutter analyze、release 和 `git diff --check` 通过。
- release DLL：9,782,272 字节；SHA-256 `7BE7D8083B563ECB5B5904698AB0ECB303FF819CBEAC3113423E55B58606C781`。

客户端既有锁文件的 RustSec 漏洞和缺失 `deny.toml` 已记录在 036 差异文档，未用忽略规则伪造通过，也未在本模块中扩展为依赖升级。

# WireGuard 模块 4.2：一键生成 Peer 后端接口

## 目标

管理端只提交网络编号和易读的设备名称，由 VNTS 生成客户端 WireGuard 密钥对、创建 Peer 并自动分配虚拟 IP。客户端私钥只在创建成功响应中出现一次。

## 接口

`POST /api/wireguard/peers/generated`

请求受现有 JWT 中间件保护：

```json
{
  "network_code": "network-a",
  "peer_id": "alice-laptop",
  "enabled": true
}
```

`enabled` 可省略，默认 `true`。成功响应的 `data`：

```json
{
  "peer": {
    "network_code": "network-a",
    "peer_id": "alice-laptop",
    "public_key": "<客户端标准 Base64 公钥>",
    "enabled": true,
    "ip": "10.26.0.2",
    "created_at": 0,
    "updated_at": 0
  },
  "private_key": "<仅本次返回的客户端标准 Base64 私钥>",
  "server_public_key": "<服务端标准 Base64 公钥>",
  "listen_addr": "0.0.0.0:51820",
  "endpoint": "vpn.example.com:51820",
  "allowed_ips": "10.26.0.0/24"
}
```

`listen_addr` 是服务实际绑定地址，只用于诊断；`endpoint` 来自严格校验的 `wireguard_public_endpoint`，用于客户端配置。WireGuard UDP 已运行但未配置公网 Endpoint 时接口返回503，并且不会生成密钥或创建 Peer。

## 原子性与并发

- 生成接口复用每个网络已有的 `wireguard_ip_update_lock`。
- 自动地址分配同时避开网关、VNT 设备 IP 和其他 WireGuard Peer IP。
- 内存先建立临时预留，防止并发设备分配同一地址。
- SQLite 在单个事务内同时插入 `wireguard_peers` 和 `ip_allocations`。
- 数据库失败时回滚内存临时预留，不留下幽灵占用。

## 私钥边界

- SQLite 只保存客户端32字节公钥。
- 普通 Peer 列表、状态接口和重启恢复均不返回客户端私钥。
- 失败响应不包含已生成的私钥。
- 成功响应包含 `Cache-Control: no-store`，禁止浏览器或中间缓存留存密钥响应。
- 代码不记录请求响应或客户端私钥日志。
- 管理员若丢失成功响应，应删除对应 Peer 后重新生成；服务端不能恢复旧私钥。

## 服务端身份

WireGuard 运行时句柄只额外暴露自身32字节公钥，不暴露静态私钥。`/api/status` 的 WireGuard 状态增加规范 Base64 `public_key`；未运行时该字段为 `null`。

## 验收

- 未认证生成请求返回 HTTP 401。
- WireGuard UDP 未运行时返回 HTTP 503，不生成不可用配置。
- 公网 Endpoint 未配置时返回 HTTP 503，数据库仍无新 Peer。
- 成功请求返回匹配的 X25519 私钥/公钥、服务端公钥、自动 IP、网段和公网 Endpoint。
- 重复 Peer 返回 HTTP 409，且失败响应不包含私钥。
- 重启后公钥和 IP 保持不变，客户端私钥不可查询。
- SQLite 文件不包含客户端私钥的 Base64 文本或原始32字节。

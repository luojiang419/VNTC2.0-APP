# WireGuard 模块 2.2：IP 管理 API

## 模块边界

本模块只把模块 2.1 的运行时一致性入口接入现有 JWT 管理 API。管理对象是“不透明 peer ID 与 IPv4 占用”，不是完整 WireGuard peer。本模块不保存或返回公钥、私钥、预共享密钥，不实现 UDP 监听、握手、正式桥接、路由转发或客户端页面。

## 受保护资源

所有接口都位于现有 `/api` JWT 中间件之后，必须携带 `Authorization: Bearer <token>`：

### 查询

```http
GET /api/wireguard/peer_ips?network_code=network-a
```

成功响应的 `data` 为数组，按 `peer_id` 稳定排序：

```json
{
  "code": 200,
  "msg": "success",
  "data": [{ "peer_id": "peer-a", "ip": "10.26.0.2" }]
}
```

查询会等待同一网络中正在进行的预留、移动或释放完成，然后读取活动 `NetworkState`，不会绕过运行时直接查询数据库，也不会暴露移动提交窗口中的临时双占位。

### 预留或移动

```http
PUT /api/wireguard/peer_ips
Content-Type: application/json

{
  "network_code": "network-a",
  "peer_id": "peer-a",
  "ip": "10.26.0.2"
}
```

处理器只负责解析 IPv4 文本，随后调用 `ControlService::reserve_wireguard_peer_ip`。已知网络校验、VNT/peer 冲突、数据库提交与内存回滚均由模块 2.1 处理。

### 释放

```http
DELETE /api/wireguard/peer_ips?network_code=network-a&peer_id=peer-a
```

成功响应的 `data` 为布尔值：数据库或活动内存任一侧实际删除占用时为 `true`；重复释放不存在的占用时为 `false`。

## 错误与兼容语义

- 缺少或无效 Bearer token：沿用现有 HTTP `401` 与 `ApiResponse`。
- 无效 IPv4、未知网络、空 peer ID 或 IP 冲突：沿用现有管理 API 约定，HTTP 响应保持成功传输，响应体 `code = 400` 并携带错误消息。
- `peer_id` 通过 JSON 或查询参数传递，不放入 URL 路径，避免对不透明标识附加路径字符约束。
- 现有路由、响应包络和登录接口不变。

## 验证范围

专项测试覆盖：

- 未授权 PUT 返回 HTTP 401；
- 无效 IPv4 返回业务码 400；
- 授权 PUT 预留后，GET 从运行时返回 peer ID 与 IP；
- DELETE 返回实际删除结果，随后 GET 返回空数组；
- 多个运行时占用按 peer ID 稳定排序。

最终结果：本模块新增 1 项 HTTP 端到端测试和 1 项运行时排序测试；全仓 18 项单元测试与 6 项 BoringTun 集成测试全部通过。格式、全目标编译、Clippy、RustSec、许可证/来源门禁和 Windows release 构建均通过。release 产物 SHA-256 为 `E8C52153CDCDC3E91982B82D48A4379AE1660704913F0CDC3474DFFD52228D12`。

# WireGuard 模块 4.1：peer 管理 API

## 范围

本模块为模块 4.0 的持久化 peer 增加 JWT 保护的创建、列出、启停和硬删除接口，并与模块 2.2 的 peer IP 接口共享同一网络级更新锁。本阶段不增加公钥更新、PSK、UDP 监听、BoringTun 多 peer 运行时、Web 页面或客户端逻辑。

所有 peer 管理操作要求 SQLite 已初始化。`persistence = false` 时不会返回假成功，而是返回业务错误。

## HTTP 接口

以下路由位于现有 `/api` JWT 中间件之后。除认证失败外，沿用项目现有响应契约：HTTP 状态为 200，业务结果由 JSON `code` 表示。

- `GET /api/wireguard/peers?network_code=...`：按 `peer_id` 稳定排序列出指定网络的 peer。
- `POST /api/wireguard/peers`：创建 peer，不提供 upsert。
- `PUT /api/wireguard/peers/enabled`：幂等设置启停状态并返回更新后的 peer。
- `DELETE /api/wireguard/peers?network_code=...&peer_id=...`：幂等硬删除 peer，并原子释放其 IP。

认证头为 `Authorization: Bearer <JWT>`。缺少、无效或过期 JWT 返回 HTTP 401，响应业务码也为 401。

创建请求：

```json
{
  "network_code": "network-a",
  "peer_id": "peer-a",
  "public_key": "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=",
  "enabled": true
}
```

`enabled` 可省略，默认 `true`。重复 `(network_code, peer_id)` 或全服务器重复 `public_key` 返回 HTTP 200、业务码 400。

启停请求：

```json
{
  "network_code": "network-a",
  "peer_id": "peer-a",
  "enabled": false
}
```

peer 响应字段：

```json
{
  "network_code": "network-a",
  "peer_id": "peer-a",
  "public_key": "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=",
  "enabled": true,
  "ip": "10.26.0.2",
  "created_at": 1783980000,
  "updated_at": 1783980000
}
```

没有 IP 时 `ip` 为 `null`。时间字段为 Unix 秒。

删除响应数据：

```json
{
  "peer_removed": true,
  "ip_released": true
}
```

再次删除同一目标返回两项均为 `false`，不会把目标不存在当作错误。

## 公钥输入契约

API 只接受标准 WireGuard 公钥文本：

- 使用标准 Base64 字母表；
- 必须带规范填充；
- 解码结果必须恰为 32 字节；
- 对解码结果重新编码后必须与输入逐字相同。

因此未填充、含空白、错误长度或其他非规范表示都会以业务码 400 拒绝。本模块不额外引入全零或低阶点策略；该安全策略没有在 A1 范围内擅自扩展。

## 一致性与锁边界

每个 `NetworkState` 继续复用模块 2.1/2.2 已有的 `wireguard_ip_update_lock`。以下操作全部在同一把网络锁内完成：

- 创建 peer 并读取可能已经存在的孤立 peer IP；
- 从数据库列出 peer，并在返回前合并运行时 IP；
- 设置 `enabled`、重新读取记录并合并 IP；
- 数据库事务硬删除 peer/IP，成功后同步清理运行时 IP；
- 既有 peer IP 列出、预留、移动和释放。

数据库删除失败时不会提前移除运行时 IP。数据库删除成功后，返回的 `ip_released` 是数据库和运行时实际释放结果的逻辑或，保证重启恢复或历史孤立状态下仍能准确报告。

## 验收范围

- 四个路由均受 JWT 保护，未认证请求返回 HTTP 401。
- 规范 32 字节 Base64 公钥可创建；未填充、空白、错误长度和非法 Base64 被拒绝。
- `enabled` 省略时默认为 `true`；重复设置相同值仍成功并返回当前 peer。
- 同一 peer 重复创建和跨网络复用同一公钥均返回业务码 400。
- peer 列表包含可选 IP，重启后 peer、启停状态和 IP 均保持一致。
- 删除同时移除 peer 和 IP；重复删除幂等。
- `persistence = false` 时创建失败，并明确报告数据库未初始化。
- 删除持久化失败时运行时 IP 保持不变；peer 删除与 peer IP 列出确实共享更新锁。

## 本阶段验证结果

- `cargo fmt --all -- --check`：通过。
- `cargo check --locked --all-targets`：通过，仅保留仓库既有 2 组 `dead_code` 警告。
- `cargo test --locked`：49/49 通过（40 项单元测试、6 项 BoringTun 集成测试、2 项轮换进程测试、1 项真实 peer API 重启测试）。
- `cargo clippy --locked --all-targets -- -A clippy::never_loop`：通过；21 条均为既有提示，本模块新增提示为 0。
- `cargo audit`：扫描 366 个锁定依赖，无漏洞；仅保留允许的既有 `spin 0.9.8` yanked 提示。
- `cargo deny check licenses sources`：`licenses ok, sources ok`。
- `git diff --check`：通过。
- Windows release 构建确认官方 `C:\Program Files\NASM\nasm.exe` 优先于 Strawberry NASM。
- release 产物：`target/release/vnts2.exe`，5,917,184 字节，SHA-256 `AAB73D7C10DD883B12F98E69A4E9AAE9F4AF122FB0E377A326650603FE502989`。

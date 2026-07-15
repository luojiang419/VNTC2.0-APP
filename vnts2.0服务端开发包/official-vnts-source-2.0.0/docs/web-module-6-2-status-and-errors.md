# Web 模块 6.2：后端状态接口与错误语义

## 范围

本模块只增加受认证的服务状态查询，并统一既有 Web API 的 HTTP 状态码与 JSON `code`。不修改前端页面，不改变 WireGuard/VNT 转发、路由、P2P 或持久化数据模型。

## 状态接口

### 请求

`GET /api/status`

接口位于既有认证路由内，支持 6.1 的 HttpOnly Cookie 或 Bearer JWT。未认证请求返回 HTTP 401 和 `code=401`。

### 返回字段

- `version`：服务端包版本。
- `uptime_seconds`：本次 HTTP 管理运行时长。
- `database.persistence_enabled`：配置是否启用持久化。
- `database.ready`：启动时数据库池是否成功初始化。
- `listeners`：Web、VNT TCP、VNT QUIC、VNT WebSocket、服务器互联 QUIC 的监听地址。
- `networks.configured`：配置网络数。
- `networks.total_nodes` / `online_nodes`：所有网络节点总数与在线数。
- `peer_servers.enabled` / `total_connections` / `connected`：服务器互联启用和连接统计。
- `wireguard.configured` / `running` / `listen_addr`：WireGuard 配置与实际运行状态。
- `wireguard.active_peers` / `max_active_peers`：当前活动 peer 与配置容量。

接口不返回管理用户名/密码、JWT/CSRF、WireGuard 私钥/主密钥、公钥身份文件路径、证书私钥路径或数据库路径。

活动 WireGuard peer 直接从现有在线 endpoint 与 sender 映射聚合，不新增第二套生命周期计数器，因此禁用、删除、ConnectionExpired 和停机回收继续使用模块 5.0–5.3 的单一事实来源。

## HTTP 与 JSON 错误契约

`ApiResponse.code` 现在同时决定真实 HTTP 状态：

| HTTP / code | 语义 | 典型场景 |
| --- | --- | --- |
| 200 | 成功 | 查询、创建、更新、幂等删除成功 |
| 400 | 请求参数无效 | IP、掩码、公钥、peer ID 等验证失败 |
| 401 | 未认证或会话失效 | 缺少/失效 Cookie 或 Bearer |
| 403 | 已认证但请求校验失败 | Cookie 写请求 CSRF 失败 |
| 404 | 资源不存在 | 网络或 peer 不存在 |
| 409 | 资源/运行状态冲突 | 重复网络、重复 peer/公钥、在线设备不可删除、被占用网络不可编辑 |
| 429 | 登录来源限速 | 6.1 登录失败封禁 |
| 500 | 未分类内部错误 | 数据库或内部不变量异常 |
| 503 | 组件不可用 | 服务器互联未启用、持久化/运行时未初始化 |

已识别且面向用户的中文验证信息继续返回。英文数据库上下文、SQLite 细节和未分类错误只写服务日志，响应使用稳定的中文通用消息，避免泄露内部实现。

## 设备列表语义修复

旧实现的 `get_device_info()` 把“不存在的网络”和“存在但没有设备”都表现为 `Some([])`，数据库错误也会降级为 `None`。本模块改为 `Result<Option<Vec<_>>>`：

- `Ok(Some([]))`：网络存在但没有设备，HTTP 200。
- `Ok(None)`：网络不存在，HTTP 404。
- `Err(_)`：数据库读取失败，按内部错误映射。

## 文件变更

- `src/http/web_server.rs`：状态响应结构、`/api/status`、HTTP/code 一致响应、服务错误分类及测试。
- `src/main.rs`：把经过启动验证的监听、持久化和容量配置传给 Web 状态层。
- `src/server/control_server/service.rs`：只读 WireGuard 运行状态聚合；设备查询三态语义。
- `tests/wireguard_peer_api.rs`：真实进程状态接口验收，并把旧的 HTTP 200 错误断言更新为 400/409/503。

## 验收标准

- 状态接口必须认证，且不出现密码、JWT、密钥或敏感路径。
- `body.code` 与真实 HTTP 状态一致。
- 参数错误、缺失资源、冲突、不可用和未知内部错误映射稳定。
- WireGuard 活动 peer 统计不引入独立生命周期状态。
- 既有 Cookie/Bearer、WireGuard 管理和 UDP/P2P 集成测试不回退。
- fmt/check/test/clippy/audit/deny/diff/release 全部完成。

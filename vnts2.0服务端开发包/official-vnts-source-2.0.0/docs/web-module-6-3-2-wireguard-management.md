# Web 模块 6.3.2：WireGuard 管理页面

## 目标与边界

本模块在 6.3.1 的完全离线控制台内补齐 WireGuard peer 与保留 IP 管理页面。页面只调用模块 2.2–5.3 已存在的后端接口，不增加数据库表、业务模型或数据面逻辑，也不进入 Windows 服务脚本与 ZIP 交付。

## 页面信息架构

新增顶级路由 `#/wireguard` 和导航入口。页面按网络隔离数据，包含：

- 网络选择器，数据来自受认证的 `/api/networks`；
- peer 列表：Peer ID、规范 Base64 公钥、启用状态、保留 IP、更新时间；
- 新增 peer 弹窗：Peer ID、公钥、初始启用状态；
- 行内启用/禁用；
- 行内 IP 预留与释放；
- peer 删除确认，明确关联 IP 会一并释放；
- 空网络、空列表、加载中和错误状态。

导航和页头改为可换行布局，表格在窄屏使用横向滚动，表单按钮在手机与桌面宽度下保持可操作。

## API 映射

| 页面操作 | 方法与路径 | 请求字段 |
| --- | --- | --- |
| 查询 peer | `GET /api/wireguard/peers?network_code=...` | `network_code` |
| 新增 peer | `POST /api/wireguard/peers` | `network_code`, `peer_id`, `public_key`, `enabled` |
| 启用/禁用 | `PUT /api/wireguard/peers/enabled` | `network_code`, `peer_id`, `enabled` |
| 删除 peer | `DELETE /api/wireguard/peers?...` | `network_code`, `peer_id` |
| 查询保留 IP | `GET /api/wireguard/peer_ips?network_code=...` | `network_code` |
| 预留 IP | `PUT /api/wireguard/peer_ips` | `network_code`, `peer_id`, `ip` |
| 释放 IP | `DELETE /api/wireguard/peer_ips?...` | `network_code`, `peer_id` |

所有写操作继续由公共请求层自动添加 `X-CSRF-Token`，认证 Cookie 仍为 HttpOnly、SameSite=Strict。查询参数使用 `encodeURIComponent`，用户输入在提交前只做首尾空白清理，最终格式与冲突判断仍由后端单一事实来源完成。

## 状态与错误处理

- 切换网络时先清空上一网络的 peer/IP，避免失败请求显示陈旧数据。
- peer 和 IP 两个列表都成功后才一次性更新页面状态。
- 同一页面再次点击导航会刷新；首次进入由 hashchange 单一路径加载，避免重复请求。
- 400 显示“请求参数错误”，用于无效 Base64 公钥或 IPv4。
- 404 显示“资源不存在”，用于不存在的网络或 peer。
- 409 显示“操作冲突”，用于重复 Peer ID、公钥或 IP 占用。
- 503 显示“服务暂不可用”，复用 6.2/6.3.1 的脱敏错误语义。
- 401 清理前端会话，403 由既有 CSRF 契约返回。

## 安全与离线约束

- 没有新增第三方依赖。
- 仍只加载同源的预编译 Vue runtime、Tailwind 输出和 Font Awesome。
- CSP 未放宽，仍无公共 CDN、`unsafe-inline`、`new Function` 或 `eval(`。
- 公钥仅显示为截断文本，完整值放在本地 DOM `title`，不发送到第三方。
- 页面不接触服务端私钥、WireGuard 身份密钥、JWT 或数据库路径。

## 代码范围

- `web-console/src/index.source.html`
  - 新增导航、响应式头部、WireGuard 页面、创建弹窗和交互逻辑。
- `static/assets/app.js`
  - 构建生成的预编译应用。
- `static/assets/app.css`
  - Tailwind 根据新增页面类名重新生成。
- `src/http/web_server.rs`
  - 扩展内嵌控制台契约测试，确认全部 WireGuard API 路径存在。

后端路由、服务层、数据库和 WireGuard 数据面没有修改。

## 验证结果

- `npm ci --ignore-scripts`：通过。
- `npm run build`：通过；最终连续构建关键产物哈希一致。
- `node --check static/assets/app.js`：通过。
- 运行资源扫描：无远程 URL、动态求值或 CSP 退化。
- `npm audit`：0 个漏洞。
- `cargo fmt --check`：通过。
- `cargo check --locked --all-targets`：通过。
- `cargo test --locked`：82/82 通过（68 单元 + 14 集成）。
- `cargo clippy --locked --all-targets -- --cap-lints warn`：通过，仅既有告警。
- `cargo audit`：无漏洞；仅策略允许的 `spin 0.9.8` yanked 警告。
- `cargo deny check licenses sources`：通过。
- `git diff --check`：通过，仅既有 CRLF 提示。
- Windows release：`C:\Program Files\NASM\nasm.exe` 优先时通过。

release 真实进程使用持久化数据库完成：

- 首页、`app.js`、登录：200；
- 无 CSRF 创建 peer：403；
- 无效公钥：400；
- 创建 peer：200；
- 重复 peer：409；
- IP 预留/查询：200；
- peer 启用：200；
- IP 释放：200；
- peer 删除：200；
- 删除后再次操作：404。

无持久化真实进程不暴露可选网络，页面进入空网络状态；503 由既有后端自动化契约覆盖，前端公共请求层已验证包含 503 映射。浏览器技能仍受企业网络策略禁止访问 `127.0.0.1`，本模块没有绕过策略进行可视化 DOM/截图验收。

## 构建产物

- `target/release/vnts2.exe`：7,270,400 字节。
- SHA-256：`64F3E11ACFE9E4BD0E71D29141A29DDFEE3029B217497988B6ABEBD35A6A09AA`。

模块 6.3 至此完成：控制台完全离线、CSP 收紧、状态概览和 WireGuard 管理功能均已内嵌。

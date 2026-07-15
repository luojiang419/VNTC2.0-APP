# Web 模块 6.3.1：离线控制台基础与状态概览

## 目标与边界

本模块把原有依赖公共 CDN、运行时编译模板的单文件控制台迁移为完全离线、随 `vnts2.exe` 内嵌的静态资源，并接入模块 6.2 的 `/api/status`。本模块保留网络、设备、服务器管理功能及 Cookie/CSRF 契约，不实现 WireGuard peer/IP 管理页面；后者属于 6.3.2。

## 只读审计结论

原 `static/index.html` 共约 64 KiB、1271 行，包含：

- `https://cdn.tailwindcss.com`；
- `https://unpkg.com/vue@3/dist/vue.global.prod.js`；
- `https://cdnjs.cloudflare.com/.../font-awesome/...`；
- 内联样式、内联 Vue 应用脚本和一个内联 `canvas style`；
- 网络、设备、服务器三个页面；
- `/api/login`、`/api/logout`、`/api/networks`、`/api/devices`、`/api/peer_servers` 调用；
- 无概览页面、无 `/api/status` 消费、无 WireGuard 管理页面。

后端已经提供受认证的 `/api/status`、WireGuard peer/IP API 和统一 400/404/409/503 语义。现有 CSP 为 CDN 与 `unsafe-inline` 放行，但不允许 `unsafe-eval`；直接把 Vue 全量浏览器构建复制到本地仍会依赖运行时模板编译，与 CSP 目标不相容。

## 实现方案

### 1. 可复现的离线前端构建

新增 `web-console` 源目录并固定依赖版本：

- Vue/runtime 与 compiler-dom `3.5.17`；
- Tailwind CSS `3.4.17`；
- Font Awesome Free `6.7.2`。

`npm run build` 执行以下工作：

1. 从 `src/index.source.html` 提取模板和现有 Composition API 逻辑；
2. 使用 `@vue/compiler-dom` 在构建阶段生成 render 函数；
3. 只嵌入 `vue.runtime.global.prod.js`，浏览器端不再编译模板，也不需要 `eval`；
4. Tailwind 扫描源模板并输出最小化 CSS；
5. 复制 Font Awesome CSS、字体及三项第三方许可证；
6. 生成固定文件名的 `static/index.html`、`static/assets/*`，由既有 `RustEmbed` 自动打包进 exe。

`package-lock.json` 固化完整依赖树；生成文件使用固定路径，连续构建的 SHA-256 一致。

### 2. 运行概览

新增 `#/status` 默认页面，登录后展示：

- 服务版本、Web 管理运行时长；
- 持久化是否启用、数据库是否就绪；
- Web/VNT TCP/VNT QUIC/VNT WebSocket/服务器互联监听地址；
- 配置网络、节点总数、在线节点数；
- 服务器互联连接总数与已连接数；
- WireGuard 配置、运行、监听地址、活动 peer 和容量。

状态页面只消费模块 6.2 已定义的数据，不增加后端业务模型，也不展示密钥、认证信息或文件路径。

### 3. API 错误语义

公共请求层同时检查真实 HTTP 状态与 JSON `code`：

- 400：`请求参数错误`；
- 404：`资源不存在`；
- 409：`操作冲突`；
- 503：`服务暂不可用`；
- 401：清理前端会话并回到登录态。

后端返回的脱敏 `msg` 仍作为详细说明展示。非 GET 请求继续从 `sessionStorage` 读取登录响应中的 CSRF 值，发送 `X-CSRF-Token`，浏览器认证仍由 HttpOnly、SameSite=Strict Cookie 完成。

### 4. CSP 收紧

最终策略仅允许同源脚本、样式、字体和连接：

```text
default-src 'self'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; font-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'
```

公共 CDN、`unsafe-inline`、运行时模板编译和内联样式均已移除。

## 文件清单

- `web-console/package.json`
- `web-console/package-lock.json`
- `web-console/tailwind.config.cjs`
- `web-console/scripts/build-console.mjs`
- `web-console/src/index.source.html`
- `web-console/src/app.css`
- `static/index.html`
- `static/assets/app.js`
- `static/assets/app.css`
- `static/assets/vue.runtime.global.prod.js`
- `static/assets/fontawesome.min.css`
- `static/webfonts/*`
- `static/licenses/*`
- `src/http/web_security.rs`
- `src/http/web_server.rs`

## 验证结果

- `npm run build`：通过；连续两次关键产物哈希一致。
- `node --check static/assets/app.js`：通过。
- 静态运行资源扫描：无公共 URL、`new Function`、`eval(` 或远程 CSS URL。
- `npm audit`：0 个漏洞。
- `cargo fmt --check`：通过。
- `cargo check --locked --all-targets`：通过。
- `cargo test --locked`：82/82 通过（新增 1 个离线控制台/CSP 契约测试）。
- `cargo clippy --locked --all-targets -- --cap-lints warn`：通过；仅既有告警。
- `cargo audit`：无漏洞；仅策略允许的 `spin 0.9.8` yanked 警告。
- `cargo deny check licenses sources`：通过。
- `git diff --check`：通过，仅既有 CRLF 提示。
- Windows release：在 `C:\Program Files\NASM\nasm.exe` 优先时通过。
- release 真实进程：首页、`app.js`、登录和 `/api/status` 均为 200；无 CSRF 的 Cookie 写请求为 403，携带 CSRF 为 200；状态响应不含敏感字段。
- `target/release/vnts2.exe`：7,241,728 字节。
- SHA-256：`87FABBD2BEBFC5217DF252CE98D73ECE0CAAAB5EBE33FF873F2B701E48AE7805`。

浏览器技能尝试访问本机控制台时被企业网络策略禁止访问 `127.0.0.1`，因此本轮无法执行可视化 DOM/截图验收；未绕过该策略。HTTP 真实进程、嵌入资源和 CSP 契约测试均已完成。

## 后续模块 6.3.2

在现有离线壳内新增 WireGuard 管理页面：按网络列出/创建/启停/删除 peer，列出/预留/释放 peer IP，并对 400/404/409/503 做页面级反馈。完成后再做浏览器可视化验收（若环境策略允许），不进入 Windows 服务脚本或 ZIP 打包。

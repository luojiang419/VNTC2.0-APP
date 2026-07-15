# Web 模块 6.1：生产安全基线

## 范围

本模块只收紧 VNTS 内嵌 Web 管理端的生产安全边界，不新增业务页面、不实现远程 TLS、不制作 Windows 安装包。现有网络、设备、服务器互联和 WireGuard 管理 API 的业务模型保持不变。

## 冻结设计

1. Web 管理端默认监听 `127.0.0.1:29871`。本阶段拒绝任何非回环监听；远程管理必须留到带 TLS 或可信反向代理的后续模块。
2. 首次无配置启动生成 24 位随机管理密码并写入 `config.toml`。显式配置启用 Web 时，用户名和密码必须非空，密码不能为 `admin` 或等于用户名；不再限制密码长度。
3. 浏览器使用 `HttpOnly; SameSite=Strict; Path=/; Max-Age=86400` 会话 Cookie。前端不再把 JWT 写入 `localStorage`。
4. Cookie 会话的 POST、PUT、PATCH、DELETE 等非安全方法必须携带与 JWT 声明一致的 `X-CSRF-Token`；Bearer 调用继续兼容且不要求 CSRF，供现有自动化客户端使用。
5. 登录失败按来源 IP 计数：5 分钟内 5 次失败后封禁 15 分钟，最多跟踪 4096 个来源；成功登录清除该来源状态。
6. 删除开放 CORS。API 响应增加 `no-store`，所有响应增加 nosniff、frame deny、referrer、permissions、COOP 和 CSP 等安全头。
7. 静态资源只从编译期 `RustEmbed` 读取，拒绝反斜杠、`.` 和 `..` 路径段，不再读取运行目录下可被替换的 `static` 文件。

## 认证流程

```text
浏览器登录 -> 校验来源限速与口令 -> 签发 24 小时 HS256 JWT
            -> JWT 写入 HttpOnly Cookie
            -> CSRF 随登录 JSON 返回并仅存 sessionStorage

浏览器读请求 -> Cookie JWT -> 鉴权通过
浏览器写请求 -> Cookie JWT + X-CSRF-Token -> 双重校验通过
自动化请求   -> Authorization: Bearer <JWT> -> 保持原有兼容
```

Bearer 优先于 Cookie，避免自动化客户端同时带浏览器 Cookie 时被意外切换到 CSRF 语义。JWT 解码失败、缺少凭证和过期凭证统一返回 401，不向客户端泄露解析细节；CSRF 失败返回 403。

## 安全头与过渡约束

当前旧页面仍从 Tailwind、Vue 和 Font Awesome CDN 加载资源，因此 6.1 的 CSP 暂时允许这三个既有来源和内联脚本/样式。模块 6.3 将把前端资产完全内嵌并进一步移除 CDN 与 `unsafe-inline`。本阶段已经移除任意源 CORS，且 `connect-src` 仅允许同源。

## 文件变更

- `src/http/web_security.rs`：会话鉴权、CSRF、登录限速、常量时间比较和安全头。
- `src/http/web_server.rs`：登录/退出接口、安全中间件、纯内嵌静态资源、真实来源地址注入。
- `src/utils/config.rs`：回环默认值、首次随机密码、Web 配置 fail-closed 校验。
- `src/main.rs`：启动前集中验证 Web 配置，删除 `admin/admin` 回退。
- `static/index.html`：浏览器改用 Cookie 与 sessionStorage CSRF，不再持久化 JWT。
- `Cargo.toml`、`Cargo.lock`：移除已不再使用的 `tower-http` CORS 依赖。

## 验收标准

- 非回环监听、缺失/弱密码拒绝启动。
- 浏览器登录设置 HttpOnly/Strict Cookie；Cookie 写请求缺少 CSRF 时返回 403。
- Bearer 写请求保持兼容。
- 连续错误登录触发来源封禁。
- 无 `Access-Control-Allow-Origin: *`，API 为 `Cache-Control: no-store`。
- 本地 `static` 覆盖和父目录路径读取均不可用。
- `cargo fmt/check/test/clippy/audit/deny`、`git diff --check` 与 Windows release 构建全部通过。

## 明确不在本模块内

- 完全离线、无 CDN 的 Web 控制台及 WireGuard 页面（6.3）。
- 统一业务错误码和运行状态接口（6.2）。
- Windows 服务安装、卸载、诊断脚本和交付 ZIP（6.4–6.5）。
- 面向公网的原生 HTTPS 或反向代理信任模型。

# Web 模块 6.3.2.1：WireGuard Peer 一键生成交互

## 目标

新增 WireGuard Peer 时不再要求管理员记忆或手工输入44位公钥。默认流程只填写易读的设备名称，由模块4.2接口生成密钥对、创建 Peer 并自动分配虚拟 IP。

## 两种添加方式

### 一键生成（默认）

1. 输入设备名称（作为 `peer_id`）。
2. 保持“一键生成”选中并提交。
3. 前端调用 `POST /api/wireguard/peers/generated`。
4. 成功后弹窗不关闭，切换到一次性客户端配置保存页。
5. 用户下载 `.conf`、扫码导入或复制保存后，明确确认才能完成并刷新 Peer 列表。

### 粘贴已有公钥

高级用户可切换到“粘贴已有公钥”，继续使用原 `POST /api/wireguard/peers` 接口。原有44位规范 Base64 公钥契约保持不变。

## 私钥防丢失边界

- 生成成功后，点击遮罩或普通关闭动作不会关闭弹窗。
- 私钥只保存在当前 Vue 响应式内存对象中，不写 `localStorage` 或 `sessionStorage`。
- 复制操作优先使用安全上下文的 Clipboard API，并保留旧浏览器降级路径。
- “已保存，完成”必须先勾选明确确认项，随后清空前端密钥引用。
- “放弃并删除 Peer”需要再次确认，并通过 DELETE API 清理刚创建的 Peer 与 IP，成功后才清空密钥并关闭。
- 页面刷新或浏览器进程终止后无法恢复私钥；模块3已提供完整配置文件下载和离线二维码，减少人工处理。

## 离线构建

源文件为 `web-console/src/index.source.html`。执行 `npm run build` 后生成：

- `static/assets/app.js`：Vue 模板预编译和应用逻辑；
- `static/assets/app.css`：Tailwind 扫描后压缩样式；
- `static/assets/qrcode.min.js`：本地打包的二维码运行时；
- `static/index.html`：仅引用本地静态资源。

服务端通过 Rust Embed 打包上述产物，不依赖 CDN。

## 验收

- Vue 模板和生成 JavaScript 语法检查通过。
- 默认方式为一键生成，手工公钥输入只在高级方式出现。
- 生成成功页包含一次性警告、复制私钥、保存确认、放弃删除。
- 编译后的应用包含生成、删除和原手工创建接口。
- 静态资源连续两次构建哈希一致。
- 全量 Rust 测试通过。

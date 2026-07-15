# Web 模块 6.3.2.2：WireGuard 客户端配置与二维码

## 公网 Endpoint 配置

服务端监听地址通常是 `0.0.0.0:51820`，不能直接写入客户端配置。部署方必须显式设置外部设备实际可访问的地址：

```toml
wireguard_bind = "0.0.0.0:51820"
wireguard_public_endpoint = "vpn.example.com:51820"
```

支持域名、IPv4和方括号IPv6，例如：

```toml
wireguard_public_endpoint = "203.0.113.10:51820"
wireguard_public_endpoint = "[2001:db8::10]:51820"
```

配置校验拒绝空白、换行、协议前缀、路径、查询、片段、用户信息、未指定/组播地址、无端口和零端口，防止配置注入和无效 Endpoint。

## 生成的客户端配置

浏览器只使用生成接口当前响应中的数据，在内存中拼装：

```ini
[Interface]
PrivateKey = <客户端私钥>
Address = 10.26.0.2/32

[Peer]
PublicKey = <服务端公钥>
AllowedIPs = 10.26.0.0/24
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
```

- `Address` 使用自动预留的单地址 `/32`。
- `AllowedIPs` 使用 Peer 所属 VNTS 虚拟网段。
- `PersistentKeepalive = 25` 兼容 NAT 后客户端。
- 文件名固定带 `wireguard-` 前缀，只保留安全的 ASCII 文件名字符；中文名称回退到虚拟 IP。

## 导出方式

- 复制完整配置；
- 下载 UTF-8 `.conf`；
- 使用 WireGuard 移动端扫描二维码导入。

二维码内容与 `.conf` 完全一致，包含客户端私钥，页面明确提示不得截图分享。配置、二维码和私钥均不写浏览器持久化存储，也不发送到额外 API。

## 离线依赖

- `qrcode 1.5.4`：二维码编码；
- `esbuild 0.28.1`：构建时把浏览器入口打包为 `static/assets/qrcode.min.js`；
- `qrcode` 和实际打包依赖 `dijkstrajs` 的许可证复制到 `static/licenses/`。

运行时只加载同源静态资源，不访问 CDN。npm 安全审计为0项漏洞。

## 验收

- 公网 Endpoint 单元测试覆盖域名、IPv4、IPv6及注入输入。
- 集成测试确认缺少 Endpoint 时不创建 Peer，配置完整时响应返回 Endpoint。
- QR 浏览器包能离线初始化并生成矩阵。
- Vue/Tailwind/QR 连续构建哈希一致。
- Rust Embed 契约确认脚本、许可证和配置导出逻辑已嵌入。
- 全量测试通过。

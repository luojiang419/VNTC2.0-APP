# WireGuard 模块 4.3：一键配置发布交付

## 发布范围

本次 Windows x64 离线包包含 WireGuard Peer 一键生成能力：

- 服务端生成标准 X25519 客户端密钥并自动分配虚拟 IP；
- 公网 Endpoint 启动校验；
- 浏览器一次性展示完整 WireGuard `.conf`；
- 支持复制、下载和离线二维码导入；
- 保留高级模式，可录入客户端已有的标准 44 字符 WireGuard 公钥。

## 使用前提

在 `config.toml` 中启用 WireGuard，并提供客户端实际可访问的地址：

```toml
wireguard_master_key_file = "wireguard-master.key"
wireguard_bind = "0.0.0.0:51820"
wireguard_public_endpoint = "vpn.example.com:51820"
```

`wireguard_public_endpoint` 支持 `域名:端口`、`IPv4:端口` 或 `[IPv6]:端口`。未配置或配置非法时，一键生成接口会在生成私钥和写入数据库之前拒绝请求。

## 离线包内容

发布包：`windows-deploy/dist/vnts2-2.0.0-windows-x64.zip`

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `vnts2.exe` | 7,345,664 | `4793E6B9FEC7E531B6C7581DACBF4EF9CFBD2BF43D18F90EB09CF8A0A41F162A` |
| `VNTS2-Manager.exe` | 36,864 | `C0E582E55A51F98D6492AE88878AF10EF0675203EF046AEB0D1F3DA9DFAB5F33` |
| `vnts2-2.0.0-windows-x64.zip` | 3,864,732 | `EE72590D39A82DA19DE61378C4C962EE46B38968C26EAE4983E5C93E972945AD` |

ZIP 同目录的 `.sha256` 文件提供外部校验值；包内 `MANIFEST.json` 和 `SHA256SUMS.txt` 提供逐文件校验。

## 许可证与安全

- `qrcode 1.5.4` 与 `dijkstrajs` 的许可证已包含在包内 `licenses/`。
- 客户端私钥和完整配置不会写入浏览器持久化存储。
- 依赖漏洞、许可证和来源审计均通过。
- 当前产物没有正式 Authenticode 签名；生产分发前如需消除 Windows 未知发布者提示，必须使用用户提供的正式 OV/EV 代码签名证书。

## 验收摘要

- Rust 测试：88/88。
- Windows 发布与 GUI 契约：3/3 组通过。
- 真实 ZIP 可重复构建。
- 正式服务未升级，仍运行旧版本；发布产物仅生成在开发区，是否部署由管理员另行决定。

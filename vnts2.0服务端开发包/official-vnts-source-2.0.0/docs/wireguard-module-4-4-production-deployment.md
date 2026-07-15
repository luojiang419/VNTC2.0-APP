# WireGuard 模块 4.4：正式服务部署

## 部署结论

WireGuard 一键生成配置版本已部署到正式 Windows 服务。部署只替换程序，现有配置、数据库、证书和服务注册信息均保留。

## 正式程序

| 项目 | 部署前 | 部署后 |
| --- | --- | --- |
| 路径 | `C:\ProgramData\VNTS2\vnts2.exe` | 不变 |
| 字节 | 7,278,592 | 7,345,664 |
| SHA-256 | `BB2762B524B32527A79D17C9EC2FFF0C7CDD7B170D0156DB8BF3D4C9DDA93296` | `4793E6B9FEC7E531B6C7581DACBF4EF9CFBD2BF43D18F90EB09CF8A0A41F162A` |

正式配置部署前后 SHA-256 均为：

```text
6CF6E349EC1396F11437687350F50982680A0DDB65593089A77F17C6461E6950
```

## 回滚备份

- 一致性备份：`C:\ProgramData\VNTS2\.backups\pre-wireguard-oneclick-20260714-225713-989`
- 更新脚本 EXE 备份：`C:\ProgramData\VNTS2\.backups\vnts2.exe.pre-update-20260714-225726-826.bak`

一致性备份在服务停止状态下创建，包含旧 EXE、配置、数据库和 TLS 证书/私钥，并经过逐文件哈希验证。备份目录未向普通用户开放。

## 运行验收

- 服务状态：Running，自动启动，LocalSystem。
- 部署后 PID：24956。
- 官方诊断：0 失败、0 警告。
- 数据库：Ready，可读取现有网络和 WireGuard Peer 列表。
- 新 Web 控制台：首页、应用脚本、离线二维码资源均为 HTTP 200。
- 监听：TCP/UDP 2222，Web 仅回环地址 29871。
- 最近日志没有 ERROR、panic 或 failed。

## 当前 WireGuard 状态

正式配置仍未启用 WireGuard，因此：

- `wireguard.configured = false`
- `wireguard.running = false`
- 一键生成接口返回 503，不产生私钥或数据库记录

这证明新接口已经部署并保持失败关闭。要真正生成客户端配置，下一阶段需要准备 32 字节主密钥文件，设置 `wireguard_bind` 和真实的 `wireguard_public_endpoint`，然后执行带回滚保护的配置更新与运行时验收。

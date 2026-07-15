# VNTS 2.0 增强控制台

面向高配置 Windows 主机的 Flutter 桌面控制台。它与轻量版 `VNTS2-Manager.exe` 并存，共享同一个 VNTS2 Windows 服务和便携 `data` 目录。

当前版本已完成真实仪表盘、服务运维与认证、网络、设备、WireGuard、互联服务器、日志和结构化配置管理。增强发布包已将控制台、`vnts2.exe`、便携 `data` 和运维脚本整合：完整解压后直接运行 `VNTS2-Console.exe`，会自动创建首次配置、安装并启动同目录服务，不再要求用户点击“安装”。

首次新建配置时，初始化脚本只生成随机的一次性引导凭据并把 API 绑定到增强版独立端口 `127.0.0.1:39871`；增强版默认注册独立的 `vnts2-console` 服务并使用隧道端口 `39872`。控制台随即显示全屏首次设置门禁，管理员必须先设置自己的账号和密码才能进入业务界面。增强版只使用自身解压目录中的 `data`，不会读取、迁移或覆盖轻量版数据。密码不再限制长度，但不能为空、不能为 `admin`、不能与账号相同。已有增强版配置、数据库、密钥、日志和凭据保持不变。

普通启动、会话失效、手动锁定和自动锁定都会进入同一全屏登录门禁。默认无操作 2 小时后锁定，默认快捷键为 `Ctrl+Shift+L`；可在“设置 → 安全与隐私”修改锁定时长、快捷键和管理员凭据。凭据修改后立即重启服务、清除内存 Cookie/CSRF 并强制重新登录。

## 工程入口

- `lib/main.dart`：最小启动入口。
- `lib/app/bootstrap.dart`：应用初始化边界。
- `lib/app/app.dart`：根应用与全局主题入口。
- `lib/features/dashboard`：真实资源、累计流量、固定容量趋势、拓扑、监听器与告警。
- `lib/features/networks`：网络与设备管理。
- `lib/features/wireguard`：Peer、IP 与一次性配置二维码。
- `lib/features/peer_servers`：出入站互联服务器状态与管理。
- `lib/features/logs`：受限本地日志读取、筛选、复制与导出。
- `lib/features/service_control`：便携 Windows 服务控制、诊断与安全 API 登录。
- `lib/features/settings`：主题、采样间隔、安全与隐私、带备份的结构化服务配置。

## 本地验证

```powershell
D:\APPdata\flutter\bin\flutter.bat pub get
D:\APPdata\flutter\bin\flutter.bat analyze
D:\APPdata\flutter\bin\flutter.bat test
D:\APPdata\flutter\bin\flutter.bat build windows --release
```

Release 主程序输出为 `build/windows/x64/runner/Release/VNTS2-Console.exe`。

完整增强发布包从服务端部署目录生成：

```powershell
& 'D:\Myproject\vnt2.0\vnts2.0服务端开发包\windows-deploy\build-vnts2-console-package.ps1'
```

输出目录为 `windows-deploy/dist/vnts2-console-2.0.0-windows-x64`，并生成同名 ZIP、外部 SHA-256、包内清单和逐文件哈希。

真实零安装回归会从无服务、无配置的全新临时目录启动 GUI，验证自动安装/启动、首次设置标记、随机引导凭据、短密码生效、旧引导凭据失效与卸载清理：

```powershell
& 'D:\Myproject\vnt2.0\vnts2.0服务端开发包\windows-deploy\tests\windows-console-zero-install-smoke.ps1' `
  -ZipPath 'D:\Myproject\vnt2.0\vnts2.0服务端开发包\windows-deploy\dist\vnts2-console-2.0.0-windows-x64.zip'
```

# VNTS 2.0 Windows 部署目录

这个目录用于放置 Windows 版本的 `vnts2` 服务端可执行文件、配置文件和服务管理脚本。

## 目录内容

- `vnts2.exe`
  - Windows 版服务端二进制
- `config.toml`
  - 默认服务端配置
- `install-vnts2-service.ps1`
  - 安装并注册 Windows 服务
- `start-vnts2-service.ps1`
  - 启动 Windows 服务
- `stop-vnts2-service.ps1`
  - 停止 Windows 服务
- `uninstall-vnts2-service.ps1`
  - 卸载 Windows 服务

## 前台调试运行

在当前目录执行：

```powershell
.\vnts2.exe --conf .\config.toml
```

说明：

- 进程会自动把工作目录切到 `config.toml` 所在目录。
- 日志默认输出到 `.\logs\vnts2.log`。
- 若 `config.toml` 中启用了 `web_bind`，内置 Web 管理端也会一起启动。

## 安装为 Windows 服务

请使用管理员 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-vnts2-service.ps1
```

默认服务名为 `vnts2`，启动类型为 `Automatic`。

安装完成后可在“服务”管理器中看到 `VNTS 2.0 Service`，也可以使用脚本控制：

```powershell
.\start-vnts2-service.ps1
.\stop-vnts2-service.ps1
.\uninstall-vnts2-service.ps1
```

## Web 控制面板（可选）

如果本机有可用 Python，可以在 `..\web-ui-source\` 目录下启动控制面板，并显式指定 Windows 模式：

```powershell
$env:VNT_SERVICE_PLATFORM = "windows"
$env:VNT_SERVICE_NAME = "vnts2"
$env:VNT_CONFIG_PATH = "$PSScriptRoot\config.toml"
$env:VNT_LOG_PATH = "$PSScriptRoot\logs\vnts2.log"
python ..\web-ui-source\server.py
```

默认监听地址仍为 `0.0.0.0:2223`。

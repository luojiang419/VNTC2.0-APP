# VNTS / VNTC 2.0 Control Panels

一个零依赖的 VNT 2.0 管理项目，包含两套风格统一的控制面板：

- `VNTS 2.0` 服务端控制台
- `VNTC 2.0` 客户端控制台

## 功能

### VNTS 服务端面板

- 启动、停止、重启 `vnts2.service`
- 编辑 `/root/vnts2/config.toml` 常用参数
- 直接修改原始 TOML 高级配置
- 实时查看 `journalctl` 日志
- 自动为配置文件创建备份

### VNTC 客户端面板

- 启动、停止、重启 `vntc2.service`
- 编辑 `/root/vntc2.0/config.toml` 常用参数
- 查看 `vnt2_ctrl` 返回的虚拟 IP、连接状态、对端列表与路由信息
- 直接修改原始 TOML 高级配置
- 实时查看 `journalctl` 日志
- 自动为配置文件创建备份

## 设计目标

- 不依赖 `pip`、`npm`、数据库
- 适合直接部署到 Ubuntu 服务器
- 默认适配你当前的目录结构：
  - `VNTS`: `/root/vnts2`
  - `VNTC`: `/root/vntc2.0`

## 目录结构

```text
.
├── client_server.py
├── server.py
├── static
│   ├── app.js
│   ├── index.html
│   └── styles.css
├── static_client
│   ├── app.js
│   ├── index.html
│   └── styles.css
├── deploy
│   ├── vnt-panel.service.example
│   ├── vntc-panel.service.example
│   └── vntc2.service.example
├── tests
│   ├── test_client_panel.py
│   └── test_panel.py
├── vnt_panel
│   ├── auth.py
│   ├── configuration.py
│   ├── settings.py
│   ├── system.py
│   └── web.py
├── vnts2.0
│   └── linux
│       ├── DEPLOY.md
│       ├── config.toml
│       ├── install.sh
│       ├── vnts2
│       └── vnts2.service
├── vntc_panel
    ├── configuration.py
    ├── runtime.py
    ├── settings.py
    └── web.py
└── vntc2.0
    └── linux
        ├── DEPLOY.md
        ├── config.toml
        ├── install.sh
        ├── vnt2_cli
        ├── vnt2_ctrl
        ├── vnt2_web
        └── vntc2.service
```

## Linux 部署包

为了方便后续快速部署到其他服务器，仓库里额外整理了两套可直接复用的 Linux 部署包：

- [vnts2.0/linux](/mnt/c/Users/jiang/Documents/New%20project%203/vnts2.0/linux)
- [vntc2.0/linux](/mnt/c/Users/jiang/Documents/New%20project%203/vntc2.0/linux)

每个目录里都包含：

- 当前正在使用的 Linux 二进制
- 当前运行版配置文件
- systemd 服务文件
- 一键安装脚本
- 对应的部署文档

## 运行

服务端面板：

```bash
python3 server.py
```

客户端面板：

```bash
python3 client_server.py
```

默认监听：

- `VNTS 面板`: `0.0.0.0:2223`
- `VNTC 面板`: `0.0.0.0:2224`

默认登录账号：

- 用户名：`luojiang`
- 密码：`luojiang`

登录后可直接在 Web UI 的“设置”页面修改账号和密码。

## 环境变量

### VNTS 服务端面板

```bash
VNT_PANEL_HOST=0.0.0.0
VNT_PANEL_PORT=2223
VNT_PANEL_USERNAME=luojiang
VNT_PANEL_PASSWORD=luojiang
VNT_PANEL_SECRET=replace-with-a-random-secret
VNT_PANEL_AUTH_FILE=/opt/vnt-panel/data/vnts-auth.json
VNT_PANEL_SESSION_TTL=43200
VNT_SERVICE_PLATFORM=linux
VNT_LOG_PATH=/root/vnts2/logs/vnts2.log

VNT_SERVICE_NAME=vnts2.service
VNT_CONFIG_PATH=/root/vnts2/config.toml
VNT_CONFIG_BACKUP_DIR=/root/vnts2/.backups
```

### VNTC 客户端面板

```bash
VNTC_PANEL_HOST=0.0.0.0
VNTC_PANEL_PORT=2224
VNTC_PANEL_USERNAME=luojiang
VNTC_PANEL_PASSWORD=luojiang
VNTC_PANEL_SECRET=replace-with-a-random-secret
VNTC_PANEL_AUTH_FILE=/opt/vnt-panel/data/vntc-auth.json
VNTC_PANEL_SESSION_TTL=43200

VNTC_SERVICE_NAME=vntc2.service
VNTC_CONFIG_PATH=/root/vntc2.0/config.toml
VNTC_CONFIG_BACKUP_DIR=/root/vntc2.0/.backups
VNTC_CTRL_BINARY=/root/vntc2.0/vnt2_ctrl
```

## systemd 模板

服务端面板：

- [deploy/vnt-panel.service.example](/mnt/c/Users/jiang/Documents/New%20project%203/deploy/vnt-panel.service.example)

客户端核心服务与客户端面板：

- [deploy/vntc2.service.example](/mnt/c/Users/jiang/Documents/New%20project%203/deploy/vntc2.service.example)
- [deploy/vntc-panel.service.example](/mnt/c/Users/jiang/Documents/New%20project%203/deploy/vntc-panel.service.example)

## 安全说明

- 这两套控制面板都需要执行 `systemctl` 和 `journalctl`，最省事的方式是以 `root` 运行
- 在 Windows 上运行 `VNTS` 面板时，请额外设置：
  - `VNT_SERVICE_PLATFORM=windows`
  - `VNT_SERVICE_NAME=vnts2`
  - `VNT_CONFIG_PATH=<windows-deploy\\config.toml>`
  - `VNT_LOG_PATH=<windows-deploy\\logs\\vnts2.log>`
- 如果面板暴露在公网，请至少做下面三件事：
  - 修改默认账号密码
  - 用防火墙限制来源 IP
  - 反向代理到 HTTPS

## 开发校验

```bash
python3 -m unittest discover -s tests -p "test_*.py"
python3 -m py_compile server.py client_server.py vnt_panel/*.py vntc_panel/*.py
```

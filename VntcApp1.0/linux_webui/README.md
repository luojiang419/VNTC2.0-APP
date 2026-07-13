# VNTC Linux WebUI

VNTC 的无界面 Linux 服务与响应式浏览器管理端。后端直接接入 `vnt-core`，支持 Linux TUN、P2P/Relay 状态、实时流量、多配置档案、设置、日志与备份恢复。WebUI 保留与软件版一致的仪表盘、链接状态、配置、设置和关于五项 Linux 功能。

## 配置与启动

```bash
cargo run --release -- --config config.example.json --check-config
cargo run --release -- --config config.example.json
```

Linux TUN 需要 root 或 `CAP_NET_ADMIN`。启动后访问 `http://127.0.0.1:18080/`。

默认只允许监听回环地址。监听非回环地址时，`web.access_token` 必须设置为非空值。远程管理优先使用 SSH 隧道：

```bash
ssh -L 18080:127.0.0.1:18080 user@linux-server
```

## 数据文件

所有状态与主配置放在同一目录：

- `config.json`：监听、访问令牌、自动连接和当前运行配置。
- `profiles.json`：多配置档案与默认配置；首次启动从旧单配置自动迁移。
- `settings.json`：主题模式、主题色与自动刷新间隔。

WebUI 完整备份不包含访问令牌，避免把管理凭据带入导出文件。

## 发行包安装

预编译包面向 Ubuntu 24.04+/glibc x86_64：

```bash
sudo ./install.sh
```

安装器创建无登录权限的 `vntc` 用户，并通过 systemd 授予 `CAP_NET_ADMIN`、`CAP_NET_RAW` 与 `/dev/net/tun` 权限。

```bash
sudo ./uninstall.sh          # 保留配置
sudo ./uninstall.sh --purge  # 删除配置和状态
```

Docker 部署与离线导入见 `docker/README.md`。容器使用 Compose `restart: unless-stopped` 管理宿主自启，不会从容器内替换自身或修改宿主策略。

## HTTP API

- 运行：`/api/status`、`/api/start`、`/api/stop`、`/api/peers`、`/api/routes`、`/api/traffic`。
  - `/api/status.uptime_seconds` 仅在 `phase=running` 时返回后端 VNT 实例的真实运行秒数；连接中、停止和异常状态返回 `null`。
- 兼容单配置：`GET/PUT /api/config`。
- 多配置：`/api/profiles`、复制、默认、连接、导入和导出子路由。
- 管理：`/api/settings`、`PUT /api/settings/access-token`、`/api/logs`、`/api/backup`、`/api/backup/restore`、`/api/data/clear`、`/api/about`。
- 存活检查：`GET /api/health`，无需鉴权。

启用访问令牌时，除健康检查和静态页面外，API 均需发送：

```text
Authorization: Bearer <access_token>
```

# VNTS 2.0 Linux 部署说明

本部署包适用于使用 systemd 的 Linux x86_64 发行版（Ubuntu 22.04/24.04、Debian 12、Rocky Linux 9 等）。目标机不需要 Rust、Node.js 或数据库服务。

## 1. 安装

校验并解压：

```bash
sha256sum -c vnts2-2.0.0-linux-x86_64.tar.gz.sha256
tar -xzf vnts2-2.0.0-linux-x86_64.tar.gz
cd vnts2-2.0.0-linux-x86_64
sha256sum -c SHA256SUMS
sudo ./install.sh
```

安装器会执行以下操作：

- 安装程序到 `/opt/vnts2/vnts2`；
- 创建低权限系统账号 `vnts2`；
- 创建实际配置 `/var/lib/vnts2/config.toml`，并提供标准入口 `/etc/vnts2/config.toml`（符号链接）；
- 将数据库、证书和日志保存到 `/var/lib/vnts2`；
- 首次安装自动生成 `/var/lib/vnts2/wireguard-master.key`，并启动 WireGuard UDP 51820；
- 注册并启动 `vnts2.service`；
- 首次安装时生成随机 Web 管理密码，保存到 `/etc/vnts2/admin-password.txt`，不会打印到日志。

重复安装会更新二进制，但保留现有配置，并创建带 UTC 时间戳的配置备份。

## 2. 登录 Web 控制台

出于安全考虑，控制台只监听服务器回环地址 `127.0.0.1:29871`。先读取账号密码：

```bash
sudo cat /etc/vnts2/admin-password.txt
```

账号固定为 `admin`。远程电脑通过 SSH 隧道访问：

```bash
ssh -L 29871:127.0.0.1:29871 user@server-ip
```

然后打开 `http://127.0.0.1:29871`。不要直接把无 TLS 的管理端口暴露到公网。

## 3. 防火墙端口

默认业务端口：

| 用途 | 协议 | 端口 | 是否需要放行 |
|---|---|---:|---|
| VNT TCP/WSS | TCP | 29872 | 是 |
| VNT QUIC | UDP | 29872 | 是 |
| Web 管理 | TCP | 29871 | 否，仅本机/SSH 隧道 |
| WireGuard | UDP | 51820 | 是，首次安装默认启用 |
| 多服务器互联 | UDP | 29873 | 启用后放行 |

Ubuntu UFW 示例：

```bash
sudo ufw allow 29872/tcp
sudo ufw allow 29872/udp
sudo ufw allow 51820/udp
```

## 4. 配置 WireGuard

首次安装会自动生成严格 32 字节、权限为 `0600` 的主密钥，并写入以下默认配置：

```toml
wireguard_master_key_file = "/var/lib/vnts2/wireguard-master.key"
wireguard_bind = "0.0.0.0:51820"
```

未显式设置 `wireguard_public_endpoint` 时，服务会根据本机默认路由选择可连接地址，并排除回环、链路本地和 `198.18.0.0/15` 基准测试网段。服务器有公网域名或位于 NAT 后方时，建议在 `[custom_nets]` 之前显式覆盖：

```toml
wireguard_public_endpoint = "vpn.example.com:51820"
```

修改后重启并诊断：

```bash
sudo systemctl restart vnts2
sudo ./diagnose.sh
```

主密钥、`network_control.db` 和配置属于同一恢复集合，备份与恢复时必须保持一致。

## 5. 运维、升级与备份

```bash
sudo ./status.sh
sudo ./diagnose.sh
sudo systemctl restart vnts2
sudo journalctl -u vnts2.service -f
```

升级前备份并再次运行新包中的安装器：

```bash
sudo systemctl stop vnts2
sudo tar -czf "vnts2-backup-$(date +%F).tar.gz" /etc/vnts2 /var/lib/vnts2
sudo ./install.sh
```

## 6. 卸载

默认保留配置和数据：

```bash
sudo ./uninstall.sh
```

彻底清除（不可恢复，请先备份）：

```bash
sudo ./uninstall.sh --purge
```

## 7. 常见问题

- 服务启动失败：运行 `sudo ./diagnose.sh` 和 `sudo journalctl -u vnts2.service -n 100 --no-pager`。
- 端口被占用：运行 `sudo ss -lntup | grep -E '29871|29872|51820|29873'`。
- 控制台打不开：确认 SSH 隧道仍保持连接，服务端不要把 `web_bind` 改为 `0.0.0.0`，当前版本会主动拒绝该不安全配置。
- 配置解析失败：TOML 顶层配置必须放在 `[custom_nets]` 之前。

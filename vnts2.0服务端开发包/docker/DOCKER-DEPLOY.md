# VNTS 2.0 Docker 部署说明

镜像平台为 `linux/amd64`。推荐在 Linux Docker Engine 24+ 或兼容版本上使用；Compose 方案使用 host 网络以保持 Web 管理端只监听宿主机 `127.0.0.1`。

## 1. 导入离线镜像

```bash
sha256sum -c vnts2-2.0.0-docker-linux-amd64.tar.gz.sha256
docker load -i vnts2-2.0.0-docker-linux-amd64.tar.gz
docker image inspect vnts2:2.0.0
```

## 2. Compose 快速启动（Linux 推荐）

将 `compose.yaml` 放到服务器后执行：

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=50
```

首次启动会在命名卷 `vnts2-data` 中生成配置、数据库、证书、日志、随机管理密码和严格 32 字节的 WireGuard 主密钥。查看密码：

```bash
docker exec vnts2 cat /data/admin-password.txt
```

账号为 `admin`，控制台地址为服务器本机 `http://127.0.0.1:29871`。远程管理使用 SSH 隧道：

```bash
ssh -L 29871:127.0.0.1:29871 user@server-ip
```

业务端口默认使用宿主机的 TCP/UDP `29872`，WireGuard 默认使用 UDP `51820`。host 网络模式只适用于 Linux；Docker Desktop 可用于镜像测试，但不建议用作正式服务器。

## 3. 安全与持久化

默认 Compose 已启用：

- UID/GID `10001:10001` 非 root 运行；
- 丢弃全部 Linux capabilities；
- `no-new-privileges`；
- 只读容器根文件系统；
- 仅 `/data` 命名卷和 `/tmp` 临时文件系统可写；
- Web 管理端只绑定回环地址。

不要把 `/data/admin-password.txt`、`config.toml`、数据库或 WireGuard 主密钥提交到代码仓库。

## 4. WireGuard 默认配置

首次启动会自动创建 `/data/wireguard-master.key`，并写入以下配置：

```toml
wireguard_master_key_file = "/data/wireguard-master.key"
wireguard_bind = "0.0.0.0:51820"
```

未显式设置 `wireguard_public_endpoint` 时，服务会根据容器默认路由选择 endpoint，并排除未指定地址、回环、链路本地和 `198.18.0.0/15`。生产环境位于 NAT 后方或使用公网域名时，在 `[custom_nets]` 之前显式覆盖：

```toml
wireguard_public_endpoint = "vpn.example.com:51820"
```

修改后重启并检查：

```bash
docker compose restart
docker compose ps
docker compose logs --tail=100
```

host 网络模式下 UDP `51820` 会直接监听宿主机；请按实际防火墙策略放行。VNTS 当前使用用户态 WireGuard 数据面，不需要 `--privileged`、`NET_ADMIN` 或 `/dev/net/tun`。

## 5. 备份、升级与恢复

备份命名卷：

```bash
docker compose stop
docker run --rm -v vnts2-data:/data -v "$PWD":/backup debian:bookworm-slim \
  tar -C /data -czf /backup/vnts2-data-backup.tar.gz .
docker compose start
```

升级时导入新镜像、更新 `compose.yaml` 中的版本，再执行：

```bash
docker compose up -d --force-recreate
```

配置、`network_control.db` 和 WireGuard 主密钥属于同一恢复集合，必须一起备份和恢复。

## 6. 停止与卸载

保留数据：

```bash
docker compose down
```

连同数据卷彻底删除（不可恢复）：

```bash
docker compose down -v
```

## 7. 常见问题

- `unhealthy`：执行 `docker inspect vnts2` 和 `docker logs vnts2`。
- 端口冲突：执行 `sudo ss -lntup | grep -E '29871|29872|51820|29873'`。
- 卷权限错误：命名卷应由容器自动创建；绑定宿主目录时需预先设置 UID/GID `10001:10001`。
- Docker Desktop 无法访问控制台：正式 Compose 使用 Linux host 网络；桌面环境仅建议做镜像内部健康测试。

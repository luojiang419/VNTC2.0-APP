# VNTC Linux WebUI Docker 部署

## 运行要求

- 原生 Linux Docker 主机，x86_64 架构。
- 主机存在 `/dev/net/tun`。
- Compose 支持 `network_mode: host`、设备映射和 capability。

P2P 打洞对 NAT 路径敏感。正式使用必须保留 Compose 中的 `network_mode: host`，不要改成默认 bridge 网络；否则 Docker 二次 NAT 可能降低直连成功率。

Docker Desktop 可以用于镜像构建和 WebUI 冒烟，但其虚拟机网络不作为 P2P 效果验收环境。

## 启动

将 `compose.yaml` 放在部署目录后执行：

```bash
mkdir -p data
docker compose up -d
docker compose logs -f
```

首次启动会生成 `data/config.json`，默认不自动连接并只监听：

```text
http://127.0.0.1:18080/
```

远程管理推荐使用 SSH 隧道：

```bash
ssh -L 18080:127.0.0.1:18080 user@docker-host
```

如果把 `web.listen` 改为 `0.0.0.0`，必须同时设置非空的 `web.access_token`。

## 离线导入

推荐在发布目录中执行一键校验和导入：

```bash
chmod +x load-image.sh
./load-image.sh
docker compose up -d
```

脚本会先通过 `.sha256` 文件验证镜像包完整性，再调用 `docker load`。也可以手动执行：

```bash
sha256sum -c VNTC_Linux_WebUI_4.5_Docker_amd64.tar.gz.sha256
gzip -dc VNTC_Linux_WebUI_4.5_Docker_amd64.tar.gz | docker load
```

## 权限说明

容器采用只读根文件系统，持久化目录只有 `/data`。Compose 会删除默认 capability，仅添加：

- `NET_ADMIN`：创建 TUN、配置虚拟地址和路由。
- `NET_RAW`：网络探测及 ICMP 相关能力。

同时映射主机 `/dev/net/tun`。删除任一配置都会导致虚拟网络功能不完整。

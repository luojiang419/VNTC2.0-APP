# VNTS 2.0 Linux 快速部署

这个目录包含当前正在使用的 `vnts2` Linux 端部署文件：

- `vnts2`
- `config.toml`
- `vnts2.service`
- `install.sh`

## 快速部署

1. 将整个 `linux` 目录上传到目标服务器
2. 按需修改 `config.toml`
3. 使用 root 执行：

```bash
chmod +x ./install.sh ./vnts2
./install.sh
```

默认会部署到：

```bash
/root/vnts2
```

如果你想改部署路径：

```bash
./install.sh /your/custom/path
```

## 需要重点修改的配置

- `tcp_bind` / `quic_bind` / `ws_bind`
  这是服务监听端口，当前示例是 `2222`
- `network`
  虚拟网段
- `white_list`
  当前示例只允许 `game`
- `server_quic_bind`
  如果要启用多服务器互联，需要改成目标服务器自己的公网地址

## 常用检查命令

```bash
systemctl status vnts2.service
systemctl restart vnts2.service
journalctl -u vnts2.service -f
```

# WireGuard 模块 4.5：局域网启用与测试

## 当前局域网地址

```text
服务器：192.168.100.102
WireGuard UDP：41194
客户端 Endpoint：192.168.100.102:41194
VNT 虚拟网络：10.26.0.0/24
```

UDP 51820 在本机 Windows 的系统排除范围 `51808–51907` 内，不能绑定。最终改用不在动态端口范围和排除范围内的 UDP 41194。

## 正式配置

```toml
wireguard_master_key_file = "wireguard-master.key"
wireguard_bind = "192.168.100.102:41194"
wireguard_public_endpoint = "192.168.100.102:41194"
wireguard_max_active_peers = 4096
```

主密钥是 32 字节加密安全随机二进制文件，仅 SYSTEM 与 Administrators 可访问。

## 为什么绑定具体局域网地址

系统 Public 防火墙配置文件当前处于关闭状态。没有为完成本模块而擅自开启全局防火墙，因为这可能影响其他业务。

WireGuard 因此只绑定物理网卡地址 `192.168.100.102`，不会在 `0.0.0.0`、VNT/TUN 或其他接口监听。已经创建的防火墙规则还进一步限定程序、UDP 端口、以太网接口和 LocalSubnet；如果以后启用 Public 防火墙，该规则会自动生效。

## 已完成验收

- WireGuard configured/running 均为 true。
- UDP 41194 只由正式服务 PID 监听。
- 数据库 Ready。
- 服务端公钥为标准 44 字符 Base64，连续重启保持稳定。
- 真实一键生成接口成功创建完整客户端配置。
- 生成响应中的客户端私钥、公钥和服务端公钥均为标准 44 字符。
- Endpoint 和 listen_addr 均为 `192.168.100.102:41194`。
- 自动化测试 Peer 已删除，最终 Peer 数为 0。
- 官方 Windows 诊断为 0 失败、0 警告。

## 手机或第二台电脑测试

1. 让客户端设备连接到与服务器相同的 `192.168.100.0/24` 局域网。
2. 在服务器本机打开 `http://127.0.0.1:29871/` 并登录。
3. 进入 WireGuard Peer 页面，点击“新增 Peer”。
4. 填写容易辨认的 Peer ID，保持默认“一键生成”。
5. 创建后使用手机 WireGuard App 扫描二维码，或下载 `.conf` 后导入另一台电脑。
6. 确认配置显示 Endpoint `192.168.100.102:41194`，然后启用隧道。
7. 在 Web 控制台确认该 Peer 的运行状态；测试完毕后可按需要保留或删除。

生成配置的 `AllowedIPs` 是 VNT 网络段，不会把客户端全部互联网流量默认导入该隧道。

## 恢复点

- 启用前回滚：`C:\ProgramData\VNTS2\.backups\pre-wireguard-lan-20260714-231156-674`
- 最终成对恢复：`C:\ProgramData\VNTS2\.backups\wireguard-lan-final-20260714-232057-173`

恢复启用状态时，数据库和 `wireguard-master.key` 必须成对恢复，不能只恢复其中一个。

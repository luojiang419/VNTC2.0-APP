# OpenWrt 精简环境与安装验收

## 首次安装生成空令牌

表现：IPK 显示已安装，但 WebUI 未监听；安装日志出现 `od: not found` 和 `WebUI 监听非本机地址时，access_token 不能为空`。

根因：OpenWrt 24.10.5 x86_64 官方镜像未包含 `od`。POSIX shell 的 `set -e` 不会自动检测管道前半段失败，原初始化管道最后的 `tr` 成功，脚本仍写出空令牌。

解决：从 `/proc/sys/kernel/random/uuid` 读取内核随机值并拼接令牌，明确检查令牌和设备 ID 长度；通过临时文件原子写入配置；初始化结束后直接执行程序的 `--check-config`，失败即中断安装。

验证：双虚拟机验收会检查令牌长度、两台设备令牌不同、目录权限 700、配置权限 600，以及无令牌请求返回 HTTP 401。完整结果见同目录上一层的开发与验证记录。

## 测试服务端配置

现有 VNTS 2.0 的 TOML 配置要求同时提供 `custom_nets` 表及 `lease_duration`，即使不使用自定义网段也不能省略表。专用测试配置显式写入这些字段，测试服务端使用独立回环端口，不复用或改写生产配置。

## Windows 中调用 WSL

跨 PowerShell、WSL 和 bash 传入多层引号时容易产生额外展开。复杂 Python 操作使用 PowerShell 单引号 here-string 通过 stdin 交给 `wsl ... python3 -`；长期验收逻辑保存为脚本文件执行。

## 真实整机重启必须使用完整引导镜像

初期使用独立内核加 rootfs 的 QEMU 直接引导，应用和隧道均正常，但执行 guest `reboot` 后未重新引导。验收改用官方 `generic-ext4-combined.img.gz`，保留 MBR、引导分区、GRUB 和磁盘标识，离线只扩展及预置 rootfs 分区。不能用服务重启代替整机重启验收。

该官方 combined 镜像在 gzip 流后附加 fwtool 元数据，Python `gzip.open` 读到尾部会报 `Not a gzipped file (b'# ')`。完整文件通过官方 SHA-256 后，用 `zlib.decompressobj(16 + MAX_WBITS)` 解压首个 gzip 流并检查 `eof`，保留 gzip CRC 校验，避免把附加元数据当第二个 gzip 流。

完整镜像在此前 VirtIO 虚拟硬件组合下仍观察到热重置后卡住。最终使用 `pc / qemu64 / 单 CPU / IDE / e1000`，独立测试和双 VM 主验收均通过客户机直接 `reboot`：QEMU PID 不变、boot_id 改变、自动组网和持久配置一致。不能将此前冷启动结果误写为热重置通过。

## 重启后的临时安装包必须重新上传

OpenWrt 的 `/tmp` 位于 tmpfs，整机重启后 `/tmp/vntc.ipk` 会消失；后续 `opkg --force-reinstall` 因找不到文件失败属于验证器准备步骤缺失。安装生命周期检查开始时重新上传原安装包。检查点接力必须核对同一 IPK 的 SHA-256，并保留前序原始报告。

## 防火墙元数据不要写成未知 UCI 选项

fw4 会对自定义 `vntc_managed` 区域选项输出警告。受管区域身份标记改存 `/etc/vntc/.firewall-managed`，同时核对固定节名和区域名；不使用 fw4 未定义的选项。安装器只创建独立 VNT 区域，不改已有 LAN/WAN 区域，不添加默认转发。

# VNTS OpenWrt 插件

Rust VNTS 2.0 服务端，含现有 Web 管理、持久化、VNT 与可选 WireGuard 功能。使用静态 musl 程序和 procd，无需 Python、Node.js、Docker 或 systemd。OpenWrt feature 使用单 Tokio 工作线程及系统日志，不持续写入日志文件。

ARM64 为 `aarch64-unknown-linux-musl`；ARMv7 为 `armv7-unknown-linux-musleabihf`，要求 ARMv7 + VFPv3/VFPv4，不能安装到无 VFP 的 ZX279128S 或其他 soft-float 平台。默认 IPK 架构对应 OpenWrt armsr 通用镜像，真实路由器先运行 `opkg print-architecture`，按实际包架构重新打包或使用匹配 CPU/ABI 的离线包，不要强制忽略架构检查。

## 安装

`opkg install /tmp/vnts2-openwrt_*.ipk`，或解压 `VNTS_OpenWrt_*.tar.gz` 后进入目录执行 `sh install.sh`。访问 `http://路由器LAN地址:29871/`；用户名 `admin` 和随机密码位于 `/etc/vnts2/config.toml`。VNT 地址为 `quic://路由器地址:29872`（也支持 TCP/WSS）。

配置、证书、SQLite 数据库和可选 WireGuard 主密钥保存在 `/etc/vnts2/`，目录 700，初始配置 600。重装、升级和卸载保留业务数据；sysupgrade 保留目录。本插件不修改原有 LAN/WAN 配置，不自动开放 WAN；公网服务按需求手动添加防火墙规则。

服务命令：`/etc/init.d/vnts2 start|stop|restart|status`，日志：`logread -e vnts2`。卸载：`opkg remove vnts2-openwrt` 或离线包的 `sh uninstall.sh`。

WireGuard 默认不开启，仍保留完整实现；需要时在配置中加入 `wireguard_bind`、`wireguard_master_key_file`，使用独立随机 32 字节密钥并配置公网 Endpoint 和 UDP 防火墙规则。备份整个 `/etc/vnts2/`，不要公开密码或密钥。

## 构建

仓库根目录运行 `bash vnts2.0服务端开发包/openwrt/build.sh 2.0.0 /path/to/output aarch64`，或将最后参数换为 `armv7` / `x86_64`。可追加第四参数指定 OpenWrt 包架构，例如 `aarch64_cortex-a53`；该参数只影响包元数据，不改变 CPU 指令集或 ABI。

Linux/WSL 安装 Rust、Python3、Zig、cargo-zigbuild、QEMU user static；版本不递增。打包器校验 ELF CPU、静态链接及 ARM hard-float 标记，生成 IPK、离线包和 SHA256SUMS。

安装前检查实际剩余内存和存储；服务端包含 SQLite 和管理端，资源占用会随网络、节点和流量增长。ARM 验证记录见仓库 `VntcApp1.0/openwrt/ARM适配与验证.md`。

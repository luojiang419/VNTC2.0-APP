# VNTC OpenWrt 客户端

基于项目现有 Rust VNT 2.0 核心与 Linux WebUI，提供静态 musl x86_64、ARM64（aarch64）和 ARMv7 程序、opkg 安装包和 procd 服务。无需 systemd、Docker、Python 或 Node.js 运行时。浏览器页面内嵌在二进制中。

## 安装与使用

面向 OpenWrt 24.10；按 CPU/ABI 和包架构选择产物，不能混用。建议至少 256MB 内存、64MB 剩余存储空间。ARMv7 包要求 VFPv3/VFPv4 和 hard-float EABI，不能用于无 VFP 的 ZX279128S。ARM64 和 ARMv7 的默认 IPK 架构分别为 `aarch64_generic` 与 `arm_cortex-a15_neon-vfpv4`，对应官方 armsr 虚拟机；真实路由器先运行 `opkg print-architecture`，不匹配时重新指定包架构打包，或使用匹配 CPU/ABI 的离线包，不要强制安装。

上传 IPK 后运行：

```sh
opkg update
opkg install kmod-tun
opkg install /tmp/vntc-openwrt_*_x86_64.ipk
cat /etc/vntc/config.json
```

或解压 `VNTC_OpenWrt_*_x86_64.tar.gz`，进入目录运行 `sh install.sh`。离线安装前需准备与系统内核匹配的 `kmod-tun`。

访问 `http://路由器LAN地址:18080/`，输入 `web.access_token` 中随机生成的管理令牌。在配置页面填写 VNTS 地址、组网码、设备名和密码，然后连接。设置页面开启自动连接后，开机连接默认档案。初次安装只启动管理页面，不连接占位服务器。

默认监听全部本机地址，不自动新增 WAN 放行规则。远程管理建议使用 SSH 隧道。安装器添加独立的 `vntc_openwrt` 防火墙分区，绑定 VNT 接口，允许组网节点访问路由器本机，禁止默认转发；仅让可信节点加入组网并设置组网密码。已有 LAN、WAN、DNS 和其他防火墙分区保持原状。需要让 LAN 设备通过 VNT 转发时，须按实际网段配置 VNT 输入/输出路由及 OpenWrt 防火墙转发规则。通过 WebUI 修改 TUN 名称后，请执行 `/etc/init.d/vntc restart` 同步专用分区。

```sh
/etc/init.d/vntc status
/etc/init.d/vntc restart
/etc/init.d/vntc stop
logread -e vntc
```

配置档案、设置和设备 ID 保存在 `/etc/vntc/`，升级/重新安装保留；`/lib/upgrade/keep.d/vntc` 使 sysupgrade 备份包含此目录。不要把管理令牌或组网密码贴入公开日志。卸载执行 `opkg remove vntc-openwrt`；便携安装执行 `sh uninstall.sh`，均默认保留业务配置，只有 `--purge` 才清理已知业务文件。

## 构建

Linux / Ubuntu WSL 安装 Rust（edition 2024）、`build-essential musl-tools binutils python3`，在仓库根目录运行：

```sh
bash VntcApp1.0/openwrt/build.sh
```

版本默认读取客户端 `pubspec.yaml`，不递增正式版本。构建使用锁定依赖，执行格式检查、musl 单元/集成测试和 release 编译，并检查 ELF 不依赖动态加载器。产物输出至 `VntcApp1.0/release/openwrt/`，包含 SHA-256。

ARM 交叉构建额外安装 Zig、cargo-zigbuild、qemu-user-static。第三参数选择架构，第四参数可指定路由器实际 OpenWrt 包架构：

```sh
bash VntcApp1.0/openwrt/build.sh 4.8.40 VntcApp1.0/release/openwrt-arm/aarch64 aarch64
bash VntcApp1.0/openwrt/build.sh 4.8.40 VntcApp1.0/release/openwrt-arm/armv7 armv7
# 例如将同一个 ARM64 静态程序打包为 aarch64_cortex-a53：
bash VntcApp1.0/openwrt/build.sh 4.8.40 /path/to/output aarch64 aarch64_cortex-a53
```

ARM 构建执行 QEMU user 的 `--help` 检查，打包检查 ELF 架构、静态链接和 ARM ABI；完整 ARM 系统验证使用仓库 `tools/openwrt/verify_arm.py`，记录见 [ARM适配与验证](ARM适配与验证.md)。包架构参数只改 opkg 元数据，不能把 ARMv7 变为 ARMv6 或把 hard-float 变为 soft-float。

## 自动虚拟机验证

`verify_vm.py` 在 Linux / WSL 使用 QEMU 启动两个独立的真实 OpenWrt 24.10.5 x86_64 系统。依赖 `qemu-system-x86 qemu-utils e2fsprogs python3-paramiko`。官方镜像下载后校验官方 SHA-256；测试仅修改专用工作目录中的镜像，所有转发端口仅监听宿主回环地址。

```sh
python3 VntcApp1.0/openwrt/verify_vm.py \
  --package VntcApp1.0/release/openwrt/vntc-openwrt_4.8.40-1_x86_64.ipk \
  --server-binary /path/to/vnts2 \
  --work-dir "$HOME/.cache/vntc-openwrt/vm"
```

验证安装、鉴权、真实 TUN、双节点虚拟 IP 双向 ping、大包通信、流量计数、停止释放 TUN、重连、进程崩溃恢复、服务端重启恢复、虚拟机重启自启、重新安装/卸载保留配置，以及便携安装。任何断言失败均返回非零并保留串口日志、命令记录及 JSON 报告。默认结束时关闭本次启动的虚拟机和测试服务端；加 `--keep-running` 保留供人工检查。

既有 `verify_vm.py` 用于 x86_64；ARM64/ARMv7 使用独立验证器。MIPS、真实硬件、特定 LAN 防火墙拓扑需针对目标设备另行验收。

## 两地 LAN 互访与监控端口转发

网关功能默认关闭，不新增常驻进程。需要 firewall4、IPv4 转发，且两地 LAN 与虚拟网段不能重叠。以下例子中 A 是现场路由器，LAN 为 `192.168.50.0/24`、虚拟 IP `10.26.0.2`；B 是访问端，LAN 为 `192.168.60.0/24`、虚拟 IP `10.26.0.3`。普通 LAN 设备以所在路由器为默认网关，无需安装 VNT；路由器若只是旁路由，需要在主网关或终端添加指向旁路由的目标网段路由。

在两端 WebUI 配置页面固定虚拟 IP，启用“禁用内置 NAT”，使用 OpenWrt 内核转发。A 输入路由填 `192.168.60.0/24=10.26.0.3`，输出路由填 `192.168.50.0/24`；B 输入路由填 `192.168.50.0/24=10.26.0.2`，输出路由填 `192.168.60.0/24`。保存并连接。OpenWrt 客户端自动添加输入网段的内核路由，断开时清理；遇到已有同前缀路由会报错，不覆盖默认路由或虚拟网段。

A 端执行（B 端交换两个 LAN 网段）：

```sh
uci set vntc_gateway.main.enabled='1'
uci set vntc_gateway.main.lan_zone='lan'
uci set vntc_gateway.main.lan_cidr='192.168.50.0/24'
uci set vntc_gateway.main.overlay_cidr='10.26.0.0/24'
uci -q delete vntc_gateway.main.remote_cidr || true
uci add_list vntc_gateway.main.remote_cidr='192.168.60.0/24'
uci commit vntc_gateway
/usr/libexec/vntc-gateway apply
```

此时 B 下电脑既能访问 B 本地地址，也能访问 A 的虚拟 IP 上开放的服务，以及 A 的 `192.168.50.x` 设备；反向同理。插件生成限定来源与目标网段的 LAN/VNT 放行及双向源地址转换，因此终端不需要额外回程路由；远端服务看到的是路由器地址。默认不增加 WAN 入口，不转发两端的普通上网流量。

如现场摄像头为 `192.168.50.100:80`，需要用 `10.26.0.2:18081` 访问，在 A 增加：

```sh
uci set vntc_gateway.camera='service'
uci set vntc_gateway.camera.proto='tcp'
uci set vntc_gateway.camera.listen_port='18081'
uci set vntc_gateway.camera.dest_ip='192.168.50.100'
uci set vntc_gateway.camera.dest_port='80'
uci commit vntc_gateway
/usr/libexec/vntc-gateway apply
```

RTSP 同样可映射 TCP 端口（如 18554 → 554），播放器使用 `rtsp://10.26.0.2:18554/实际流路径` 并选择 RTP over TCP；UDP 服务使用独立的 `proto='udp'` 服务节。RTSP 的动态 RTP/RTCP UDP 端口还需按设备配置单独处理。Web 页面若返回绝对地址或额外服务端口，优先通过远端 LAN IP 直接访问。组网不会自动代理 ONVIF/广播发现，已知 IP 的访问不受此限制。

修改配置后执行 apply，服务重启和开机会重新应用；规则使用独立的 `vntcg_` 节及所有权记录，校验失败恢复原防火墙配置。关闭使用 `uci set vntc_gateway.main.enabled='0'; uci commit vntc_gateway; /usr/libexec/vntc-gateway apply`。卸载只清理受管规则，默认保留 `/etc/config/vntc_gateway` 和业务配置，sysupgrade 备份包含二者。不要手动改写受管防火墙节，应修改网关配置后重新应用。

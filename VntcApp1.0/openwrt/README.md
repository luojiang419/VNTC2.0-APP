# VNTC OpenWrt 客户端

基于项目现有 Rust VNT 2.0 核心与 Linux WebUI，提供静态 musl x86_64 程序、opkg 安装包和 procd 服务。无需 systemd、Docker、Python 或 Node.js 运行时。浏览器页面内嵌在二进制中。

## 安装与使用

首版面向 OpenWrt 24.10、x86_64 软路由；其他架构需要另外交叉编译，不能混用。建议至少 256MB 内存、64MB 剩余存储空间。

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

## 自动虚拟机验证

`verify_vm.py` 在 Linux / WSL 使用 QEMU 启动两个独立的真实 OpenWrt 24.10.5 x86_64 系统。依赖 `qemu-system-x86 qemu-utils e2fsprogs python3-paramiko`。官方镜像下载后校验官方 SHA-256；测试仅修改专用工作目录中的镜像，所有转发端口仅监听宿主回环地址。

```sh
python3 VntcApp1.0/openwrt/verify_vm.py \
  --package VntcApp1.0/release/openwrt/vntc-openwrt_4.8.40-1_x86_64.ipk \
  --server-binary /path/to/vnts2 \
  --work-dir "$HOME/.cache/vntc-openwrt/vm"
```

验证安装、鉴权、真实 TUN、双节点虚拟 IP 双向 ping、大包通信、流量计数、停止释放 TUN、重连、进程崩溃恢复、服务端重启恢复、虚拟机重启自启、重新安装/卸载保留配置，以及便携安装。任何断言失败均返回非零并保留串口日志、命令记录及 JSON 报告。默认结束时关闭本次启动的虚拟机和测试服务端；加 `--keep-running` 保留供人工检查。

目前验证边界为 x86_64 虚拟机；ARM/MIPS、真实硬件、特定 LAN 防火墙拓扑需针对目标设备另行验收。

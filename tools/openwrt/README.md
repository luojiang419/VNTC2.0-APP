# OpenWrt ARM 构建与验证工具

服务端和客户端共用静态 ELF/ABI 校验与交叉构建入口。ARM64 使用 `aarch64-unknown-linux-musl`；ARMv7 使用 `armv7-unknown-linux-musleabihf`（ARMv7 + VFPv3，hard-float）。不涵盖 ARMv6、MIPS、无 VFP 的 ZX279128S 或其他 soft-float 平台。

## 构建

Linux/WSL 安装 Rust、Zig、cargo-zigbuild、qemu-user-static、Python3、binutils、build-essential、cmake；x86_64 另需 musl-tools。建议固定依赖，保持已有 Cargo.lock。仓库根目录分别执行：

```sh
bash VntcApp1.0/openwrt/build.sh 4.8.40 VntcApp1.0/release/openwrt-arm/aarch64 aarch64
bash VntcApp1.0/openwrt/build.sh 4.8.40 VntcApp1.0/release/openwrt-arm/armv7 armv7
bash vnts2.0服务端开发包/openwrt/build.sh 2.0.0 vnts2.0服务端开发包/dist/openwrt/aarch64 aarch64
bash vnts2.0服务端开发包/openwrt/build.sh 2.0.0 vnts2.0服务端开发包/dist/openwrt/armv7 armv7
```

第四参数可以指定真实路由器 `opkg print-architecture` 中的包架构。默认 `aarch64_generic`、`arm_cortex-a15_neon-vfpv4` 对应官方 armsr 镜像。aarch64_cortex-a53 等其他包架构需要正确重打包；离线包不依赖 opkg 架构标签，但仍须匹配 CPU/ABI，安装器会先校验 CPU 和程序能否运行。修改标签不会转换机器码，不要强制安装不匹配的 IPK。

构建运行格式检查、静态 musl 编译、QEMU user `--help`，并检查 ELF 的 CPU、32/64 位、ARM hard-float 标记和 PT_INTERP。rustup 安装过程使用 flock 串行化，避免服务端和客户端同时下载相同标准库。网络代理按当前机器配置到进程环境，不写入通用脚本。

## 完整 ARM 系统验证

额外安装 `qemu-system-arm qemu-utils e2fsprogs python3-paramiko`。`verify_arm.py` 校验官方 OpenWrt 24.10.5 armsr kernel、ext4 rootfs 和同内核 kmod-tun 的 SHA-256，在 QEMU virt 上启动两个同架构的独立 256MiB 虚拟机：ARM64 使用 Cortex-A53，ARMv7 使用 Cortex-A15。

```sh
python3 tools/openwrt/verify_arm.py --arch aarch64 \
  --client-package VntcApp1.0/release/openwrt-arm/aarch64/vntc-openwrt_4.8.40-1_aarch64_generic.ipk \
  --server-package vnts2.0服务端开发包/dist/openwrt/aarch64/vnts2-openwrt_2.0.0-1_aarch64_generic.ipk \
  --client-portable VntcApp1.0/release/openwrt-arm/aarch64/VNTC_OpenWrt_4.8.40_aarch64.tar.gz \
  --server-portable vnts2.0服务端开发包/dist/openwrt/aarch64/VNTS_OpenWrt_2.0.0_aarch64.tar.gz
```

ARMv7 替换为 `--arch armv7`、armv7 目录/离线包文件名及 `arm_cortex-a15_neon-vfpv4` IPK。默认结束关闭本轮虚拟机，保留隔离磁盘、SSH 私钥、串口/命令日志和 report.json；私钥与业务密码不得分发或提交。仅 `--keep-running` 且验证全部成功时保留运行。

同架构服务端运行在节点 A，两个客户端均运行在 ARM 系统内部，验证 QUIC 中继、TLS/TCP 中继、双向 1300 字节包、虚拟 IP HTTP、管理鉴权、SQLite 持久化、错误架构拒装、重装保配置、procd 崩溃恢复、真实客户机热重启自启及离线安装/卸载/重装。端口只监听宿主回环；ARM64 使用 23100/23101（SSH）、23110/23111（客户端）、23120（中继）、23121（服务端管理），ARMv7 对应 232xx，不干扰既有 x86 验证机。

ARMv7 固定 `virt,virtualization=on / cortex-a15`，本机 TCG 重启后的 SSH 等待上限为 420 秒，x86_64/ARM64 仍为 180 秒。接力可追加 `--resume-run /path/to/run`，要求已有安装/数据面/崩溃恢复阶段通过且四个包的 SHA-256 完全相同；保留旧 report 与串口日志，复用原磁盘后执行冷启动、真实热重启和剩余生命周期，不将重建 QEMU 进程计为热重启通过。

`python3 tools/openwrt/verify_stability.py --run /path/to/run` 可复用已经验收的磁盘补测：冷启动后先等 5 个连续大包零丢失，再验证每方向各 20 个 1300 字节包零丢失，追加原报告。正常退出先在 guest 内执行 sync，避免 QEMU 直接退出丢失刚复制文件的未落盘尾部；这不属于断电耐久性验收。

两份报告均成功后，运行 `python3 tools/openwrt/collect.py --report /path/to/aarch64/report.json --report /path/to/armv7/report.json`，会检查包哈希与报告、IPK ELF 与元数据、离线包内层校验和及二者机器码一致性，汇总到 `dist/openwrt-arm/`。

## 持续传输与保留管理页面

`live_validate.py --run /path/to/run --output /path/to/live --duration 300 --rounds 30` 复用已通过基础验收的磁盘，从交付目录重新部署同哈希 IPK。每种架构分别执行 TCP 和 QUIC 中继，每协议每方向传输 30 次 1MiB 随机文件，逐次 SHA-256 验证；同时每方向发送 150 个 1300 字节 ICMP 包，要求零丢失，并比较服务进程 PID。

临时 HTTP 数据源由 `transfer_http.c` 静态交叉编译，仅用于隔离 VM 验收，不装进插件。传输结束移除临时进程和 guest /tmp 测试数据，成功后保留 VNTs/vntc 及 VM 运行；失败则写入错误报告并停止本轮 VM。部署时仍使用既有的随机密码和管理令牌，配置保留。

报告保存为 `{architecture}-live-report.json`；登录凭据单独写入 `{architecture}-access.json`，仅放在被忽略的本地交付目录，不能提交 Git。不要对已经运行的同一 VM 目录重复执行启动命令。

HTTP 和嵌入资源检查不代表浏览器视觉验收；QEMU 测试不代表具体路由器的 Wi-Fi、Flash 分区、满带宽、硬件加速或长期稳定性。无指定机型时交付通用 CPU/ABI 版本，后续仍需核对设备 `uname -m`、`opkg print-architecture`、剩余存储以及匹配内核的 kmod-tun。

任务结果与产物入口见 `VntcApp1.0/openwrt/ARM适配与验证.md`。

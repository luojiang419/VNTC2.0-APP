# VNTs / vntc OpenWrt ARM 适配与验证

[CODEX_LONG_TASK_CONTINUE_V3]

## 目标与边界

2026-11-01，用户确认同时开发 ARM64（aarch64）与 ARMv7 的 VNTs 服务端、vntc 客户端插件，提供 OpenWrt 安装包和离线包。保留已有 x86_64 版本、精简静态界面、业务配置与网络协议；不刷写真实路由器，不推送 GitHub。

## 进度

- 工作分支：`codex/openwrt-arm`，基于已验证的 `codex/openwrt-client`。
- 客户端复用 `linux_webui` 和 `openwrt/`；服务端复用 `vnts2.0服务端开发包/official-vnts-source-2.0.0`，新增 OpenWrt/procd 集成。
- 已完成四个静态 musl release 构建、QEMU user 启动、架构/ABI 校验及 IPK/离线包生成。
- 客户端 28 项 musl 回归通过；服务端 90 项单元、6 项加密门禁与 10 项集成测试通过，共 106 项；默认非 OpenWrt feature 的 cargo check 通过。
- ARM64/ARMv7 官方 OpenWrt 双 VM 均已通过安装、鉴权、错误架构拒装、QUIC 与 TLS/TCP 加密中继、双向大包/HTTP、重装保留配置/SQLite 和 procd 崩溃恢复。
- ARM64 共 12 组、ARMv7 共 13 组完整 VM 检查通过（ARMv7 包含接力冷启动）；两种架构均通过真实热重启、自动组网、离线安装/卸载/重装和稳定后双向 20 个 1300 字节包零丢失。
- 产物汇总与哈希、ELF、包元数据、内层校验、IPK/离线包机器码一致性检查通过。全部实现和验收完成，仅作本地提交，不推送 GitHub。
- 现有工作区的重打包器修改、KEY/KEY2 和测试文档不属于本任务，保持原状。

## 已有验证入口

既有 x86_64 VM 和 `release/openwrt-lite` 保留；历史结果见 `开发与验证记录.md`、`精简与低内存优化.md`。ARM 必须单独运行，不将交叉编译或 ELF 检查当作真机/虚拟机组网通过。

## 实现

- `tools/openwrt/targets.py`：共享 CPU、ELF 位数、little-endian、静态链接、ARM hard-float 与包架构校验。
- `tools/openwrt/build-common.sh`：Rust + musl/cargo-zigbuild，rustup 使用 flock，ARM 通过 QEMU user 执行 `--help`。
- 客户端 `openwrt/build.sh/package.py/install.sh`：保持原 x86_64 调用方式，增加 aarch64/armv7 以及包架构参数。
- 服务端 `vnts2.0服务端开发包/openwrt/`：随机管理密码、procd、IPK/离线安装、卸载保留配置/SQLite/密钥及 sysupgrade keep.d。
- 服务端 Rust `openwrt` feature：单工作线程、512KiB 工作线程栈、最多 4 个阻塞线程，控制台日志默认 warn，支持 Unix SIGTERM 优雅退出；默认 Linux/Windows 行为保持原有实现。
- `tools/openwrt/verify_arm.py`：官方 OpenWrt 24.10.5 armsr/armv8 和 armsr/armv7 镜像、同内核 TUN、两台 256MiB 无 swap VM，服务端和客户端均在 guest 中原生运行。
- `tools/openwrt/collect.py`：将经过 VM 验收且 SHA-256 一致的 IPK、离线包与报告汇总，检查 portable 内容与 IPK 机器码一致。

## 安装范围

ARM64 默认 IPK 为 `aarch64_generic`，ARMv7 为 `arm_cortex-a15_neon-vfpv4`，用于官方 armsr 测试环境。真实设备的包架构标签可能不同，可按 `opkg print-architecture` 重打包，或使用匹配 CPU/ABI 的静态离线包；不应强制忽略架构检查。

ARMv7 采用 hard-float，要求 VFPv3/VFPv4，不支持没有 VFP 的 ZX279128S；本任务不再操作用户中兴原厂系统。MIPS、ARMv6、soft-float 不在本次范围内。QEMU 的基础通信结果不代表实际路由器满带宽、P2P 直连、特定 LAN 转发或长期稳定性。

## 构建与验证入口

共享命令见 `tools/openwrt/README.md`。实际 WSL 工具链：Rust 1.97.0、Zig 0.13.0、cargo-zigbuild 0.23.0、QEMU 8.2.2；锁定现有 Cargo.lock，客户端 4.8.40、服务端 2.0.0，不递增正式版本。

缓存目录：客户端 `/home/luo/.cache/vntc-openwrt/target`；服务端 `/home/luo/.cache/vnts-openwrt/target`；官方 ARM 镜像 `/home/luo/.cache/vnt-openwrt/downloads`；VM `/home/luo/.cache/vnt-openwrt/arm-vm`。下载遇到超时后仅在本轮进程使用本机现有代理，未写入项目通用脚本或修改依赖锁。

构建原始产物位于 `VntcApp1.0/release/openwrt-arm/{aarch64,armv7}` 和 `vnts2.0服务端开发包/dist/openwrt/{aarch64,armv7}`。历史 x86 产物不覆盖。

## 最终交付

汇总目录：`D:\Myproject\vnt2.0\dist\openwrt-arm\`。

- `aarch64/`：VNTs 与 vntc 各一份 IPK 和离线 tar.gz，SHA256SUMS、verification.json。
- `armv7/`：同上，ARMv7 hard-float。
- `使用说明.md`、`manifest.json`、`native-verification.json`：安装入口、每件产物的校验值和验证分类。

所有交付压缩包与实际 VM 验收时的 SHA-256 一致；汇总器同时核对包内 ELF、架构元数据和离线包中每个文件的校验和。x86_64 旧三参数打包入口另作兼容性检查，通过。

## 完整 VM 结果与资源

官方 OpenWrt 24.10.5，QEMU virt，单 vCPU，256MiB，无 swap；节点 A 同时运行服务端与客户端，节点 B 运行客户端。首轮硬件使用默认 virt；ARMv7 接力固定 virtualization=on，保留已通过阶段及其原报告；真实热重启要求 QEMU PID 不变、Linux boot_id 改变，并在重启后恢复双向数据面。

| 架构 | vntc RSS（节点 A） | VNTs RSS | 节点 A MemAvailable |
| --- | ---: | ---: | ---: |
| ARM64 | 6788KiB / 6.63MiB | 6332KiB / 6.18MiB | 170.46MiB |
| ARMv7 | 6828KiB / 6.67MiB | 6264KiB / 6.12MiB | 188.67MiB |

这是低流量、短时快照。程序 RSS 不等于系统总占用或浏览器内存，不能用来承诺满带宽、最大节点数或其他机型的内存。节点 B 客户端 RSS 分别为 6880KiB、6712KiB。

- ARM64 原始记录：`/home/luo/.cache/vnt-openwrt/arm-vm/20261101T133738Z-aarch64`。
- ARMv7 原始记录：`/home/luo/.cache/vnt-openwrt/arm-vm/20261101T134003Z-armv7`。
- 两种架构均实际验证随机鉴权、原生 IPK/TUN、错误架构拒装、QUIC/TLS-TCP 中继、双向大包和 HTTP、SQLite/配置保留、procd 崩溃恢复、客户机热重启、离线安装/卸载/重装，以及稳定后双向 20 包零丢失。
- ARMv7 早期 180 秒 SSH 等待不足，固定 virt virtualization=on 并单独提高 TCG 等待上限，独立和接力热重启均通过。
- ARM64 稳定性补测发现直接 SIGTERM QEMU 会丢失新复制程序未刷盘的尾部；测试器已加入 sync，使用相同离线包恢复后核对完整长度/哈希、业务配置不变、冷启动注册和双向零丢失通过。恢复证据附在最终 ARM64 report 的 `test_environment_recovery` 字段中。
- 开发验收阶段结束后 ARM VM 曾停止；随后按用户要求重新部署并保留在线，当前状态见下节。

本次不涉及刷写物理路由器；ARM WireGuard 专项流量、满载/P2P/具体 LAN 拓扑和浏览器视觉验收不在当前通过范围内。无需将构建/VM 缓存、私钥或临时凭据加入源码提交。

## 持续数据传输与在线部署（2026-11-01）

用户要求生成后部署、实际验证数据传输稳定性并提供 VNTs/vntc 访问地址。已从交付目录重新安装相同 SHA-256 的 IPK，逐台核对安装后的程序哈希，保留既有业务配置和随机凭据。每种架构运行两台 256MiB 完整 OpenWrt VM，节点 A 同时运行服务端，两个客户端均使用 relay_only，依次验证 TCP 与 QUIC。

| 架构 | TCP 实际持续时间 | QUIC 实际持续时间 | 双向有效载荷 | 文件完整性 | 大包丢失 | 意外进程重启 |
| --- | ---: | ---: | ---: | --- | --- | --- |
| ARM64 | 179.731 秒 | 150.439 秒 | 120MiB | 120 次 SHA-256 全一致 | 0% | 无 |
| ARMv7 | 150.146 秒 | 150.122 秒 | 120MiB | 120 次 SHA-256 全一致 | 0% | 无 |

每协议、每方向 30 次 1MiB 随机文件传输，同时每方向发送 150 个 1300 字节 ICMP 包，每架构共 600 包。传输通过虚拟 IP 的原生 TCP HTTP 流，实际穿过 TUN、VNT 加密通道和 ARM 服务端中继。最后保持 QUIC 连接。该结果属于短时、受控负载稳定性验收，不代表最大吞吐或长期运行验收。

当前本机访问地址：

| 架构 | vntc 节点 A | vntc 节点 B | VNTs |
| --- | --- | --- | --- |
| ARM64 | http://127.0.0.1:23110/ | http://127.0.0.1:23111/ | http://127.0.0.1:23121/ |
| ARMv7 | http://127.0.0.1:23210/ | http://127.0.0.1:23211/ | http://127.0.0.1:23221/ |

已在 Windows 宿主实际验证六个页面 HTTP 200、VNTs 登录及受保护 API、vntc running 和在线对端。四台 VM、两个 VNTs 和四个 vntc 保持运行，临时 HTTP 测试进程及 guest 测试数据已经清理。保留 WSL keepalive，管理地址依赖本机 WSL/VM 继续运行。

交付目录 `dist/openwrt-arm/live/` 包含两个 live-report.json、summary.json、windows-access-check.json、cleanup-check.json。用户名、密码和管理令牌仅写入该忽略目录下的 `访问说明.md` 和两个 access.json，不进入源码提交。原始命令/串口/载荷记录位于上述 VM 目录的 `live-20261101T143721Z/`。

## Windows 临时版互通验收（2026-11-01）

用户要求在本机部署 Windows 临时版，验证与上述 ARM 服务端和客户端连接、传输。已用同一 VNT Core 构建 Windows x86_64 原生 EXE + WebUI，版本 `4.8.40-win-arm-test`，使用实际 Wintun，不替换已运行的正式 Flutter 客户端，不安装系统服务。隔离目录为 `dist/windows-arm-interop/`，控制台 http://127.0.0.1:18083/；凭据仅存本地 `state/config.json` 和 `访问说明.md`。

Windows 虚拟 IP 为 `10.26.0.10/24`，网卡为 `VNT-App-TUN-VNT-WinARM-Test`。预置 ARM64/ARMv7 各 TCP/QUIC 共四个档案；两组网段相同，依次连接。ARM 各节点保持 relay_only，使用虚拟 IP 的真实 TCP HTTP 数据流传输。

| ARM 架构 | 通道 | 双向有效载荷 | 实际持续时间 | 文件校验 | 大包 ping |
| --- | --- | ---: | ---: | --- | --- |
| ARM64 | TCP | 40MiB | 94.344 秒 | SHA-256 全一致 | 240 包零丢失 |
| ARM64 | QUIC | 40MiB | 61.015 秒 | SHA-256 全一致 | 240 包零丢失 |
| ARMv7 | TCP | 40MiB | 60.422 秒 | SHA-256 全一致 | 240 包零丢失 |
| ARMv7 | QUIC | 40MiB | 60.453 秒 | SHA-256 全一致 | 240 包零丢失 |

每组 Windows 分别与两个 ARM 对端进行 10 轮、每轮双向各 1MiB 随机文件传输，总计 160MiB、160 次文件 SHA-256 检查；同时四条方向各 60 个 1300 字节 ICMP 包，总计 960 包。Windows 原生 Rust 25 项测试通过；管理 API 确认 `windows/x86_64`、`Windows 原生进程`，七个本机管理页面 HTTP 200。没有将 HTTP 检查当作浏览器视觉验收。

Windows 无法直接访问 WSL 回环 UDP，实测得到 WinError10054；增加 `tools/openwrt/udp_relay.py`，为两组 QUIC 测试提供独立转接，仅允许 Windows WSL 网关 IP，转发加密报文。TCP 仍直接连接宿主回环 23120/23220。该转接属于本地 NAT 测试环境，未更改 ARM 插件网络核心。

`tools/openwrt/windows_temp.py` 提供启动、停止和状态查询；临时部署目录附 `Start.cmd`、`Stop.cmd`、`Status.cmd`。停止前通过 API 释放测试 TUN，核对 EXE 路径与 PID，仅删除该测试的精确防火墙组；WSL 转接停止前逐项核对 /proc/PID/cmdline。重启动态读取 WSL 地址，重建两组转接并默认连接 ARM64 TCP。已实际停止/重启，再分别切换 ARM64/ARMv7 QUIC，复核两个对端大包 ping 零丢失，最后切回 ARM64 TCP，保持两个对端在线。

原正式客户端 `C:\Program Files\VNT App\vnt_app.exe` 保持运行；原有 `vnt-tun`（192.168.111.33/24）及 `VNT-App-TUN-cfg-10e9a9095ae0ef29`（10.10.10.3/24）未替换。临时测试 HTTP 服务和 guest 文件已在验收器 finally 中清理；运行报告、命令日志、重启复核及当前 PID 仅保存在忽略目录。

交付报告为 `dist/windows-arm-interop/interop-report.json` 和 `restart-check.json`。Windows 原生构建使用 Rust 1.95/MSVC、`cargo build --release --locked --target x86_64-pc-windows-msvc`，独立 CARGO_TARGET_DIR，opt-level=s、thin LTO、单 codegen unit、panic=abort。临时版保留四套档案和配置；ARM VM 依赖 WSL 持续运行。此验收属于短时、受控负载的跨平台中继互通，未覆盖公网 P2P、真实路由器或长期压力测试。

源码提交至独立分支 `codex/openwrt-arm`，当前工作区分支 `codex/windows-system-service` 同时有其他任务修改；通过独立 Git 索引与 compare-and-swap 更新任务分支，不切换工作区、不提交其他任务文件、不推送 GitHub。下一步：用户通过 Windows 管理页面确认界面及档案操作；后续物理路由器部署仍需明确机型、CPU/ABI 和可用资源。

## LAN 网关与监控服务（2026-11-02，已完成）

用户进一步授权实现并验证：B 的普通 LAN 设备免装 VNT，访问 B 本地路由器、A 虚拟 IP 的服务及映射端口，以及 A 的 LAN 设备；反向同理。不得改动现有物理路由器和 Windows 业务网络。

已实现 `linux_webui/src/openwrt_routes.rs`：连接后添加输入网段的系统路由，断开时只清理本连接新增路由；拒绝默认/虚拟网段覆盖、重复网段和已有同前缀路由冲突。`openwrt/files/vntc-gateway` 按 UCI 配置生成限定网段的 LAN/TUN 转发、源地址转换和 TCP/UDP DNAT，默认关闭、无常驻进程；安装、卸载、配置保留和 sysupgrade 集成已补齐。专用 VNT 分区启用 TCP MSS 调整。

29 项 OpenWrt musl 测试通过；ARM64/ARMv7 新客户端已编译，候选修订号 `4.8.40-2`，原 `dist/openwrt-arm/` 保留不覆盖。新产物和验证记录在 `dist/openwrt-gateway/`。`tools/openwrt/verify_gateway.py` 复用现有 VM，利用 ip-full/kmod-veth 在每台 guest 创建独立的 `vntc_lan` 命名空间；LAN 终端无 VNT 网卡，仅通过路由器默认网关通信。测试专用服务位于 `/opt/vntc-gateway-test/`，由独立 procd 测试服务管理，不装入正式插件；原业务配置已备份到 guest `/root/vntc-gateway-backup/`。

首轮无节制叠加大文件、四路视频及高频 UDP，观察到单 vCPU TCG guest CPU 满载、40 包中 4 包未及时收到、最长约 14 秒 RTT；属于失败记录，不计为稳定性通过。已修正 fw4 NAT 不能使用目标列表却返回检查成功的问题，并加入 MSS 调整。随后用明确负载边界重新验证：文件源每台约 64KiB/s、分组双向 RTSP/H.264、持续 UDP 和大包，全部通过；保留首轮报告及原始日志。该结果不代表满带宽通过。

UCI 候选配置必须同时用 `-c` 和 `-t` 隔离正式文件与暂存目录；实测无效映射、名称冲突之后，正式防火墙和全局暂存区均保持原样。只操作有所有权记录的规则，保留其他同前缀规则。已有路由冲突测试以协议号过滤确认原路由未被覆盖（ip-full 会把协议 187 显示为 isis）。

最终每种架构通过 8 组网关数据面/边界/重启检查和 3 组所有权/卸载/重装检查：

| 架构 | TCP 阶段 | QUIC 阶段 | 文件校验 | RTSP 完整性 | UDP 回显 | 1300 字节 ping |
| --- | ---: | ---: | --- | --- | --- | --- |
| ARM64 | 82.390 秒 | 82.594 秒 | 6MiB、24 次 SHA-256 一致 | 8 次视频流 SHA-256 一致 | 480 次零丢失/损坏 | 320 包零丢失 |
| ARMv7 | 82.000 秒 | 82.062 秒 | 6MiB、24 次 SHA-256 一致 | 8 次视频流 SHA-256 一致 | 480 次零丢失/损坏 | 320 包零丢失 |

每个协议阶段：两方向各 3 轮，每轮分别用远端 LAN IP 与虚拟 IP 映射端口下载 256KiB 文件；随后两方向分别验证直接 LAN RTSP 和映射端口 RTSP，每次传输 20 秒、200 帧 H.264 测试片。全程并发 4 条 60 次、1300 字节 UDP 回显，以及两方向各 80 个大包 ping。逐次验证文件/压缩视频 SHA-256、RTP 包序号、回显数据和进程 PID，两个服务端和客户端无意外重启。

两种架构均实际执行客户机 reboot，boot_id 改变后自动恢复测试 LAN、服务、网关规则、输入路由和远端文件访问；正常退出前 sync。IPK 卸载后受管规则清理，配置保留；离线安装、离线卸载与重装均恢复远端服务，并保留专门构造的同前缀非受管规则及原有防火墙配置。B 节点最终为离线安装，仍由 procd 管理。

Windows 原生临时客户端又完成两架构、两协议的映射端口访问，8 个 256KiB 文件 SHA-256 一致；FFmpeg 从两架构 A 节点的 `rtsp://10.26.0.2:18554/live` 实际解码，各 200 帧逐帧 SHA-256 与本机原始视频全一致。注册完成后首个服务探测需一次重试，四次切档案均约 20 秒完成两端探测和下载（包含文件传输时间）；就绪后传输正常。最终 Windows 回到 ARM64 TCP，两个对端在线。

交付目录 `dist/openwrt-gateway/` 包含三种架构的新客户端 IPK/离线包（4.8.40-2），ARM64/ARMv7 同时附原 SHA-256 不变的 VNTs 2.0.0-1 包。x86_64 通过 29 项 musl 测试、默认非 OpenWrt feature 的 cargo check、release 构建和包/ELF 校验，本轮未另跑 x86 网关 VM。`collect_gateway.py` 已核对所有离线包内部校验、IPK/离线机器码与脚本一致，以及四台 guest 实装客户端/网关脚本和两台服务端程序哈希。

本次采样 vntc RSS：ARM64 6992/6780KiB，ARMv7 7196/7120KiB；服务端 RSS 为 7996/7416KiB。网关 helper 无新增常驻进程，样本受测试后缓存和运行负载影响，不能据此承诺实机总内存。原 Windows 正式客户端与业务网络不作替换。

当前 A LAN 为 192.168.50.0/24、B LAN 为 192.168.60.0/24；虚拟 IP 分别为 10.26.0.2/3。测试映射为 18081→HTTP 18090、18554→RTSP 8554、UDP 18082→18092；六个管理页面地址保持前文所列。用户可通过 Windows 临时版确认虚拟端口访问；模拟 LAN 地址只在各自 guest 的终端命名空间内使用，不向宿主物理 LAN 桥接。物理摄像头、ONVIF 广播发现、动态 RTP/UDP 端口、公网 P2P、满载及长时间运行未计入本次验收。

任务实现与本地部署全部完成，保留 VM 和 Windows 临时版运行。使用说明和无凭据清单见交付目录；最终结果为两份 report.json、两份 lifecycle.json、Windows report.json、manifest.json。仅作本地独立索引提交，不推送 GitHub。后续真机部署需要实际机型、CPU/ABI、LAN 网段与摄像头服务参数。

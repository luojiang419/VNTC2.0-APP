# ARM 交叉构建与 OpenWrt 验收

## Rustup 并行安装竞争

表现：服务端和客户端同时下载相同 rust-std 时，一个进程完成后另一个报 `.partial` 文件无法重命名，随后回滚。

根因：rustup 的组件下载不适合作为多个构建任务的并行初始化阶段。

解决：`tools/openwrt/build-common.sh` 使用用户级 flock 串行化组件安装，编译阶段仍可独立进行。已安装 aarch64 与 ARMv7 标准库，两个客户端和两个服务端静态 release 构建完成。

## WSL 默认 cc 指向 Zig/glibc

表现：对 x86_64 musl 执行 cargo test 时，出现 `_start`、`_init`、`_fini` 重复定义，来源同时包含 glibc 的 Scrt1.o 和 Rust 自带的 musl rcrt1.o。

根因：当前环境的 cc 包装器默认目标为 glibc，不能直接用作 musl 链接器。

解决：x86_64 musl 显式设置 `CC_x86_64_unknown_linux_musl=musl-gcc` 和 `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc`。ARM 通过 cargo-zigbuild 注入对应目标工具链。修复后客户端 28 项 musl 测试通过。

## OpenWrt 不写日志文件后原集成测试超时

表现：WireGuard 密钥轮换与 UDP 集成测试等待身份初始化超时，但子服务端仍在运行。

根因：旧测试通过临时 `logs/vnts2.log` 中的公钥事件观察初始化；OpenWrt feature 已改为控制台日志且默认 warn，因此不能沿用文件日志采集方式。

解决：OpenWrt 日志级别支持 `RUST_LOG=info`；仅在测试进程中将控制台输出捕获到隔离临时目录。保留原有公钥、在线互斥、轮换、认证和 UDP 断言。身份轮换 1 项、主密钥轮换 1 项、管理 API 3 项、UDP 5 项均通过；路由器产品仍不创建日志文件。

## ARMv7 并不等同于所有 ARM

静态链接解决 libc 依赖，不能解决 CPU 指令集或浮点 ABI 差异。本次 ARMv7 包是 hard-float，要求 VFPv3/VFPv4，不适合 ZX279128S 这类没有 VFP 的芯片。打包器检查 ELF Machine、位数、hard-float 标记与动态加载器；真实路由器还需核对 `opkg print-architecture`。已验证 x86/ARM 混标打包会拒绝。

## 验收边界

QEMU user 的 `--help` 只证明用户态程序能启动；完整 OpenWrt 中的安装、TUN、加密数据面和生命周期需要单独执行 `tools/openwrt/verify_arm.py`。官方 kernel/rootfs/kmod-tun 必须属于同一发行版和子目标，并通过官方 SHA-256。完整结果以 `ARM适配与验证.md` 和交付目录中的 report.json 为准。

## ARM32 TCG 重启等待

本机默认 virt/Cortex-A15 首轮重启在 `Restarting system` 后未能于 SSH 的 180 秒等待内恢复。启用 `virtualization=on` 后独立热重启检查通过（QEMU PID 不变且 boot_id 改变）；在双节点接力中，串口已进入第二次 Linux 引导，但用户态启动仍超过原等待期限。

ARMv7 验证器将 SSH 等待上限单独提高到 420 秒，x86_64 默认保持 180 秒。使用 `--resume-run` 保存历史报告/串口，检查包哈希不变后复用磁盘；冷启动和真正的客户机热重启分别记录，不以重建 QEMU 代替热重启。

## QEMU 直接退出使新复制文件尾部未持久化

表现：ARM64 完成离线安装及当场通信后，测试脚本直接 SIGTERM QEMU；下一次冷启动服务端无法运行。guest 内的程序长度变成 8388608 字节，而原包及解压副本是 8867984 字节。

根因：测试器把直接停止 QEMU 当作普通退出，没有先等待 guest 文件系统刷盘，实际制造了安装后突然断电。原安装包校验正常，修复时与包内机器码 SHA-256 一致，业务配置哈希不变。

解决：ARMVM.stop 在 SSH 可用时先执行 sync 再退出 QEMU。用同一已验收离线包恢复测试机，确认长度/哈希、服务端启动和客户端注册，再执行冷启动连续通信检查。报告保留 environment-recovery.json 的恢复证据；不宣称对路由器断电耐久性已验收。

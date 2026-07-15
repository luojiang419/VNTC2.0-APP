# Windows 正式服务便携迁移与 C 盘旧部署清理（模块 8.4）

## 目标

将实际运行的 `vnts2` Windows 服务从 `C:\ProgramData\VNTS2` 迁入 `windows-deploy`，使程序固定位于便携根目录，所有可变运行数据只位于同级 `data`，并清除可能误导后续操作的 C 盘旧目录和根目录旧配置。

## 迁移前保护

- 创建阶段备份 `backup/062_VNTS2.0_移除C盘旧服务与正式迁移_20260715`。
- C 盘旧部署备份 45 个文件，总大小 71,263,908 字节。
- 备份中的配置、SQLite 数据库和 WireGuard 主密钥与原文件 SHA-256 分别一致。
- 备份含真实配置和密钥，仅用于本机故障恢复，不进入发布包。

## 迁移冲突保护

真实迁移前发现目标 `data\.backups` 和旧部署 `.backups` 同时存在。更新脚本已改为：

- 递归合并 `logs` 和 `.backups`，保留两边原有文件。
- 目标存在同名同哈希文件时安全跳过。
- 目标存在同名不同内容时立即停止，不覆盖任何一方。
- 拒绝跟随迁移源中的重解析点。
- 每个新复制文件都在写入后复核 SHA-256。

独立临时 Windows 服务端到端测试已实际验证“目标已有备份目录”场景：迁移后服务恢复 Running，目标原备份、源备份和源日志全部保留。

## 正式切换结果

- Windows 服务名仍为唯一的 `vnts2`，没有创建第二个重复服务。
- 程序路径：`D:\Myproject\vnt2.0\vnts2.0服务端开发包\windows-deploy\vnts2.exe`。
- 配置路径：`D:\Myproject\vnt2.0\vnts2.0服务端开发包\windows-deploy\data\config.toml`。
- GUI 状态模型返回 `Installed=true`、`State=Running`、`PortableLayout=true`。
- 最终 PID 为 36880，进程实际可执行路径与服务 ImagePath 均指向 D 盘便携根目录。
- 迁移后配置、证书、私钥和 WireGuard 主密钥与旧目录哈希一致。
- SQLite `PRAGMA quick_check` 结果为 `ok`。

## 网络与防火墙验收

- TCP：`0.0.0.0:2222`、`127.0.0.1:29871`。
- UDP：`0.0.0.0:2222`、`192.168.100.102:41194`、`192.168.100.102:41195`。
- Web 控制台首页返回 HTTP 200。
- WireGuard 入站规则 `VNTS2-WireGuard-LAN-UDP-41194` 已改为 D 盘程序路径。
- Peer QUIC 入站规则 `VNTS2-Peer-QUIC-LAN-UDP-41195` 已改为 D 盘程序路径。
- 服务诊断：`Failures=0; Warnings=0`。

## 旧路径清理

1. 先将 `C:\ProgramData\VNTS2` 改名为带时间戳的隔离目录。
2. 在 C 盘旧路径不存在的情况下重启正式服务。
3. 重新验证进程路径、TCP/UDP 端口和 Web HTTP 200。
4. 通过后删除隔离目录。
5. 删除 D 盘根目录已备份且不再使用的 `config.toml`，并移除空的根目录 `logs` / `.backups`。

最终检查：C 盘旧目录不存在，无隔离目录残留，所有 Windows 服务、运行进程和防火墙程序过滤器中对 `C:\ProgramData\VNTS2` 的引用数均为 0。

## 发布和回归

- 最新 Windows ZIP：3,868,117 字节，SHA-256 `01DF3405E62A91D7363B2BBD899AB5108A6F77E24722D7E11E49A112530129B8`。
- 服务脚本、PowerShell GUI、原生 GUI EXE 和可重复发布包契约测试通过。
- 独立 Windows 服务安装、迁移、启停、诊断和卸载端到端测试通过。
- 无测试服务、GUI 进程或临时构建目录残留。

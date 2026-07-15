# Windows 便携发布构建与根目录产物（模块 8.3）

## 目标

确保开发目录、正式 ZIP 和最终便携根目录使用同一份 Release `vnts2.exe`、同一份原生 GUI 以及同一套便携服务脚本，消除根目录旧二进制被误安装的可能。

## 发布构建规则

- 默认构建只写入 `dist`，不改动便携根目录。
- `-SyncPortableRoot` 必须显式指定，才会将构建验证过的 `vnts2.exe` 和 `VNTS2-Manager.exe` 同步到便携根目录。
- 同步前按 SHA-256 判断是否需要替换；旧文件先复制到 `data\.backups`并复核哈希。
- 新文件先写入同目录临时文件，验证哈希后原子替换，替换后再次验证。
- 构建器会先运行原生 GUI 验证模式，只接受 `PortableDataRelativePath=data` 且 `ExistingDeploymentAction=MigrateExistingService` 的新版管理器。
- 发布包只包含空 `data/README.txt`，不包含真实配置、日志、数据库、密钥或备份。

## 正式产物

- 根目录 `vnts2.exe`：7,345,664 字节，SHA-256 `4793E6B9FEC7E531B6C7581DACBF4EF9CFBD2BF43D18F90EB09CF8A0A41F162A`。
- 根目录 `VNTS2-Manager.exe`：37,888 字节，SHA-256 `754D5AC62304099225FBDEB0A41F9D805CFECA296086C7F29456C95909066798`。
- 根目录与 staging 中的两份二进制分别同哈希。
- ZIP：`vnts2-2.0.0-windows-x64.zip`，3,867,733 字节，SHA-256 `EE51EF4E2E9B4D13889FB43ECD04056757B036CF15990B05C580C6A03A72DC67`。
- `MANIFEST.json` 记录 19 个白名单文件，`SHA256SUMS.txt` 记录 20 个包内文件，均包含 `data/README.txt`。

## 验收

- Windows 服务运维脚本契约测试：通过。
- PowerShell GUI 契约测试：通过。
- 原生 GUI EXE 契约测试：通过。
- 可重复发布包契约测试：通过，包括默认不同步和显式同步备份/替换两条路径。
- ZIP 实际哈希与外部 `.sha256` 记录一致。
- 当前正式服务保持 Running、PID 38600，ImagePath 仍指向 `C:\ProgramData\VNTS2`，本模块没有停止、迁移或重启它。

## 阶段边界

便携 `data` 目录当前只包含说明文件和根目录旧程序备份，故意尚未生成 `data/config.toml`。根目录的历史 `config.toml` 仍保留但不被新脚本使用。正式 C 盘数据迁移、服务 ImagePath 切换和历史文件清理由模块 8.4 独立执行。

# Windows 便携 GUI 路径与迁移交互（模块 8.2）

## 目标

原生 WinForms GUI 和 PowerShell 兼容 GUI 使用同一套便携目录语义，避免再次把开发目录中的旧程序或根目录 `config.toml` 注册成服务。

## 状态展示

GUI 状态区现在同时显示：

- 程序路径：当前服务实际注册的 `vnts2.exe`；未安装时显示当前 GUI 同目录程序。
- 配置路径：当前服务实际注册的配置；未安装时显示 `data\config.toml`。
- 数据目录：当前服务配置所在目录；未安装时显示同级 `data`。

已安装服务分为：

- `便携部署`：程序位于 GUI 同目录，配置位于同目录 `data`。
- `待迁移部署`：程序或配置仍位于其他目录，例如旧的 `C:\ProgramData\VNTS2`。

## 首次安装

点击“安装并启动”时，如果 `data\config.toml` 不存在，GUI 自动：

1. 创建同级 `data`；
2. 从只读 `config.example.toml` 复制配置；
3. 调用便携安装脚本。

默认模板未启用 Web 管理端，不需要预置密码。之后点击 Web 控制台时，原生 GUI 继续使用原有的加密安全随机密码、配置备份和回环地址限制。

## 已有部署迁移

检测到其他路径中的同名服务后：

- 状态显示“待迁移部署”；
- 主按钮显示“迁移并启动服务”；
- 确认框展示目标程序和目标 data 目录；
- 默认按钮为“否”；取消不产生写入；
- 确认后调用更新脚本，并同时传入 `-TargetDir`、`-SourceExecutable` 和 `-MigrateExistingData`。

GUI 不自行复制数据库或密钥，迁移、哈希验证与失败回滚全部由模块 8.1 的事务脚本负责。

## 验收

- PowerShell GUI 语法检查：通过。
- PowerShell GUI 状态模型：当前正式 C 盘服务识别为 `ExistingDeployment`，动作识别为 `MigrateExistingService`。
- C# WinForms 源码编译：通过。
- 临时验证 EXE：x64，37,888 字节，SHA-256 `26220C3FD978FDE0E0614AFC98ED72E7F05C3E9F06C39B74FC0971E27BE54FF2`。
- 临时 EXE 模型：`PortableDataRelativePath=data`，`ExistingDeploymentAction=MigrateExistingService`。
- 服务脚本、两套 GUI、原生 EXE 与发布包契约测试：全部通过。

本模块没有替换正式 GUI 二进制，也没有迁移或停止当前正式服务。

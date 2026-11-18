# Windows 服务升级错误 193 与安装器误报成功

## 表现

安装器以退出码 0 完成，但 VntCoreService 停止；`sc.exe start` 返回 193（不是有效的 Win32 应用程序）。直接运行同一服务 EXE 的 `--validate-config` 成功，说明程序本身可执行。

## 根因

安装器调用系统 Windows PowerShell 5.1。脚本通过 `sc.exe config` 传递包含嵌套双引号的 binPath，PowerShell 的原生命令参数转换丢掉内部引号，SCM 中 ImagePath 变成未加引号的 `C:\Program Files\VNT App\vnt_service.exe`。服务注册成功并不代表启动路径正确。

旧安装器把脚本放在 Inno `[Run]` 项中，未检查子进程退出码；服务脚本已报错，外层安装仍显示成功。

## 解决

- 升级已有服务时用 `Invoke-CimMethod -MethodName Change` 的结构化 `PathName` 参数写入包含双引号的完整 EXE 路径，并检查 ReturnValue。
- 完整安装中同步执行服务脚本、等待结束并检查退出码；失败必须中止安装，不能仅依赖 Inno 的成功提示。
- 包含中文注释的 PowerShell 5.1 脚本保存为 UTF-8 BOM。
- 分别验证“新装”和“已注册服务覆盖升级”，路径中必须带空格。

## 验证记录

2026-11-17：直接 Windows PowerShell 5.1 执行修复脚本返回 0，SCM ImagePath 保留引号且服务 Running。本机完整覆盖安装返回 0，9 个业务文件原哈希不变，聊天 SQLite 完整性和各表记录保留检查通过。第二轮 CI 的含空格目录新装、覆盖升级两轮安装均通过。

相关实现：`scripts/install_vnt_service.ps1`、`scripts/export_installer_package.ps1`；隔离 CI 验收：`scripts/test_windows_installer_service.ps1`。后者拒绝在非 GitHub Runner 或已经存在 VNT 核心服务的环境运行，防止误操作本机业务服务。

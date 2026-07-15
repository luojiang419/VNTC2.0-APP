# Windows 便携 data 目录架构（模块 8.1）

## 目标

VNTS2 不再把程序、配置或运行数据部署到 `ProgramData`。发布目录可以整体复制到其他磁盘或文件夹；以管理员身份运行同目录 GUI 后，即可重新注册并启动 Windows 服务。

Windows 服务注册信息仍由 SCM 保存，这是 Windows 服务工作的必要条件；除此之外，不在发布目录外创建 VNTS2 文件。

## 目录契约

```text
VNTS2/
├─ VNTS2-Manager.exe
├─ vnts2.exe
├─ config.example.toml
├─ *.ps1
└─ data/
   ├─ config.toml
   ├─ network_control.db
   ├─ cert.pem
   ├─ key.pem
   ├─ wireguard-master.key
   ├─ logs/
   └─ .backups/
```

- 根目录只放程序、GUI、管理脚本和只读配置模板。
- `data` 保存全部可变状态；配置文件所在目录也是服务工作目录。
- 服务启动命令固定为：根目录 `vnts2.exe` 加同根 `data\config.toml`。
- 安装时根目录和 `data` 都收紧为 SYSTEM/Administrators，避免普通用户替换 LocalSystem 服务程序或读取密钥。
- 卸载只删除 SCM 注册，保留整个便携目录和 `data`。

## 快捷迁移流程

1. 在 GUI 中停止并卸载服务；数据不会删除。
2. 复制整个 `VNTS2` 文件夹到新位置或新电脑。
3. 以管理员身份运行新位置的 `VNTS2-Manager.exe`。
4. 点击安装并启动；SCM 将注册新位置的绝对路径。

若同名服务仍指向旧位置，更新脚本必须显式使用 `-MigrateExistingData`。迁移在停服状态进行，对配置、数据库、证书和 WireGuard 主密钥逐个执行 SHA-256 校验；目标 `data` 已有不同内容时拒绝覆盖。

## 本模块完成内容

- 新增统一便携路径模型和布局识别。
- 安装脚本只接受 `data\config.toml`。
- 更新脚本支持显式跨目录迁移、哈希验证、程序原子替换和 ImagePath 回滚。
- 状态输出新增 `DataPath` 与 `PortableLayout`。
- 诊断新增便携布局、根目录 ACL 和 data ACL 检查。
- 卸载返回数据保留状态和实际数据目录。

GUI 路径展示、自动初始化、按钮文案和真实菜单点击属于下一模块。

## 验收

- PowerShell 语法检查：通过。
- Windows 服务脚本契约测试：通过。
- 隔离临时 Windows 服务安装、重复安装、启动、停止、错误启动、卸载：通过。
- 既有 GUI、原生 GUI 和可重复发布包静态契约：通过。
- 默认正式服务未被本模块测试修改。

# Windows 原生 GUI 网络管理与 WireGuard 快捷操作方案

## 任务目标

用户无需进入 Web 页面，即可在 `VNTS2-Manager.exe` 中完成：

- 查看、新增、编辑和删除网络；
- 设置新网络的组网编号；
- 在每个网络卡片显示可供 VNTC 使用的 QUIC 地址和组网编号；
- 一键复制 QUIC 地址、组网编号或完整连接信息；
- 查看 WireGuard 运行状态和 Peer 列表；
- 一键生成 Peer 密钥、自动分配 IP 和完整客户端配置；
- 复制私钥/配置、保存 `.conf`、启停 Peer、设置/释放 IP 和删除 Peer。

## 核心语义

`quic_bind` 是服务器级监听地址，不是每个网络独立的地址。每个网络独有的字段是 `network_code`，也就是 VNTC 中的“组网编号”。

因此网络卡片展示两项：

- 服务器地址：`quic://host:port`；
- 组网编号：当前网络的 `network_code`。

完整复制文本采用：

```text
服务器地址：quic://host:port
组网编号：office
```

## QUIC 分享地址

当前服务使用 `0.0.0.0:2222`监听，`0.0.0.0` 不能直接作为客户端地址。GUI 增加“QUIC 分享地址”设置：

- 首次自动建议主局域网 IPv4 和当前 QUIC 端口；
- 允许改成公网 IP 或域名；
- 统一规范为 `quic://host:port`；
- 校验协议、主机和 1–65535 端口；
- 保存到便携数据目录 `data/gui-settings.json`；
- 仅用于复制/分享，不静默修改服务监听、NAT 或防火墙。

## 本机 API 访问

GUI 不读写 SQLite 表，全部复用已有服务 API：

- `GET/POST/PUT/DELETE /api/networks`；
- `GET /api/status`；
- `GET/POST/PUT/DELETE /api/wireguard/peers`；
- `GET/PUT/DELETE /api/wireguard/peer_ips`。

安全约束：

- 只允许访问当前服务配置的回环 Web 地址；
- 用户名/密码从当前 `data/config.toml` 读取；
- 登录令牌只存于窗口内存，不写入日志、剪贴板或文件；
- 密码、JWT 和 CSRF 值不显示在操作输出；
- Web 管理接口未启用时，经用户确认后复用现有安全初始化流程，仅绑定 `127.0.0.1`，不打开浏览器。

## 网络管理窗口

主窗口“业务管理”区新增“网络管理”按钮。弹窗包含：

- 服务器状态和 QUIC 分享地址设置；
- 网络列表：组网编号、子网、网关、租期、在线/总设备数；
- 每行的“复制 QUIC”、“复制编号”、“复制全部”按钮；
- “新增网络”弹窗：组网编号、网关、掩码和租期；
- “编辑网络”弹窗：只允许修改网关、掩码和租期；
- 删除前明确确认。

`network_code` 是设备、IP 分配和 WireGuard Peer 的关联键，现有后端也禁止对它直接重命名。GUI 在创建时支持设置组网编号，编辑时显示为只读，避免破坏关联数据。

## WireGuard 管理窗口

主窗口“业务管理”区新增“WireGuard”按钮。弹窗包含：

- 运行/配置状态、UDP 监听、公开端点、服务器公钥和活动 Peer 数；
- 组网编号下拉选择；
- Peer 列表：名称、预留 IP、启用状态、公钥和创建时间；
- 复制公钥、启用/禁用、设置/释放 IP 和删除；
- “新增 Peer”默认使用一键生成模式，也保留“已有公钥”高级模式；
- 生成结果弹窗提供复制私钥、复制完整配置和保存 `.conf`；
- 私钥和完整客户端配置仅在创建结果弹窗中显示一次；
- 关闭前要求用户确认已保存，放弃时可立即删除刚生成的 Peer。

## 模块拆分

### 9.1 本机 API 客户端与网络管理

- 新增回环 API 登录/请求封装。
- 新增 `data/gui-settings.json` 和 QUIC 分享地址校验。
- 新增网络管理列表、创建/编辑/删除弹窗和复制按钮。
- 使用独立临时服务验证 API 与 GUI 模型，不修改正式网络数据。

### 9.2 WireGuard 原生管理弹窗

- 新增状态、Peer 列表、IP 和启停/删除操作。
- 新增一键生成和已有公钥两种新增模式。
- 新增一次性密钥/配置弹窗和 `.conf` 保存。
- 针对错误网络编号、重复 Peer、非法公钥、IP 冲突和服务未启用编写可见错误处理。

### 9.3 发布与真实 GUI 验收

- 重建 `VNTS2-Manager.exe` 和 Windows ZIP。
- 使用原生 GUI 创建/编辑/删除临时网络。
- 验证三种复制按钮。
- 使用原生 GUI 生成临时 WireGuard Peer，验证配置复制/保存后删除。
- 确认正式服务、端口、数据库和原有网络/Peer 数据在测试后恢复原状。

### 9.4 全局收尾

- 运行 Rust、Web、服务脚本、原生 GUI 和发布包回归。
- 清理临时 Peer、临时网络、测试服务和构建缓存。
- 生成进度快照 092。

## 文件/模块清单

- `windows-deploy/gui/Vnts2Manager.cs`：主窗口入口、API 客户端、网络管理和 WireGuard 窗口。
- `windows-deploy/tests/windows-native-gui-manager.Tests.ps1`：原生 GUI 编译和操作契约。
- `windows-deploy/tests/windows-service-e2e.Tests.ps1`：独立服务的本机 API 验收。
- `windows-deploy/build-vnts2-manager-exe.ps1`：如使用新框架程序集，只增加必需引用。
- `windows-deploy/README.md` 和 `README-PACKAGE.md`：客户使用说明。
- `windows-deploy/dist/*`：重建后的正式产物。

## 验收标准

1. GUI 不打开浏览器也能查询和管理网络/WireGuard。
2. 每个网络都能复制正确的 `quic://host:port` 和组网编号。
3. 新增网络后立即出现在列表，编辑/删除遵循后端资源占用限制。
4. WireGuard 一键生成结果可复制并保存为可导入的 `.conf`。
5. 密码、JWT、CSRF 和 WireGuard 私钥不进入 GUI 日志或发布包。
6. 所有可变 GUI 设置位于 `data`，整目录迁移后仍可使用。
7. 原生 GUI 真实点击测试中不出现未处理异常、卡死或命令行窗口。
8. 测试后正式服务保持 Running，原有网络和 Peer 数据不变。

# VNTC 2.0 APP

![VNTC 2.0 APP 首页封面](docs/screenshots/homepage-cover.png)

VNTC 2.0 APP 是一个基于 [VNT](https://github.com/vnt-dev/vnt) 的图形化虚拟组网客户端，在原有组网能力之上，进一步整合了房间大厅、聊天室、私信、远程协助、日志诊断、配置备份恢复等能力，目标是让普通用户也能更轻松地搭建和使用自己的虚拟局域网。

这个仓库当前以源码为主，适合二次开发、功能定制、构建打包和问题排查。

- English introduction: [README_EN.md](README_EN.md)

## 界面预览

首页封面展示的是软件主界面。以下为各主要页面实拍截图，便于用户快速了解实际 UI 和功能入口。

<table>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-01-dashboard.png" alt="仪表盘页面" />
      <br />
      <sub>仪表盘：连接状态、流量、延迟、设备概览</sub>
    </td>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-02-room.png" alt="房间页面" />
      <br />
      <sub>房间：大厅、聊天室、私信与联调入口</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-03-link-status.png" alt="链接状态页面" />
      <br />
      <sub>链接状态：设备列表、路由与链路观察</sub>
    </td>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-04-config.png" alt="配置管理页面" />
      <br />
      <sub>配置管理：新建、导入导出、排序与编辑</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" align="center">
      <img src="docs/screenshots/detail-05-settings.png" alt="设置页面" />
      <br />
      <sub>设置：默认配置、自启动、备份恢复等</sub>
    </td>
    <td width="50%" align="center">
    </td>
  </tr>
</table>

## 项目特色

- 图形化管理 VNT 组网配置，不需要长期手写命令行。
- 在一个客户端里同时完成连接、查看状态、交流协作和远程协助。
- 提供默认大厅、房间、私信三层沟通入口，适合多设备和多成员协作。
- 远程协助走 VNT 虚拟 IP 直连，已内置 RustDesk 会话密码链路和清理机制。
- 桌面端补齐了系统托盘、关闭行为、自启动、日志导出、联调诊断等实用能力。
- 配置支持新建、编辑、导入、导出、排序、默认配置、整机备份与恢复。

## 主要功能

### 1. 虚拟组网连接

- 新建和编辑 VNT 配置，支持常见组网参数填写。
- 支持默认配置、自动连接、启动时自动接入。
- 支持多配置管理和拖拽排序。
- 支持导入单个配置、导出单个配置、整机备份和整机恢复。

### 2. 仪表盘

- 实时查看连接状态、设备数量、在线离线数量。
- 展示上下行总流量、实时速率、速度曲线。
- 展示虚拟 IP、设备名、服务器、协议、NAT 类型。
- 展示平均延迟、丢包率、加密状态和加密算法。

### 3. 链接状态

- 分设备查看当前已连接节点。
- 分路由查看链路情况。
- 支持延迟历史趋势观察。
- 支持查看当前设备信息，方便排障和联调。

### 4. 房间 / 大厅 / 私信

- 连接组网后自动创建默认大厅。
- 支持创建房间、切换房间、进入公共大厅。
- 支持私信会话和在线成员快速发起一对一沟通。
- 支持聊天室联调诊断和聊天本地数据清理。

### 5. 聊天协作

- 支持文字消息。
- 支持图片发送。
- 支持文件发送。
- 支持语音消息能力，平台环境允许时可直接使用。

### 6. 远程协助

- 在聊天/私信链路中发起远程协助。
- 当前远程协助使用内置 RustDesk 运行时，不依赖系统已安装版本参与实际连接。
- 基于 VNT 虚拟 IP 和会话密码建立直连。
- 已补齐接受、拒绝、取消、结束、失败时的会话态清理。
- 已补齐 Windows 防火墙监听检测和软失败提示，降低误判和卡死概率。

### 7. 平台集成与运维能力

- 支持系统托盘与关闭按钮行为配置。
- 支持日志实时查看、复制、导出、清空。
- Android 侧包含磁贴/小组件相关支持。
- iOS 侧包含 VPN Extension、Widget、Intent 等工程结构。

## 页面总览

- `仪表盘`：看全局状态、流量、延迟和设备概览。
- `房间`：进入大厅、房间、聊天室和私信。
- `链接状态`：看设备和路由细节。
- `配置`：管理所有组网配置。
- `设置`：设置自启动、自动连接、默认配置、备份恢复等。
- `关于`：查看开源来源、帮助入口和联系方式。

## 适用场景

- 家庭或异地设备组网
- 办公电脑与个人设备互联
- 小团队远程协作和临时沟通
- 游戏联机或局域网替代场景
- 远程排障、远程协助和联调测试

## 平台支持

- Windows
- macOS
- Linux
- Android
- iOS

## 快速开始

### 作为使用者

- 打开软件后先创建或导入组网配置。
- 设置默认配置后，可启用自动连接。
- 连接成功后，可在仪表盘查看状态，在房间页进入大厅、聊天室或私信。
- 需要远程协助时，可在对应会话内直接发起。

### 作为开发者

先安装以下环境：

- [Flutter](https://docs.flutter.dev/get-started/install)
- [Rust](https://www.rust-lang.org/tools/install)
- `flutter_rust_bridge_codegen`（仅在需要重新生成桥接代码时）

常见开发启动方式：

```bash
flutter pub get
flutter run
```

Windows 打包脚本位于：

- `scripts/build_windows.bat`
- `scripts/build_windows_installer.bat`

## Android 构建说明

为避免公开仓库在 GitHub Push Protection 下再次被拦截，仓库当前已经移除了：

- `android/app/src/main/jniLibs/`

这意味着：

- 当前公开仓库默认不带 Android 预编译 Rust `.so`。
- 如果你要自行构建 Android 版本，需要先重新生成或补齐对应 `jniLibs` 产物。
- 仓库中的 `.github/workflows/build.yml` 保留了多平台构建流程和 Android 侧重建 `.so` 的参考步骤，可按你的分支策略继续调整使用。

## 开源来源

本项目建立在以下开源项目基础之上：

- VNT Core: [vnt-dev/vnt](https://github.com/vnt-dev/vnt)
- Original GUI Project: [lmq8267/VntApp](https://github.com/lmq8267/VntApp)

当前仓库侧重于面向实际使用场景的客户端体验增强与桌面协作能力补充，包括但不限于：

- 房间大厅和私信交互
- 聊天附件和语音链路
- 内置远程协助流程
- Windows 打包与诊断增强
- 配置备份恢复与快捷入口能力

## 说明

- 当前 README 重点描述的是仓库内已经落地的功能和源码能力。
- 如果你是为了二次开发，建议优先阅读 `lib/`、`rust/`、`scripts/` 与最近的 `进度快照`。
- 如果你是为了直接使用软件，建议优先获取对应平台的打包版本，而不是直接从源码目录运行构建产物。

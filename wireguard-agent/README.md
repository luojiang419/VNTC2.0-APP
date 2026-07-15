# VNTS WireGuard 受管 Agent

`vnts-wireguard-agent` 让已接入 VNTS 的 WireGuard 用户与桌面 VNTC 用户建立真实点对点通信。Agent 通过已认证的 WireGuard 隧道向网关发现目标，只在直连握手成功后为目标安装 `/32` 路由。

## 前置条件

- WireGuard 接口已能连接 VNTS，其公钥与服务端 peer 记录一致。
- 服务端 peer 已启用并预留 IPv4。
- 服务端 peer 的 `AllowedIPs` 包含整个 VNT 子网，例如 `10.26.0.0/24`；这保证控制请求经服务端到达网关，也作为直连失败时的回退路由。
- 系统已安装 WireGuard 命令行 `wg`/`wg.exe`，Agent 以可管理该接口的权限运行。
- 目标 VNTC 与 WireGuard peer 连接同一台 VNTS，且 VNTC 使用 Windows/macOS/Linux 桌面运行时。

## 运行

Windows 示例：

```powershell
.\vnts-wireguard-agent.exe `
  --interface wg-vnts `
  --gateway 10.26.0.1 `
  --target 10.26.0.10
```

Linux 示例：

```bash
sudo ./vnts-wireguard-agent \
  --interface wg0 \
  --gateway 10.26.0.1 \
  --target 10.26.0.10 \
  --target 10.26.0.11
```

`--wg <path>` 可指定 `wg` 程序路径。按 `Ctrl+C` 退出时，Agent 会删除自己管理的直连 peer。

## 运行语义

- 控制端口为虚拟网关 UDP `51821`，只能从已认证 WireGuard 会话内访问，无额外 HTTP 凭据。
- 租约有效期 60 秒，Agent 每 20 秒刷新。
- 探测阶段不配置 `AllowedIPs`；握手成功后才安装目标 `/32`。
- 发现失败、握手超时、租约失效、peer 撤销或 VNTC 离线时，Agent 删除直连 peer；原 VNTS 子网路由随即恢复中继。
- VNTC 仅在最近 45 秒内观测到认证直连流量时选择直连，否则使用现有 `WireGuardRelay(18)`。

## 边界

- 首版只做同服务器 IPv4 单播；跨服务器、IPv6、广播和组播继续中继或拒绝。
- MTU 上限为 1420，不做服务端分片、重组或 MSS 修改。
- Android/iOS VNTC 因原生 VPN socket protection 边界暂不开启直连，保持服务端中继。
- UDP NAT 穿透无法建立时不会中断业务，但数据会经 VNTS 转发。

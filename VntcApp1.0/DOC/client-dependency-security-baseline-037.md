# 客户端依赖安全基线修复（037）

## 目标与范围

本阶段独立修复 `VntcApp1.0` Rust 依赖锁文件中已知的 RustSec 漏洞、unsound 与 yanked 版本，并建立可重复执行的 `cargo deny` 策略。它不改变 WireGuard 模块 5.2 数据面行为，也不修改 Android 原生 bridge/runtime、聊天、页面、model、版本或构建脚本。

## 修复结果

| 类别 | 修复前 | 修复后 |
| --- | ---: | ---: |
| RustSec vulnerabilities | 5 | 0 |
| unsound advisory | 1 | 0 |
| yanked 依赖 | 2 | 0 |
| `cargo deny` 策略 | 缺失 | 四类检查通过 |

关键升级为 `quinn 0.11.11`、`quinn-proto 0.11.16`、`rustls 0.23.42`、`rustls-webpki 0.103.13`、`anyhow 1.0.103`、`futures 0.3.32`、`spin 0.9.9` 和 `zeroize 1.9.0`。所有升级都落在已有直接依赖约束内，没有引入框架大版本迁移。

## 策略设计

`deny.toml` 对 Windows、Linux、Android、macOS、iOS 的全部 feature 依赖图执行统一检查：

- 漏洞和 unsound advisory 必须失败关闭，且 `ignore` 为空。
- 工作区自身的未维护 advisory 必须失败；第三方传递依赖的未维护状态保留为可见告警。
- 只允许项目实际需要的许可证集合。
- 禁止通配依赖、未知 registry 和未知 Git 来源。
- 唯一允许的 Git 仓库是已有的 `tcp_ip`，并继续由精确 revision 锁定。
- 重复版本暂时告警，不为消除告警而扩大到不相关依赖重构。

本地 `rust_lib_vnt_app` 与 vendored `vnt-core` 标记为 `publish = false`。本地 path 依赖补充精确版本，`tcp_ip` 同时保留精确 crate 版本与原有 Git revision，使来源策略和 Cargo 解析契约一致。

## 剩余告警

`cargo audit` 仍报告 `adler`、`derivative`、`instant`、`paste`、`yaml-rust` 五个第三方未维护告警，但返回成功且不存在漏洞。这些都是现有传递依赖；本阶段不进行高风险的大范围依赖替换，也没有使用 advisory 忽略项隐藏它们。

`cargo deny` 还显示既有重复版本和 `allo-isolate` 缺少 license field 的告警；许可证、来源、漏洞和禁止项检查均实际通过。

## 验证

```text
Rust fmt/check/clippy                         通过
vnt-core                                     23/23
Rust 适配层                                  4/4
Flutter analyze                              0 issues
Flutter tests                                171/171
VNTS 模块 1–5.1 服务端兼容回归                65/65
cargo audit                                  0 vulnerabilities
cargo deny                                   advisories/bans/licenses/sources ok
Windows Flutter release                      通过
Android Flutter release APK                  通过
git diff --check                             通过
```

产物：

```text
rust_lib_vnt_app.dll  10,080,768 bytes
SHA-256 98E4CE53230A5BB1B7E6B1A92FADE48B769B2BA5FFBD5ACF8689ABB315D87C4B

vnt_app.exe           187,392 bytes
SHA-256 0D26AD306236A4F63BC114911411319557BDFEFF77FFBFA3A3CCC9E01FB95CAA

app-release.apk       68,126,483 bytes
SHA-256 F00A5EA71D79C46144585AAFC0B05659C640E10B103EEB47346EF7699EA78C98
```

Windows 构建已确保 `C:\Program Files\NASM` 优先。Apple 原生 release 受 Windows 主机限制未执行；其依赖图已由 `cargo deny` 覆盖，不能等同于真实 Apple 链接验收。

## 结论

客户端依赖安全基线已从“已知漏洞且无 deny 策略”提升为“零已知漏洞、来源与许可证策略可复验、Windows/Android 可出包”。WireGuard 模块 5.2 功能行为与模块 1–5.1 服务端兼容回归保持通过。

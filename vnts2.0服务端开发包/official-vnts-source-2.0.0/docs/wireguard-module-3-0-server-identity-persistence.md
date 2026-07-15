# WireGuard 模块 3.0：服务端身份密钥安全持久化

## 范围

本模块只提供每个 VNTS 服务实例一套 WireGuard X25519 静态身份的安全持久化基础。所有虚拟网络共用该服务端身份；只有显式配置主密钥文件时才启用初始化。

本模块不包含 UDP 监听、BoringTun peer 运行时、peer 公钥/PSK、身份轮换、VNT 数据桥接、路由、MTU、HTTP 管理接口或客户端功能。

## 配置契约

```toml
persistence = true
wireguard_master_key_file = 'C:\ProgramData\vnts2\wireguard-master.key'
```

- `wireguard_master_key_file` 未配置：不初始化 WireGuard 身份，既有 VNT 启动语义保持不变。
- 已配置：`persistence` 必须为 `true`，SQLite 必须成功初始化。
- 主密钥文件必须由部署方预先创建，内容严格为 32 字节二进制；不接受十六进制、Base64、口令文本或尾随换行。
- 路径相对于配置文件所在工作目录解析；生产环境应使用绝对路径。
- 主密钥文件不得放入源码、SQLite 数据目录、阶段备份或常规日志采集目录。

PowerShell 生成示例：

```powershell
$key = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
[System.IO.File]::WriteAllBytes('C:\ProgramData\vnts2\wireguard-master.key', $key)
```

生成后应使用 Windows ACL 移除继承，只向实际 VNTS 服务账户授予读取权限。Linux 部署应将文件所有者设为服务账户并使用 `chmod 600`。

## 数据模型

SQLite schema 从 v1 升至 v2，新增单行表 `wireguard_server_identity`：

| 字段 | 约束 | 含义 |
| --- | --- | --- |
| `id` | 只能为 `1` | 每实例唯一身份 |
| `format_version` | 当前为 `1` | 密文格式与算法版本 |
| `encryption_key_version` | 正整数，当前为 `1` | 为停机原子主密钥轮换预留 |
| `nonce` | 24 字节 | XChaCha20-Poly1305 随机 nonce |
| `ciphertext` | 48 字节 | 32 字节私钥密文及 16 字节认证标签 |
| `public_key` | 32 字节 | X25519 公钥，可明文保存 |
| `created_at` / `updated_at` | Unix 秒 | 创建与更新记录 |

数据库不保存主密钥或明文 WireGuard 私钥。

## 密码学边界

- 身份：X25519 静态私钥和对应公钥。
- 静态加密：XChaCha20-Poly1305。
- AAD：固定上下文 `vnts2/wireguard-server-identity`、格式版本、加密主密钥版本和公钥。
- 主密钥、临时明文私钥缓冲区使用 `zeroize::Zeroizing`；`StaticSecret` 启用依赖默认的销毁零化。
- 解密后重新派生公钥并与数据库公钥比较；不匹配即拒绝加载。
- 复用 BoringTun 0.7.1 已使用的 `chacha20poly1305 0.10.1` 与 `x25519-dalek 2.0.1`，避免引入重复密码实现。

## 首次初始化与并发

1. 启动时严格读取 32 字节主密钥。
2. 查询固定 `id = 1` 的身份记录。
3. 已存在时执行认证解密和公私钥一致性校验。
4. 不存在时生成新身份并执行 `INSERT OR IGNORE`。
5. 多进程或并发初始化时只有一个候选身份可写入；未写入的一方丢弃候选私钥并重新加载获胜记录。

因此正常重启会恢复同一公钥，不会静默生成新身份。

## 失败关闭语义

下列情况会阻止已配置 WireGuard 身份的服务启动：

- `persistence = false`；
- SQLite 初始化失败；
- 主密钥文件缺失、不可读或长度不是 32 字节；
- 密文、nonce、公钥或版本字段非法；
- 主密钥错误或 AEAD 认证失败；
- 解密私钥派生的公钥与记录不一致。

错误信息不输出主密钥、明文私钥或密文内容。

## 轮换边界

本表预留 `encryption_key_version`，但模块 3.0 不提供轮换命令。后续模块 3.1 应在服务停止状态下使用旧主密钥认证解密、使用新主密钥重新加密，并在单个 SQLite 事务内提交密文、nonce、版本和更新时间；失败时保持旧记录不变。

WireGuard 身份私钥轮换与加密主密钥轮换不是同一操作，必须在后续独立模块中设计客户端公钥迁移。

## 验证覆盖

- schema v2 迁移与重复执行；
- 首次创建后再次加载公钥稳定；
- 数据库密文不等于明文私钥；
- 并发初始化只持久化一条身份；
- 错误主密钥失败关闭；
- 篡改密文失败关闭；
- 主密钥文件严格 32 字节。

use ipnet::Ipv4Net;
use rand::Rng;
use rand::distr::Alphanumeric;
use serde::{Deserialize, Serialize};

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize, Serialize)]
pub struct ConfigFile {
    pub tcp_bind: Option<SocketAddr>,
    pub quic_bind: Option<SocketAddr>,
    pub ws_bind: Option<SocketAddr>,
    pub cert: Option<PathBuf>,
    pub key: Option<PathBuf>,
    pub network: Ipv4Net,
    pub custom_nets: HashMap<String, Ipv4Net>,
    pub white_list: HashSet<String>,
    pub lease_duration: u64,
    pub web_bind: Option<SocketAddr>,
    pub username: Option<String>,
    pub password: Option<String>,
    #[serde(default)]
    pub persistence: bool,
    #[serde(default)]
    pub wireguard_master_key_file: Option<PathBuf>,
    #[serde(default)]
    pub wireguard_bind: Option<SocketAddr>,
    #[serde(default)]
    pub wireguard_public_endpoint: Option<String>,
    #[serde(default = "default_wireguard_max_active_peers")]
    pub wireguard_max_active_peers: usize,
    #[serde(default)]
    pub wireguard_dns: Vec<IpAddr>,
    pub server_quic_bind: Option<SocketAddr>,
    #[serde(default)]
    pub peer_servers: Vec<String>,
    pub server_token: Option<String>,
    #[serde(default)]
    pub server_id: Option<String>,
    #[serde(default)]
    pub lease_authority: Option<String>,
}
impl Default for ConfigFile {
    fn default() -> Self {
        Self {
            tcp_bind: Some("0.0.0.0:29872".parse().unwrap()),
            quic_bind: Some("0.0.0.0:29872".parse().unwrap()),
            ws_bind: Some("0.0.0.0:29872".parse().unwrap()),
            cert: None,
            key: None,
            network: Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24),
            custom_nets: Default::default(),
            white_list: Default::default(),
            lease_duration: 24 * 60 * 60,
            web_bind: Some("127.0.0.1:29871".parse().unwrap()),
            username: Some("admin".to_string()),
            password: None,
            persistence: true,
            wireguard_master_key_file: None,
            wireguard_bind: None,
            wireguard_public_endpoint: None,
            wireguard_max_active_peers: default_wireguard_max_active_peers(),
            wireguard_dns: vec![],
            server_quic_bind: None,
            peer_servers: vec![],
            server_token: None,
            server_id: None,
            lease_authority: None,
        }
    }
}

const fn default_wireguard_max_active_peers() -> usize {
    4096
}

impl ConfigFile {
    pub fn save_to(&self, path: &Path) -> anyhow::Result<()> {
        let s = toml::to_string_pretty(self)?;

        let mut file = std::fs::File::create(path)?;
        file.write_all(s.as_bytes())?;

        Ok(())
    }
    pub fn load_from(path: Option<PathBuf>) -> anyhow::Result<Self> {
        let path = if let Some(path) = path {
            path
        } else {
            let path = Path::new("config.toml");
            if !path.exists() {
                let file = Self {
                    password: Some(generate_admin_password()),
                    ..Self::default()
                };
                file.save_to(path)?;
                return Ok(file);
            }
            path.to_path_buf()
        };
        let content = std::fs::read_to_string(path)?;
        let cfg: ConfigFile = toml::from_str(&content)?;
        Ok(cfg)
    }

    pub fn web_management_config(&self) -> anyhow::Result<Option<(SocketAddr, String, String)>> {
        let Some(web_bind) = self.web_bind else {
            return Ok(None);
        };
        anyhow::ensure!(
            web_bind.ip().is_loopback(),
            "Web 管理端在当前版本只允许绑定回环地址；远程管理请等待 TLS/反向代理阶段"
        );
        let username = self
            .username
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow::anyhow!("启用 Web 管理端时必须配置非空 username"))?;
        let password = self
            .password
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("启用 Web 管理端时必须配置 password"))?;
        anyhow::ensure!(!password.trim().is_empty(), "Web 管理密码不能为空");
        anyhow::ensure!(
            !password.eq_ignore_ascii_case("admin") && password != username,
            "Web 管理密码不能使用默认值 admin，也不能与用户名相同"
        );
        Ok(Some((web_bind, username.to_string(), password.to_string())))
    }

    pub fn validated_wireguard_public_endpoint(&self) -> anyhow::Result<Option<String>> {
        let Some(raw) = self.wireguard_public_endpoint.as_deref() else {
            return Ok(None);
        };
        validate_wireguard_public_endpoint(raw).map(Some)
    }

    pub fn effective_wireguard_public_endpoint(&self) -> anyhow::Result<Option<String>> {
        if self.wireguard_public_endpoint.is_some() {
            return self.validated_wireguard_public_endpoint();
        }
        let Some(bind) = self.wireguard_bind else {
            return Ok(None);
        };
        anyhow::ensure!(bind.port() != 0, "WireGuard 监听端口不能为 0");
        let host = match bind.ip() {
            IpAddr::V4(address) if !address.is_unspecified() => address.to_string(),
            IpAddr::V6(address) if !address.is_unspecified() => format!("[{address}]"),
            _ => discover_wireguard_endpoint_host(),
        };
        validate_wireguard_public_endpoint(&format!("{host}:{}", bind.port())).map(Some)
    }

    pub fn validate_cluster_config(&self) -> anyhow::Result<()> {
        match (
            self.server_id.as_deref().map(str::trim),
            self.lease_authority.as_deref().map(str::trim),
        ) {
            (None, None) => return Ok(()),
            (Some(server_id), Some(authority)) => {
                validate_server_id(server_id)?;
                validate_server_id(authority)?;
            }
            _ => {
                anyhow::bail!("server_id 与 lease_authority 必须同时配置或同时省略");
            }
        }
        anyhow::ensure!(self.persistence, "集群租约模式要求 persistence = true");
        anyhow::ensure!(
            self.server_quic_bind.is_some(),
            "集群租约模式要求配置 server_quic_bind"
        );
        anyhow::ensure!(
            self.server_token
                .as_deref()
                .is_some_and(|token| !token.trim().is_empty()),
            "集群租约模式要求配置非空 server_token"
        );
        Ok(())
    }

    pub fn validated_wireguard_dns(&self) -> anyhow::Result<Vec<IpAddr>> {
        anyhow::ensure!(
            self.wireguard_dns.len() <= 4,
            "wireguard_dns 最多允许配置 4 个地址"
        );
        let mut result = Vec::new();
        for address in &self.wireguard_dns {
            if !result.contains(address) {
                result.push(*address);
            }
        }
        Ok(result)
    }
}

fn validate_server_id(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty() && value.len() <= 64,
        "服务端 ID 长度必须为 1..=64"
    );
    anyhow::ensure!(
        value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.')),
        "服务端 ID 只能包含字母、数字、点、下划线和连字符"
    );
    Ok(())
}

fn validate_wireguard_public_endpoint(raw: &str) -> anyhow::Result<String> {
    let value = raw.trim();
    anyhow::ensure!(!value.is_empty(), "WireGuard 公网 Endpoint 不能为空");
    anyhow::ensure!(
        value == raw && !value.chars().any(|character| character.is_whitespace()),
        "WireGuard 公网 Endpoint 不能包含空白字符"
    );
    anyhow::ensure!(
        !value.contains("://")
            && !value.contains('/')
            && !value.contains('?')
            && !value.contains('#')
            && !value.contains('@'),
        "WireGuard 公网 Endpoint 只能使用 host:port，不能包含协议、路径或用户信息"
    );
    anyhow::ensure!(value.len() <= 259, "WireGuard 公网 Endpoint 过长");

    let port_text = if let Some(bracketed) = value.strip_prefix('[') {
        let (host, suffix) = bracketed
            .split_once(']')
            .ok_or_else(|| anyhow::anyhow!("WireGuard IPv6 Endpoint 必须使用 [IPv6]:port"))?;
        let address: Ipv6Addr = host
            .parse()
            .map_err(|_| anyhow::anyhow!("WireGuard 公网 Endpoint 包含无效 IPv6 地址"))?;
        anyhow::ensure!(
            !address.is_unspecified() && !address.is_multicast(),
            "WireGuard 公网 Endpoint 不能使用未指定或组播地址"
        );
        suffix
            .strip_prefix(':')
            .filter(|port| !port.contains(':'))
            .ok_or_else(|| anyhow::anyhow!("WireGuard 公网 Endpoint 必须包含端口"))?
    } else {
        let (host, port) = value
            .rsplit_once(':')
            .ok_or_else(|| anyhow::anyhow!("WireGuard 公网 Endpoint 必须使用 host:port"))?;
        anyhow::ensure!(
            !host.is_empty() && !host.contains(':'),
            "WireGuard IPv6 Endpoint 必须使用 [IPv6]:port"
        );
        if let Ok(address) = host.parse::<Ipv4Addr>() {
            anyhow::ensure!(
                !address.is_unspecified() && !address.is_multicast(),
                "WireGuard 公网 Endpoint 不能使用未指定或组播地址"
            );
        } else {
            validate_endpoint_hostname(host)?;
        }
        port
    };
    let port: u16 = port_text
        .parse()
        .map_err(|_| anyhow::anyhow!("WireGuard 公网 Endpoint 端口无效"))?;
    anyhow::ensure!(port != 0, "WireGuard 公网 Endpoint 端口不能为 0");
    Ok(value.to_string())
}

fn discover_wireguard_endpoint_host() -> String {
    let routed_address = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
        .and_then(|socket| {
            socket.connect((Ipv4Addr::new(192, 0, 2, 1), 9))?;
            socket.local_addr()
        })
        .ok()
        .and_then(|address| match address.ip() {
            IpAddr::V4(ip)
                if !ip.is_unspecified()
                    && !ip.is_loopback()
                    && !ip.is_link_local()
                    && !is_ipv4_benchmark_address(ip) =>
            {
                Some(ip.to_string())
            }
            _ => None,
        });
    if let Some(address) = routed_address {
        return address;
    }
    for variable in ["COMPUTERNAME", "HOSTNAME"] {
        let Ok(host) = std::env::var(variable) else {
            continue;
        };
        let host = host.trim();
        if !host.is_empty() && validate_endpoint_hostname(host).is_ok() {
            return host.to_string();
        }
    }
    Ipv4Addr::LOCALHOST.to_string()
}

fn is_ipv4_benchmark_address(address: Ipv4Addr) -> bool {
    let octets = address.octets();
    octets[0] == 198 && matches!(octets[1], 18 | 19)
}

fn validate_endpoint_hostname(host: &str) -> anyhow::Result<()> {
    anyhow::ensure!(host.len() <= 253, "WireGuard 公网 Endpoint 主机名过长");
    for label in host.split('.') {
        anyhow::ensure!(
            !label.is_empty() && label.len() <= 63,
            "WireGuard 公网 Endpoint 主机名无效"
        );
        let bytes = label.as_bytes();
        anyhow::ensure!(
            bytes.first().is_some_and(u8::is_ascii_alphanumeric)
                && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
                && bytes
                    .iter()
                    .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-'),
            "WireGuard 公网 Endpoint 主机名无效"
        );
    }
    Ok(())
}

fn generate_admin_password() -> String {
    rand::rng()
        .sample_iter(&Alphanumeric)
        .take(24)
        .map(char::from)
        .collect()
}

pub fn print_example() {
    let str = r#"# 绑定tcp地址，不写则不启用tcp服务
tcp_bind = "0.0.0.0:29872"
# 绑定quic地址，不写则不启用quic服务
quic_bind = "0.0.0.0:29872"
# 绑定wss地址，不写则不启用wss服务
ws_bind = "0.0.0.0:29872"
# 默认虚拟网段
network = "10.26.0.0/24"
# 网络编号白名单
white_list = []
# IP租约时长，单位秒，默认24小时，离线超过这个时间IP就会被回收
lease_duration = 86400
# Web管理端绑定地址，不写则不启用web服务
web_bind = "127.0.0.1:29871"
# 管理端登录用户名密码
username = "admin"
# 管理端登录用户密码
password = "请替换为非空密码"
# 是否启用数据持久化
persistence = true

# WireGuard 服务端身份主密钥文件（可选）
# 文件必须由部署方预先创建，内容严格为32字节二进制；未配置时不启用WireGuard身份
# wireguard_master_key_file = "wireguard-master.key"

# WireGuard UDP 监听地址（可选；必须同时启用持久化并配置有效主密钥文件）
# wireguard_bind = "0.0.0.0:51820"
# 客户端连接使用的公网地址；启用一键生成客户端配置时必须设置，可使用域名、IPv4或方括号IPv6
# wireguard_public_endpoint = "vpn.example.com:51820"
# WireGuard 最大活跃 peer 数；容量满时拒绝新会话，不驱逐现有会话
wireguard_max_active_peers = 4096
# WireGuard 客户端默认 DNS；为空时不生成 DNS 行
wireguard_dns = []

# tls证书不填时将自动生成
# 自定义tls证书路径
cert = "cert.pem"
# 自定义tls私钥路径
key = "key.pem"

# 服务端互联配置（可选）
# 服务端之间通信的UDP端口，不填则不启用服务端互联
# server_quic_bind = "0.0.0.0:29873"
# 其他服务器地址列表
# peer_servers = ["server1.example.com:29873", "192.168.1.100:29873"]
# 服务器验证码，用于服务器之间的身份验证
# server_token = "your-secret-token"
# 多服务器全局租约模式（两项必须同时配置）；所有节点填写相同 lease_authority
# server_id = "server-a"
# lease_authority = "server-a"

# 自定义虚拟网段 格式：网络编号 = "网段"
[custom_nets]

# net1 = "10.25.0.0/24"
# net2 = "10.27.1.0/24"
"#;
    println!("{}", str);
}

#[cfg(test)]
mod tests {
    use super::{ConfigFile, generate_admin_password};

    #[test]
    fn default_web_management_is_loopback_without_hard_coded_password() {
        let config = ConfigFile::default();
        assert!(config.web_bind.unwrap().ip().is_loopback());
        assert_eq!(config.username.as_deref(), Some("admin"));
        assert!(config.password.is_none());
    }

    #[test]
    fn generated_admin_password_is_strong_and_not_reused() {
        let first = generate_admin_password();
        let second = generate_admin_password();
        assert_eq!(first.len(), 24);
        assert_eq!(second.len(), 24);
        assert_ne!(first, second);
        assert_ne!(first, "admin");
    }

    #[test]
    fn web_management_rejects_remote_bind_and_unsafe_credentials() {
        let mut config = ConfigFile {
            password: Some("strong-password-123".to_string()),
            ..ConfigFile::default()
        };
        assert!(config.web_management_config().is_ok());

        config.web_bind = Some("0.0.0.0:29871".parse().unwrap());
        assert!(config.web_management_config().is_err());

        config.web_bind = Some("127.0.0.1:29871".parse().unwrap());
        config.password = Some("admin".to_string());
        assert!(config.web_management_config().is_err());
        config.password = Some("short".to_string());
        assert!(config.web_management_config().is_ok());
        config.password = Some(" ".to_string());
        assert!(config.web_management_config().is_err());
        config.password = Some("operator".to_string());
        config.username = Some("operator".to_string());
        assert!(config.web_management_config().is_err());
    }

    #[test]
    fn wireguard_public_endpoint_accepts_hosts_and_rejects_injection_or_wildcards() {
        for endpoint in [
            "vpn.example.com:51820",
            "203.0.113.10:51820",
            "[2001:db8::1]:51820",
        ] {
            let config = ConfigFile {
                wireguard_public_endpoint: Some(endpoint.to_string()),
                ..ConfigFile::default()
            };
            assert_eq!(
                config.validated_wireguard_public_endpoint().unwrap(),
                Some(endpoint.to_string())
            );
        }

        for endpoint in [
            "",
            " vpn.example.com:51820",
            "vpn.example.com:51820\nAddress=10.0.0.1",
            "https://vpn.example.com:51820",
            "vpn.example.com",
            "vpn.example.com:0",
            "0.0.0.0:51820",
            "[::]:51820",
            "2001:db8::1:51820",
            "bad_host.example:51820",
        ] {
            let config = ConfigFile {
                wireguard_public_endpoint: Some(endpoint.to_string()),
                ..ConfigFile::default()
            };
            assert!(
                config.validated_wireguard_public_endpoint().is_err(),
                "invalid endpoint was accepted: {endpoint:?}"
            );
        }
    }

    #[test]
    fn wireguard_public_endpoint_falls_back_to_bind_port_when_omitted() {
        let config = ConfigFile {
            wireguard_bind: Some("0.0.0.0:51820".parse().unwrap()),
            ..ConfigFile::default()
        };
        let endpoint = config
            .effective_wireguard_public_endpoint()
            .unwrap()
            .unwrap();
        assert!(endpoint.ends_with(":51820"));
        assert_ne!(endpoint, "0.0.0.0:51820");
        assert_ne!(endpoint, "[::]:51820");
        assert!(!endpoint.starts_with("198.18."));
        assert!(!endpoint.starts_with("198.19."));

        let config = ConfigFile {
            wireguard_bind: Some("203.0.113.10:51821".parse().unwrap()),
            ..ConfigFile::default()
        };
        assert_eq!(
            config.effective_wireguard_public_endpoint().unwrap(),
            Some("203.0.113.10:51821".to_string())
        );
    }

    #[test]
    fn cluster_config_is_opt_in_and_fail_closed() {
        assert!(ConfigFile::default().validate_cluster_config().is_ok());

        let mut config = ConfigFile {
            server_id: Some("server-a".to_string()),
            lease_authority: Some("server-a".to_string()),
            server_quic_bind: Some("127.0.0.1:29873".parse().unwrap()),
            server_token: Some("cluster-secret".to_string()),
            ..ConfigFile::default()
        };
        assert!(config.validate_cluster_config().is_ok());

        config.lease_authority = None;
        assert!(config.validate_cluster_config().is_err());
        config.lease_authority = Some("bad id".to_string());
        assert!(config.validate_cluster_config().is_err());
    }
}

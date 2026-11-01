use std::env;
use std::fs;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use anyhow::{anyhow, bail, Context};
use serde::Deserialize;
use serde_json::json;

use crate::api::vnt_api::VntConfig;

const SETTINGS_SCHEMA_VERSION: u32 = 1;
const NETWORKS_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceSettings {
    pub schema_version: u32,
    #[serde(default)]
    pub auto_connect: bool,
    #[serde(default)]
    pub default_config_key: String,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NetworksFile {
    schema_version: u32,
    #[serde(default)]
    updated_at: String,
    configs: Vec<ServiceNetworkConfig>,
}

#[derive(Debug, Deserialize)]
pub struct ServiceNetworkConfig {
    #[serde(rename = "itemKey")]
    pub item_key: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    network_code: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    display_device_name: String,
    #[serde(default)]
    ip: String,
    #[serde(default)]
    server_address: String,
    #[serde(default)]
    server: Vec<String>,
    #[serde(default)]
    stun_server: Vec<String>,
    #[serde(default)]
    udp_stun: Vec<String>,
    #[serde(default)]
    in_ips: Vec<String>,
    #[serde(default)]
    input: Vec<String>,
    #[serde(default)]
    out_ips: Vec<String>,
    #[serde(default)]
    output: Vec<String>,
    #[serde(default)]
    mapping: Vec<String>,
    #[serde(default)]
    port_mapping: Vec<String>,
    #[serde(default)]
    password: String,
    #[serde(default)]
    server_encrypt: bool,
    #[serde(default = "default_protocol")]
    protocol: String,
    #[serde(default)]
    finger: bool,
    #[serde(default = "default_cipher_model")]
    cipher_model: String,
    #[serde(default)]
    device_id: String,
    #[serde(default)]
    tun_name: String,
    #[serde(default)]
    device_name: String,
    #[serde(default = "default_cert_mode")]
    cert_mode: String,
    #[serde(default)]
    mtu: u32,
    #[serde(default)]
    ports: Vec<u32>,
    #[serde(default)]
    first_latency: bool,
    #[serde(default)]
    no_proxy: bool,
    #[serde(default)]
    rtx: bool,
    #[serde(default)]
    compress: bool,
    #[serde(default)]
    fec: bool,
    #[serde(default)]
    no_punch: bool,
    #[serde(default)]
    no_nat: bool,
    #[serde(default)]
    no_tun: bool,
    #[serde(default)]
    allow_mapping: bool,
    #[serde(default)]
    tunnel_port: u16,
    #[serde(default)]
    dns: Vec<String>,
    #[serde(default)]
    packet_loss: f64,
    #[serde(default)]
    packet_delay: u32,
    #[serde(default = "default_punch_model")]
    punch_model: String,
    #[serde(default = "default_channel_type")]
    use_channel: String,
    #[serde(default = "default_compressor")]
    compressor: String,
    #[serde(default)]
    allow_wire_guard: bool,
    #[serde(default)]
    local_dev: String,
    #[serde(default)]
    local_ipv4: String,
    #[serde(default)]
    disable_relay: bool,
}

pub struct ServiceConfigurationSnapshot {
    pub settings: ServiceSettings,
    configs: Vec<ServiceNetworkConfig>,
    networks_updated_at: String,
}

impl ServiceConfigurationSnapshot {
    pub fn revision(&self) -> String {
        format!("{}:{}", self.settings.updated_at, self.networks_updated_at)
    }

    pub fn selected_config(&self) -> anyhow::Result<&ServiceNetworkConfig> {
        let key = self.settings.default_config_key.trim();
        if key.is_empty() {
            bail!("系统自动连接未设置默认配置");
        }
        self.configs
            .iter()
            .find(|config| config.item_key == key)
            .with_context(|| format!("系统自动连接默认配置不存在: {key}"))
    }
}

impl ServiceNetworkConfig {
    pub fn to_vnt_config(&self) -> anyhow::Result<VntConfig> {
        let token = first_non_empty(&self.token, &self.network_code);
        if token.is_empty() {
            bail!("配置 {} 缺少 token", self.item_key);
        }
        let name = first_non_empty(&self.display_device_name, &self.name);
        let server_values = if self.server.is_empty() {
            vec![self.server_address.clone()]
        } else {
            self.server.clone()
        };
        let server_values: Vec<String> = server_values
            .into_iter()
            .filter(|value| !value.trim().is_empty())
            .map(|value| normalize_server_address(&value, &self.protocol))
            .collect();
        if server_values.is_empty() {
            bail!("配置 {} 缺少服务器地址", self.item_key);
        }

        let input_values = if self.in_ips.is_empty() {
            &self.input
        } else {
            &self.in_ips
        };
        let output_values = if self.out_ips.is_empty() {
            &self.output
        } else {
            &self.out_ips
        };
        let in_ips = input_values
            .iter()
            .map(|value| parse_input_network(value))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let out_ips = output_values
            .iter()
            .map(|value| parse_network(value))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let ports = self
            .ports
            .iter()
            .map(|value| u16::try_from(*value).map_err(|_| anyhow!("端口超出有效范围: {value}")))
            .collect::<anyhow::Result<Vec<_>>>()?;

        let bridge_options = json!({
            "cert_mode": self.cert_mode,
            "cipher_model": self.cipher_model,
            "rtx": self.rtx,
            "fec": self.fec,
            "no_tun": self.no_tun,
            "allow_mapping": self.allow_mapping,
            "udp_stun": if self.udp_stun.is_empty() { &self.stun_server } else { &self.udp_stun },
            "tunnel_port": self.tunnel_port,
        });
        let tun_name = first_non_empty(&self.tun_name, &self.device_name);
        let local_binding = if self.local_ipv4.parse::<Ipv4Addr>().is_ok() {
            self.local_ipv4.trim()
        } else if self.local_dev.parse::<Ipv4Addr>().is_ok() {
            self.local_dev.trim()
        } else {
            ""
        };
        let port_mappings = if self.mapping.is_empty() {
            self.port_mapping.clone()
        } else {
            self.mapping.clone()
        };
        let use_channel_type = if self.no_punch {
            "relay".to_string()
        } else if self.disable_relay {
            "p2p".to_string()
        } else {
            self.use_channel.clone()
        };
        let compressor = if self.compress {
            "lz4".to_string()
        } else {
            self.compressor.clone()
        };

        Ok(VntConfig {
            tap: false,
            token: token.to_string(),
            device_id: self.device_id.trim().to_string(),
            name: name.to_string(),
            server_address_str: server_values.join("\n"),
            name_servers: self.dns.clone(),
            stun_server: if self.udp_stun.is_empty() {
                self.stun_server.clone()
            } else {
                self.udp_stun.clone()
            },
            in_ips,
            out_ips,
            password: non_empty_option(&self.password),
            mtu: (self.mtu > 0).then_some(self.mtu),
            ip: non_empty_option(&self.ip),
            no_proxy: self.no_nat || self.no_proxy,
            server_encrypt: self.server_encrypt,
            cipher_model: format!("__vnt_bridge_json__={bridge_options}"),
            finger: self.finger,
            punch_model: self.punch_model.clone(),
            ports: (!ports.is_empty()).then_some(ports),
            first_latency: self.first_latency,
            device_name: non_empty_option(tun_name),
            use_channel_type,
            packet_loss_rate: (self.packet_loss != 0.0).then_some(self.packet_loss),
            packet_delay: self.packet_delay,
            port_mapping_list: port_mappings,
            compressor,
            allow_wire_guard: self.allow_wire_guard,
            local_dev: non_empty_option(local_binding),
            disable_relay: self.disable_relay,
        })
    }
}

pub fn machine_root_from_environment() -> PathBuf {
    let base = env::var_os("PROGRAMDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let drive = env::var_os("SystemDrive").unwrap_or_else(|| "C:".into());
            PathBuf::from(drive).join("ProgramData")
        });
    base.join("VNTC APP2.0")
}

pub fn load_snapshot(root: &Path) -> anyhow::Result<Option<ServiceConfigurationSnapshot>> {
    let config_dir = root.join("config");
    let settings_path = config_dir.join("service.json");
    let networks_path = config_dir.join("networks.json");
    if !settings_path.exists() && !networks_path.exists() {
        return Ok(None);
    }
    if !settings_path.exists() || !networks_path.exists() {
        bail!("VNT 系统服务配置不完整");
    }
    let settings: ServiceSettings = serde_json::from_slice(
        &fs::read(&settings_path)
            .with_context(|| format!("读取服务配置失败: {}", settings_path.display()))?,
    )
    .context("解析 service.json 失败")?;
    let networks: NetworksFile = serde_json::from_slice(
        &fs::read(&networks_path)
            .with_context(|| format!("读取网络配置失败: {}", networks_path.display()))?,
    )
    .context("解析 networks.json 失败")?;
    if settings.schema_version != SETTINGS_SCHEMA_VERSION {
        bail!("不支持的 service.json 版本: {}", settings.schema_version);
    }
    if networks.schema_version != NETWORKS_SCHEMA_VERSION {
        bail!("不支持的 networks.json 版本: {}", networks.schema_version);
    }
    Ok(Some(ServiceConfigurationSnapshot {
        settings,
        configs: networks.configs,
        networks_updated_at: networks.updated_at,
    }))
}

fn first_non_empty<'a>(first: &'a str, second: &'a str) -> &'a str {
    if first.trim().is_empty() {
        second.trim()
    } else {
        first.trim()
    }
}

fn non_empty_option(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn normalize_server_address(value: &str, protocol: &str) -> String {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if lower.starts_with("txt:") {
        return format!("dynamic://{}", &value[4..]);
    }
    if lower.starts_with("udp://") {
        return format!("quic://{}", &value[6..]);
    }
    if lower.starts_with("ws://") {
        return format!("wss://{}", &value[5..]);
    }
    if value.contains("://") {
        return value.to_string();
    }
    let scheme = match protocol.trim().to_ascii_uppercase().as_str() {
        "TCP" => "tcp",
        "WSS" | "WS" => "wss",
        "DYNAMIC" => "dynamic",
        _ => "quic",
    };
    format!("{scheme}://{value}")
}

fn parse_input_network(value: &str) -> anyhow::Result<(u32, u32, String)> {
    let (network, target) = value
        .split_once(',')
        .with_context(|| format!("无效的 in_ips 格式: {value}"))?;
    let target = Ipv4Addr::from_str(target.trim())
        .with_context(|| format!("无效的 in_ips 目标地址: {target}"))?;
    let (address, mask) = parse_network(network)?;
    Ok((address, mask, target.to_string()))
}

fn parse_network(value: &str) -> anyhow::Result<(u32, u32)> {
    let (address, prefix) = value
        .trim()
        .split_once('/')
        .with_context(|| format!("无效的网络格式: {value}"))?;
    let address = Ipv4Addr::from_str(address.trim())
        .with_context(|| format!("无效的 IPv4 地址: {address}"))?;
    let prefix: u32 = prefix
        .trim()
        .parse()
        .with_context(|| format!("无效的网络掩码: {prefix}"))?;
    if prefix > 32 {
        bail!("网络掩码超出范围: {prefix}");
    }
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    Ok((u32::from(address), mask))
}

fn default_protocol() -> String {
    "UDP".to_string()
}
fn default_cipher_model() -> String {
    "aes_gcm".to_string()
}
fn default_cert_mode() -> String {
    "skip".to_string()
}
fn default_punch_model() -> String {
    "all".to_string()
}
fn default_channel_type() -> String {
    "all".to_string()
}
fn default_compressor() -> String {
    "none".to_string()
}

#[cfg(test)]
mod tests {
    use super::{load_snapshot, parse_input_network, parse_network};
    use std::fs;

    #[test]
    fn parses_networks_using_flutter_compatible_integer_layout() {
        assert_eq!(
            parse_network("192.168.2.0/24").unwrap(),
            (0xC0A80200, 0xFFFFFF00)
        );
        assert_eq!(
            parse_input_network("10.8.0.0/16,10.0.0.2").unwrap(),
            (0x0A080000, 0xFFFF0000, "10.0.0.2".to_string())
        );
        assert!(parse_network("10.0.0.0/33").is_err());
    }

    #[test]
    fn loads_versioned_snapshot_and_maps_default_network() {
        let root =
            std::env::temp_dir().join(format!("vnt-service-config-test-{}", std::process::id()));
        let config_dir = root.join("config");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join("service.json"),
            r#"{"schemaVersion":1,"autoConnect":true,"defaultConfigKey":"a","updatedAt":"1"}"#,
        )
        .unwrap();
        fs::write(
            config_dir.join("networks.json"),
            r#"{"schemaVersion":1,"updatedAt":"2","configs":[{"itemKey":"a","token":"token","display_device_name":"node","server":["127.0.0.1:29872"],"tun_name":"VNT-TUN"}]}"#,
        )
        .unwrap();

        let snapshot = load_snapshot(&root).unwrap().unwrap();
        let config = snapshot.selected_config().unwrap().to_vnt_config().unwrap();
        assert_eq!(snapshot.revision(), "1:2");
        assert_eq!(config.server_address_str, "quic://127.0.0.1:29872");
        assert_eq!(config.device_name.as_deref(), Some("VNT-TUN"));

        fs::remove_dir_all(root).unwrap();
    }
}

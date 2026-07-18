use std::net::Ipv4Addr;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Instant;

use anyhow::{Context, Result, anyhow, bail};
use ipnet::Ipv4Net;
use serde::Serialize;
use tokio::sync::{Mutex, RwLock};
use vnt_core::api::VntApi;
use vnt_core::context::NetworkAddr;
use vnt_core::context::config::Config as CoreConfig;
use vnt_core::core::{NetworkManager, RegisterResponse};
use vnt_core::nat::NetInput;
use vnt_core::port_mapping::PortMapping;
use vnt_core::tls::verifier::CertValidationMode;
use vnt_core::tunnel_core::server::transport::config::{ProtocolAddress, ProtocolType};
use vnt_core::utils::task_control::{TaskGroupGuard, TaskGroupManager};

use crate::config::{ChannelMode, VntConfig};

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimePhase {
    Stopped,
    Starting,
    Running,
    Error,
}

#[derive(Clone, Debug, Serialize)]
pub struct StatusSnapshot {
    pub phase: RuntimePhase,
    pub error: Option<String>,
    pub uptime_seconds: Option<u64>,
    pub virtual_ip: Option<String>,
    pub virtual_network: Option<String>,
    pub connected_server: Option<String>,
    pub nat_state: String,
    pub nat_type: Option<String>,
    pub public_ips: Vec<String>,
    pub online_peer_count: usize,
    pub direct_peer_count: usize,
    pub relay_peer_count: usize,
    pub route_peer_count: usize,
}

impl StatusSnapshot {
    fn stopped() -> Self {
        Self {
            phase: RuntimePhase::Stopped,
            error: None,
            uptime_seconds: None,
            virtual_ip: None,
            virtual_network: None,
            connected_server: None,
            nat_state: "unavailable".to_string(),
            nat_type: None,
            public_ips: Vec::new(),
            online_peer_count: 0,
            direct_peer_count: 0,
            relay_peer_count: 0,
            route_peer_count: 0,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct PeerSnapshot {
    pub virtual_ip: String,
    pub name: String,
    pub online: bool,
    pub link_type: String,
    pub rtt_ms: Option<u32>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RouteSnapshot {
    pub virtual_ip: String,
    pub link_type: String,
    pub metric: u8,
    pub rtt_ms: u32,
    pub loss_rate: f64,
    pub score: u32,
}

#[derive(Clone, Debug, Serialize)]
pub struct TrafficSnapshot {
    pub virtual_ip: String,
    pub tx_bytes: u64,
    pub rx_bytes: u64,
}

pub struct VntController {
    operation: Mutex<()>,
    running: Mutex<Option<RunningVnt>>,
    phase: RwLock<(RuntimePhase, Option<String>)>,
}

impl Default for VntController {
    fn default() -> Self {
        Self {
            operation: Mutex::new(()),
            running: Mutex::new(None),
            phase: RwLock::new((RuntimePhase::Stopped, None)),
        }
    }
}

impl VntController {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub async fn start(&self, config: VntConfig) -> Result<()> {
        let _operation = self.operation.lock().await;
        if self.running.lock().await.is_some() {
            return Ok(());
        }

        *self.phase.write().await = (RuntimePhase::Starting, None);
        match RunningVnt::start(&config).await {
            Ok(running) => {
                *self.running.lock().await = Some(running);
                *self.phase.write().await = (RuntimePhase::Running, None);
                Ok(())
            }
            Err(error) => {
                let message = format!("{error:#}");
                *self.phase.write().await = (RuntimePhase::Error, Some(message));
                Err(error)
            }
        }
    }

    pub async fn stop(&self) {
        let _operation = self.operation.lock().await;
        self.running.lock().await.take();
        *self.phase.write().await = (RuntimePhase::Stopped, None);
    }

    pub async fn is_active(&self) -> bool {
        matches!(
            self.phase.read().await.0,
            RuntimePhase::Starting | RuntimePhase::Running
        )
    }

    pub async fn status(&self) -> StatusSnapshot {
        let phase = self.phase.read().await.clone();
        let running = self.running.lock().await;
        match running.as_ref() {
            Some(running) => running.status(phase.0, phase.1),
            None => StatusSnapshot {
                phase: phase.0,
                error: phase.1,
                ..StatusSnapshot::stopped()
            },
        }
    }

    pub async fn peers(&self) -> Vec<PeerSnapshot> {
        self.running
            .lock()
            .await
            .as_ref()
            .map(RunningVnt::peers)
            .unwrap_or_default()
    }

    pub async fn routes(&self) -> Vec<RouteSnapshot> {
        self.running
            .lock()
            .await
            .as_ref()
            .map(RunningVnt::routes)
            .unwrap_or_default()
    }

    pub async fn traffic(&self) -> Vec<TrafficSnapshot> {
        self.running
            .lock()
            .await
            .as_ref()
            .map(RunningVnt::traffic)
            .unwrap_or_default()
    }
}

struct RunningVnt {
    _network_manager: NetworkManager,
    _task_guard: TaskGroupGuard,
    api: VntApi,
    network: NetworkAddr,
    started_at: Instant,
}

impl RunningVnt {
    async fn start(config: &VntConfig) -> Result<Self> {
        let core_config = to_core_config(config)?;
        let mut attempts = vec![core_config.clone()];
        if let Some(fallback) = tcp_fallback_config(&core_config) {
            attempts.push(fallback);
        }

        let mut last_error = None;
        for (index, attempt) in attempts.into_iter().enumerate() {
            match start_attempt(attempt).await {
                Ok(running) => {
                    if index > 0 {
                        log::warn!("QUIC 连接失败，Linux 服务已回退到 TCP");
                    }
                    return Ok(running);
                }
                Err(error) => {
                    let retry = index == 0 && is_retryable_transport_error(&error);
                    last_error = Some(error);
                    if !retry {
                        break;
                    }
                }
            }
        }
        Err(last_error.unwrap_or_else(|| anyhow!("启动 VNT 网络失败")))
    }

    fn status(&self, phase: RuntimePhase, error: Option<String>) -> StatusSnapshot {
        let server_nodes = self.api.server_node_list();
        let connected_server = server_nodes
            .iter()
            .find(|node| node.connected)
            .map(|node| node.server_addr.to_string());
        let clients = self.api.client_ips();
        let online_peer_count = clients.iter().filter(|client| client.online).count();
        let direct_peer_count = clients
            .iter()
            .filter(|client| client.online && self.api.is_direct(&client.ip))
            .count();
        let nat = self.api.nat_info();

        StatusSnapshot {
            phase,
            error,
            uptime_seconds: Some(self.started_at.elapsed().as_secs()),
            virtual_ip: Some(self.network.ip.to_string()),
            virtual_network: Ipv4Net::new(self.network.ip, self.network.prefix_len)
                .ok()
                .map(|network| network.trunc().to_string()),
            connected_server,
            nat_state: if nat.is_some() {
                "ready"
            } else {
                "discovering"
            }
            .to_string(),
            nat_type: nat.as_ref().map(|value| format!("{:?}", value.nat_type)),
            public_ips: nat
                .map(|value| {
                    value
                        .public_ips
                        .into_iter()
                        .map(|ip| ip.to_string())
                        .collect()
                })
                .unwrap_or_default(),
            online_peer_count,
            direct_peer_count,
            relay_peer_count: online_peer_count.saturating_sub(direct_peer_count),
            route_peer_count: self
                .api
                .route_table()
                .iter()
                .filter(|(_, routes)| !routes.is_empty())
                .count(),
        }
    }

    fn peers(&self) -> Vec<PeerSnapshot> {
        self.api
            .client_ips()
            .into_iter()
            .map(|peer| {
                let direct = self.api.is_direct(&peer.ip);
                PeerSnapshot {
                    virtual_ip: peer.ip.to_string(),
                    name: peer.name,
                    online: peer.online,
                    link_type: if direct { "p2p" } else { "relay" }.to_string(),
                    rtt_ms: self.api.get_rtt(&peer.ip),
                }
            })
            .collect()
    }

    fn routes(&self) -> Vec<RouteSnapshot> {
        self.api
            .route_table()
            .into_iter()
            .flat_map(|(ip, routes)| {
                routes.into_iter().map(move |route| RouteSnapshot {
                    virtual_ip: ip.to_string(),
                    link_type: if route.is_direct() { "p2p" } else { "relay" }.to_string(),
                    metric: route.metric(),
                    rtt_ms: route.rtt(),
                    loss_rate: f64::from(route.loss_rate()) / 100.0,
                    score: route.score(),
                })
            })
            .collect()
    }

    fn traffic(&self) -> Vec<TrafficSnapshot> {
        self.api
            .all_traffic_info()
            .into_iter()
            .map(|traffic| TrafficSnapshot {
                virtual_ip: traffic.ip.to_string(),
                tx_bytes: traffic.tx_bytes,
                rx_bytes: traffic.rx_bytes,
            })
            .collect()
    }
}

async fn start_attempt(config: CoreConfig) -> Result<RunningVnt> {
    let task_manager = TaskGroupManager::new();
    let (task_group, task_guard) = task_manager.create_task()?;
    let mut network_manager = NetworkManager::create_network(Box::new(config), task_group)
        .await
        .context("创建 VNT 网络实例失败")?;
    let network = match network_manager.register().await.context("注册 VNTS 失败")? {
        RegisterResponse::Success(network) => network,
        RegisterResponse::Failed(error) => bail!("注册 VNTS 失败：{}", error.message),
    };
    if !network_manager.is_no_tun() {
        network_manager
            .start_tun()
            .await
            .context("启动 Linux TUN 失败，请检查 CAP_NET_ADMIN")?;
        network_manager
            .set_tun_network_ip(network.ip, network.prefix_len)
            .await
            .context("配置 Linux TUN 地址失败")?;
    }
    let api = network_manager.vnt_api();
    Ok(RunningVnt {
        _network_manager: network_manager,
        _task_guard: task_guard,
        api,
        network,
        started_at: Instant::now(),
    })
}

pub fn to_core_config(config: &VntConfig) -> Result<CoreConfig> {
    let server_addr = config
        .server_addresses
        .iter()
        .map(|address| {
            let normalized = normalize_server_address(address);
            ProtocolAddress::from_str(&normalized)
                .map_err(|error| anyhow!("无效服务器地址 {address}：{error}"))
        })
        .collect::<Result<Vec<_>>>()?;
    let device_id = match config.device_id.as_deref().map(str::trim) {
        Some(value) if !value.is_empty() => value.to_string(),
        _ => vnt_core::utils::device_id::get_device_id().context("生成设备 ID 失败")?,
    };
    let input = config
        .input_routes
        .iter()
        .map(|value| parse_input_route(value))
        .collect::<Result<Vec<_>>>()?;
    let output = config
        .output_routes
        .iter()
        .map(|value| Ipv4Net::from_str(value).with_context(|| format!("无效输出路由：{value}")))
        .collect::<Result<Vec<_>>>()?;
    let port_mapping = config
        .port_mappings
        .iter()
        .map(|value| PortMapping::from_str(value).map_err(anyhow::Error::msg))
        .collect::<Result<Vec<_>>>()?;

    Ok(CoreConfig {
        server_addr,
        cert_mode: CertValidationMode::InsecureSkipVerification,
        network_code: config.network_code.trim().to_string(),
        device_id,
        device_name: config.device_name.trim().to_string(),
        tun_name: Some(config.tun_name.trim().to_string()),
        ip: config.virtual_ip,
        password: normalized_optional(&config.password),
        no_punch: config.channel_mode == ChannelMode::RelayOnly,
        compress: config.compress,
        rtx: config.rtx,
        fec: config.fec,
        input,
        output,
        no_nat: config.no_nat,
        no_tun: config.no_tun,
        mtu: Some(config.mtu),
        port_mapping,
        allow_port_mapping: config.allow_port_mapping,
        allow_wire_guard: false,
        wireguard_p2p: None,
        udp_stun: normalize_stun(&config.udp_stun, 3478),
        tcp_stun: normalize_stun(&config.tcp_stun, 443),
        tunnel_port: config.tunnel_port,
    })
}

fn parse_input_route(value: &str) -> Result<NetInput> {
    let (network, target) = value
        .split_once('=')
        .context("输入路由格式必须为 CIDR=目标虚拟IP")?;
    Ok(NetInput {
        net: Ipv4Net::from_str(network.trim())
            .with_context(|| format!("无效输入路由网段：{network}"))?,
        target_ip: Ipv4Addr::from_str(target.trim())
            .with_context(|| format!("无效输入路由目标：{target}"))?,
    })
}

fn normalized_optional(value: &Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_stun(values: &[String], default_port: u16) -> Vec<String> {
    values
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(|value| {
            if value.contains(':') {
                value.to_string()
            } else {
                format!("{value}:{default_port}")
            }
        })
        .collect()
}

fn normalize_server_address(value: &str) -> String {
    let value = value.trim();
    let lower = value.to_ascii_lowercase();
    if lower.starts_with("udp://") {
        format!("quic://{}", &value[6..])
    } else if lower.starts_with("txt:") {
        format!("dynamic://{}", &value[4..])
    } else if value.contains("://") {
        value.to_string()
    } else {
        format!("quic://{value}")
    }
}

fn tcp_fallback_config(config: &CoreConfig) -> Option<CoreConfig> {
    if config.server_addr.len() != 1
        || config.server_addr.first()?.protocol_type != ProtocolType::Quic
    {
        return None;
    }
    let mut fallback = config.clone();
    fallback.server_addr[0].protocol_type = ProtocolType::TlsTcp;
    Some(fallback)
}

fn is_retryable_transport_error(error: &anyhow::Error) -> bool {
    let message = format!("{error:#}").to_ascii_lowercase();
    message.contains("timeout")
        || message.contains("deadline has elapsed")
        || message.contains("failed to establish quic")
        || message.contains("connection refused")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> VntConfig {
        VntConfig {
            server_addresses: vec!["udp://127.0.0.1:2225".to_string()],
            network_code: "test".to_string(),
            device_id: Some("linux-test-device".to_string()),
            udp_stun: vec!["stun.example.com".to_string()],
            input_routes: vec!["192.168.10.0/24=10.26.0.2".to_string()],
            output_routes: vec!["192.168.20.0/24".to_string()],
            ..VntConfig::default()
        }
    }

    #[test]
    fn converts_linux_config_to_current_core_config() {
        let core = to_core_config(&config()).unwrap();
        assert_eq!(core.server_addr[0].protocol_type, ProtocolType::Quic);
        assert_eq!(core.udp_stun, vec!["stun.example.com:3478"]);
        assert_eq!(core.input.len(), 1);
        assert_eq!(core.output.len(), 1);
        assert!(!core.no_punch);
        assert!(!core.allow_wire_guard);
        assert!(core.wireguard_p2p.is_none());
    }

    #[test]
    fn generates_non_empty_device_id_when_missing() {
        let mut value = config();
        value.device_id = None;
        let core = to_core_config(&value).unwrap();
        assert!(!core.device_id.trim().is_empty());
    }

    #[test]
    fn relay_only_disables_punching() {
        let mut value = config();
        value.channel_mode = ChannelMode::RelayOnly;
        assert!(to_core_config(&value).unwrap().no_punch);
    }

    #[test]
    fn stopped_snapshot_has_no_uptime() {
        assert_eq!(StatusSnapshot::stopped().uptime_seconds, None);
    }

    #[test]
    fn monotonic_uptime_keeps_elapsed_seconds() {
        let started_at = Instant::now() - std::time::Duration::from_secs(7);
        assert!(started_at.elapsed().as_secs() >= 7);
    }
}

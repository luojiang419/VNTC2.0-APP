use std::net::Ipv4Addr;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context};
use flutter_rust_bridge::DartFnFuture;
use ipnet::Ipv4Net;
use rust_p2p_core::nat::NatInfo;
use serde::Deserialize;
use tokio::runtime::{Handle, Runtime};
use vnt_core::api::VntApi as CoreVntApi;
use vnt_core::context::config::Config as CoreConfig;
use vnt_core::context::NetworkAddr;
use vnt_core::core::{NetworkManager, RegisterResponse};
use vnt_core::nat::NetInput;
use vnt_core::port_mapping::PortMapping;
use vnt_core::tls::verifier::CertValidationMode;
use vnt_core::tunnel_core::server::transport::config::ProtocolAddress;
use vnt_core::utils::task_control::{TaskGroupGuard, TaskGroupManager};

const CORE_VERSION: &str = "2.0.0";

#[flutter_rust_bridge::frb]
pub async fn vnt_init(vnt_config: VntConfig, call: VntApiCallback) -> anyhow::Result<VntApi> {
    match tokio::task::spawn_blocking(|| VntApi::new(vnt_config, call)).await {
        Ok(result) => result,
        Err(err) => Err(anyhow!("vnt_init spawn_blocking {:?}", err)),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn init_log_with_path(log_dir: String, config_path: String) -> anyhow::Result<()> {
    use log::LevelFilter;
    use log4rs::append::rolling_file::policy::compound::roll::fixed_window::FixedWindowRoller;
    use log4rs::append::rolling_file::policy::compound::trigger::size::SizeTrigger;
    use log4rs::append::rolling_file::policy::compound::CompoundPolicy;
    use log4rs::append::rolling_file::RollingFileAppender;
    use log4rs::config::{Appender, Config, Root};
    use log4rs::encode::pattern::PatternEncoder;
    use std::path::PathBuf;

    let log_path = PathBuf::from(&log_dir);
    if !log_path.exists() {
        std::fs::create_dir_all(&log_path)
            .context(format!("创建日志目录失败: {}", log_dir))?;
    }

    let log_file = log_path.join("vnt-core.log");
    let trigger = SizeTrigger::new(10 * 1024 * 1024);
    let roller_pattern = log_path.join("vnt-core.{}.log").to_string_lossy().to_string();
    let roller = FixedWindowRoller::builder()
        .build(&roller_pattern, 5)
        .context("创建日志滚动器失败")?;
    let policy = CompoundPolicy::new(Box::new(trigger), Box::new(roller));
    let encoder =
        PatternEncoder::new("{d(%Y-%m-%d %H:%M:%S%.3f)} [{f}:{L}] {h({l})} {M}:{m}{n}{n}");

    let appender = RollingFileAppender::builder()
        .encoder(Box::new(encoder))
        .build(log_file, Box::new(policy))
        .context("创建日志追加器失败")?;

    let config = Config::builder()
        .appender(Appender::builder().build("rolling_file", Box::new(appender)))
        .build(Root::builder().appender("rolling_file").build(LevelFilter::Info))
        .context("构建日志配置失败")?;

    log4rs::init_config(config).context("初始化日志系统失败")?;
    log::info!("日志系统初始化成功，日志目录: {}", log_dir);
    log::info!("持久化配置路径: {}", config_path);
    Ok(())
}

#[derive(Clone, Debug)]
pub struct VntConfig {
    pub tap: bool,
    pub token: String,
    pub device_id: String,
    pub name: String,
    pub server_address_str: String,
    pub name_servers: Vec<String>,
    pub stun_server: Vec<String>,
    pub in_ips: Vec<(u32, u32, String)>,
    pub out_ips: Vec<(u32, u32)>,
    pub password: Option<String>,
    pub mtu: Option<u32>,
    pub ip: Option<String>,
    pub no_proxy: bool,
    pub server_encrypt: bool,
    pub cipher_model: String,
    pub finger: bool,
    pub punch_model: String,
    pub ports: Option<Vec<u16>>,
    pub first_latency: bool,
    pub device_name: Option<String>,
    pub use_channel_type: String,
    pub packet_loss_rate: Option<f64>,
    pub packet_delay: u32,
    pub port_mapping_list: Vec<String>,
    pub compressor: String,
    pub allow_wire_guard: bool,
    pub local_dev: Option<String>,
    pub disable_relay: bool,
}

pub struct VntApi {
    _runtime: Runtime,
    _task_group_guard: TaskGroupGuard,
    network_manager: Mutex<Option<NetworkManager>>,
    core_api: CoreVntApi,
    stopped: AtomicBool,
}

impl VntApi {
    pub fn new(vnt_config: VntConfig, call: VntApiCallback) -> anyhow::Result<VntApi> {
        let (core_config, connect_targets) = convert_to_core_config(&vnt_config)?;
        let task_manager = TaskGroupManager::new();
        let (task_group, task_group_guard) = task_manager.create_task()?;
        let runtime = Runtime::new().context("创建 Tokio Runtime 失败")?;

        for (index, address) in connect_targets.iter().enumerate() {
            call.emit_connect(RustConnectInfo {
                count: index + 1,
                address: address.clone(),
            });
        }

        let (network_manager, network_addr) = match runtime.block_on(async {
            start_network(core_config, task_group, call.clone()).await
        }) {
                Ok(value) => value,
                Err(err) => {
                    call.emit_error(error_info_from_error(&err));
                    return Err(err);
                }
            };

        call.emit_handshake(RustHandshakeInfo {
            finger: None,
            version: CORE_VERSION.to_string(),
        });
        call.emit_register(RustRegisterInfo::from_network_addr(&network_addr));
        call.emit_success();

        let api = network_manager.vnt_api();
        Ok(Self {
            _runtime: runtime,
            _task_group_guard: task_group_guard,
            network_manager: Mutex::new(Some(network_manager)),
            core_api: api,
            stopped: AtomicBool::new(false),
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        if self.stopped.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(network_manager) = self.network_manager.lock().ok().and_then(|mut guard| guard.take()) {
            drop(network_manager);
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn device_list(&self) -> Vec<RustPeerClientInfo> {
        if self.is_stopped() {
            return vec![];
        }
        self.core_api
            .client_ips()
            .into_iter()
            .map(|client| RustPeerClientInfo {
                virtual_ip: client.ip.to_string(),
                name: client.ip.to_string(),
                status: if client.online {
                    "Online".to_string()
                } else {
                    "Offline".to_string()
                },
                client_secret: false,
            })
            .collect()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn route_list(&self) -> Vec<(String, Vec<RustRoute>)> {
        if self.is_stopped() {
            return vec![];
        }
        self.core_api
            .client_ips()
            .into_iter()
            .map(|client| {
                let ip = client.ip;
                (
                    ip.to_string(),
                    build_route_from_api(&self.core_api, ip)
                        .into_iter()
                        .collect(),
                )
            })
            .collect()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn nat_info(&self) -> RustNatInfo {
        if self.is_stopped() {
            return RustNatInfo::default();
        }
        self.core_api
            .nat_info()
            .map(RustNatInfo::from)
            .unwrap_or_default()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn current_device(&self) -> RustCurrentDeviceInfo {
        if self.is_stopped() {
            return RustCurrentDeviceInfo::default();
        }
        current_device_from_api(&self.core_api)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn route(&self, ip: &String) -> Option<RustRoute> {
        if self.is_stopped() {
            return None;
        }
        let ip = Ipv4Addr::from_str(ip).ok()?;
        build_route_from_api(&self.core_api, ip)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn peer_nat_info(&self, ip: &String) -> Option<RustNatInfo> {
        if self.is_stopped() {
            return None;
        }
        let ip = Ipv4Addr::from_str(ip).ok()?;
        self.core_api.peer_nat_info(&ip).map(RustNatInfo::from)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn up_stream(&self) -> String {
        convert(total_traffic(&self.core_api, true))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn down_stream(&self) -> String {
        convert(total_traffic(&self.core_api, false))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_all(&self) -> Vec<(String, u64, u64)> {
        if self.is_stopped() {
            return vec![];
        }
        self.core_api
            .all_traffic_info()
            .into_iter()
            .map(|info| (info.ip.to_string(), info.tx_bytes, info.rx_bytes))
            .collect()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn up_stream_line(&self, ip: String) -> Vec<u64> {
        if self.is_stopped() {
            return vec![];
        }
        let ip = match Ipv4Addr::from_str(&ip) {
            Ok(ip) => ip,
            Err(_) => return vec![],
        };
        self.core_api
            .traffic_info(&ip)
            .map(|info| vec![info.tx_bytes])
            .unwrap_or_default()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn down_stream_line(&self, ip: String) -> Vec<u64> {
        if self.is_stopped() {
            return vec![];
        }
        let ip = match Ipv4Addr::from_str(&ip) {
            Ok(ip) => ip,
            Err(_) => return vec![],
        };
        self.core_api
            .traffic_info(&ip)
            .map(|info| vec![info.rx_bytes])
            .unwrap_or_default()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn ip_up_stream_total(&self, ip: String) -> String {
        if self.is_stopped() {
            return String::new();
        }
        let ip = match Ipv4Addr::from_str(&ip) {
            Ok(ip) => ip,
            Err(_) => return String::new(),
        };
        self.core_api
            .traffic_info(&ip)
            .map(|info| convert(info.tx_bytes))
            .unwrap_or_default()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn ip_down_stream_total(&self, ip: String) -> String {
        if self.is_stopped() {
            return String::new();
        }
        let ip = match Ipv4Addr::from_str(&ip) {
            Ok(ip) => ip,
            Err(_) => return String::new(),
        };
        self.core_api
            .traffic_info(&ip)
            .map(|info| convert(info.rx_bytes))
            .unwrap_or_default()
    }
}

async fn start_network(
    core_config: CoreConfig,
    task_group: vnt_core::utils::task_control::TaskGroup,
    call: VntApiCallback,
) -> anyhow::Result<(NetworkManager, NetworkAddr)> {
    let mut network_manager = NetworkManager::create_network(Box::new(core_config.clone()), task_group)
        .await
        .context("创建 VNT 2.0 网络实例失败")?;
    let register_response = network_manager
        .register()
        .await
        .context("注册到 VNTS 2.0 服务端失败")?;
    let network_addr = match register_response {
        RegisterResponse::Success(network_addr) => network_addr,
        RegisterResponse::Failed(error) => {
            return Err(anyhow!("注册到 VNTS 2.0 服务端失败: {}", error.message));
        }
    };
    if !network_manager.is_no_tun() {
        #[cfg(target_os = "android")]
        {
            let tun_config = build_android_tun_config(&network_addr, &core_config)?;
            let tun_fd = call.request_android_vpn_fd(tun_config).await?;
            network_manager
                .start_tun_fd(Some(tun_fd as i32))
                .await
                .context("启动 Android VPN 失败")?;
        }
        #[cfg(not(target_os = "android"))]
        {
        network_manager
            .start_tun()
            .await
            .context("启动虚拟网卡失败")?;
        network_manager
            .set_tun_network_ip(network_addr.ip, network_addr.prefix_len)
            .await
            .context("设置虚拟网卡 IP 失败")?;
        }
    }
    Ok((network_manager, network_addr))
}

fn build_android_tun_config(
    network_addr: &NetworkAddr,
    core_config: &CoreConfig,
) -> anyhow::Result<RustDeviceConfig> {
    let virtual_network = Ipv4Net::new(network_addr.ip, network_addr.prefix_len)
        .context("解析 Android VPN 虚拟网段失败")?
        .network()
        .to_string();
    let external_route = core_config
        .output
        .iter()
        .map(|network| {
            (
                network.network().to_string(),
                prefix_to_netmask(network.prefix_len()).to_string(),
            )
        })
        .collect();
    Ok(RustDeviceConfig {
        virtual_ip: network_addr.ip.to_string(),
        virtual_netmask: prefix_to_netmask(network_addr.prefix_len).to_string(),
        virtual_gateway: network_addr.gateway.to_string(),
        virtual_network,
        external_route,
    })
}

fn convert_to_core_config(vnt_config: &VntConfig) -> anyhow::Result<(CoreConfig, Vec<String>)> {
    let server_addr = parse_server_addresses(&vnt_config.server_address_str)?;
    let connect_targets: Vec<String> =
        server_addr.iter().map(|address| address.to_string()).collect();
    let bridge_options = decode_bridge_options(&vnt_config.cipher_model)?;
    let cert_mode = decode_cert_mode(
        bridge_options
            .cert_mode
            .as_deref()
            .unwrap_or("skip"),
    )?;

    let input = vnt_config
        .in_ips
        .iter()
        .map(|(dest, mask, ip)| {
            Ok(NetInput {
                net: Ipv4Net::new(Ipv4Addr::from(*dest), prefix_from_mask(*mask)?)
                    .context("解析 in_ips 网络段失败")?,
                target_ip: Ipv4Addr::from_str(ip).context("解析 in_ips 目标 IP 失败")?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;

    let output = vnt_config
        .out_ips
        .iter()
        .map(|(dest, mask)| {
            Ipv4Net::new(Ipv4Addr::from(*dest), prefix_from_mask(*mask)?)
                .context("解析 out_ips 网络段失败")
        })
        .collect::<anyhow::Result<Vec<_>>>()?;

    let port_mapping = vnt_config
        .port_mapping_list
        .iter()
        .map(|value| PortMapping::from_str(value).map_err(anyhow::Error::msg))
        .collect::<anyhow::Result<Vec<_>>>()?;

    let ip = match &vnt_config.ip {
        Some(ip) if !ip.trim().is_empty() => {
            Some(Ipv4Addr::from_str(ip.trim()).context("解析指定虚拟 IP 失败")?)
        }
        _ => None,
    };

    let compressor = vnt_config.compressor.trim().to_lowercase();
    let use_channel_type = vnt_config.use_channel_type.trim().to_lowercase();
    let device_id = if vnt_config.device_id.trim().is_empty() {
        vnt_core::utils::device_id::get_device_id().context("生成 VNT 2.0 device_id 失败")?
    } else {
        vnt_config.device_id.trim().to_string()
    };
    let udp_stun = normalize_stun_servers(
        if bridge_options.udp_stun.is_empty() {
            vnt_config.stun_server.clone()
        } else {
            bridge_options.udp_stun.clone()
        },
        3478,
    );
    let tcp_stun = normalize_stun_servers(
        if bridge_options.tcp_stun.is_empty() {
            udp_stun.clone()
        } else {
            bridge_options.tcp_stun.clone()
        },
        443,
    );

    Ok((
        CoreConfig {
            server_addr,
            cert_mode,
            network_code: vnt_config.token.trim().to_string(),
            device_id,
            device_name: vnt_config.name.trim().to_string(),
            tun_name: vnt_config
                .device_name
                .as_ref()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            ip,
            password: vnt_config
                .password
                .as_ref()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            no_punch: use_channel_type == "relay",
            compress: compressor != "none",
            rtx: bridge_options.rtx,
            fec: bridge_options.fec,
            input,
            output,
            no_nat: vnt_config.no_proxy,
            no_tun: bridge_options.no_tun,
            mtu: vnt_config.mtu.map(|value| value.min(u16::MAX as u32) as u16),
            port_mapping,
            allow_port_mapping: bridge_options.allow_mapping,
            udp_stun,
            tcp_stun,
            tunnel_port: bridge_options.tunnel_port,
        },
        connect_targets,
    ))
}

fn parse_server_addresses(raw: &str) -> anyhow::Result<Vec<ProtocolAddress>> {
    let mut addresses = Vec::new();
    for part in raw
        .split(['\n', '\r', ',', ';'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let normalized = normalize_server_address_legacy(part);
        let parsed = ProtocolAddress::from_str(&normalized)
            .map_err(|err| anyhow!("无效服务器地址 {}: {}", part, err))?;
        addresses.push(parsed);
    }
    if addresses.is_empty() {
        return Err(anyhow!("服务器地址不能为空"));
    }
    Ok(addresses)
}

fn normalize_server_address_legacy(raw: &str) -> String {
    let address = raw.trim();
    let lower = address.to_lowercase();
    if let Some(value) = lower.strip_prefix("txt:") {
        return format!("dynamic://{}", value);
    }
    if lower.starts_with("udp://") {
        return format!("quic://{}", &address[6..]);
    }
    if lower.starts_with("ws://") {
        return format!("wss://{}", &address[5..]);
    }
    if address.contains("://") {
        return address.to_string();
    }
    format!("quic://{}", address)
}

fn decode_cert_mode(payload: &str) -> anyhow::Result<CertValidationMode> {
    CertValidationMode::from_str(payload.trim()).map_err(anyhow::Error::msg)
}

#[derive(Debug, Default, Deserialize)]
struct BridgeOptions {
    #[serde(default)]
    cert_mode: Option<String>,
    #[serde(default)]
    rtx: bool,
    #[serde(default)]
    fec: bool,
    #[serde(default)]
    no_tun: bool,
    #[serde(default)]
    allow_mapping: bool,
    #[serde(default)]
    udp_stun: Vec<String>,
    #[serde(default)]
    tcp_stun: Vec<String>,
    #[serde(default)]
    tunnel_port: Option<u16>,
}

fn decode_bridge_options(payload: &str) -> anyhow::Result<BridgeOptions> {
    const JSON_PREFIX: &str = "__vnt_bridge_json__=";
    const LEGACY_PREFIX: &str = "__vnt_bridge_cert_mode__=";
    const LEGACY_SPLITTER: &str = ";;__vnt_bridge_cipher_model__=";

    if let Some(raw) = payload.strip_prefix(JSON_PREFIX) {
        return serde_json::from_str(raw).context("解析 2.0 bridge payload 失败");
    }

    if let Some(rest) = payload.strip_prefix(LEGACY_PREFIX) {
        let cert_mode = if let Some((mode, _legacy_cipher)) = rest.split_once(LEGACY_SPLITTER) {
            mode.trim()
        } else {
            rest.trim()
        };
        return Ok(BridgeOptions {
            cert_mode: Some(cert_mode.to_string()),
            ..BridgeOptions::default()
        });
    }

    Ok(BridgeOptions {
        cert_mode: Some("skip".to_string()),
        ..BridgeOptions::default()
    })
}

fn normalize_stun_servers(entries: Vec<String>, default_port: u16) -> Vec<String> {
    entries
        .into_iter()
        .map(|entry| {
            let trimmed = entry.trim().to_string();
            if trimmed.is_empty() {
                return trimmed;
            }
            if trimmed.contains(':') {
                return trimmed;
            }
            format!("{trimmed}:{default_port}")
        })
        .filter(|entry| !entry.is_empty())
        .collect()
}

fn prefix_from_mask(mask: u32) -> anyhow::Result<u8> {
    let prefix = mask.count_ones() as u8;
    let rebuilt = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    if rebuilt != mask {
        return Err(anyhow!("非法网络掩码: {mask}"));
    }
    Ok(prefix)
}

fn looks_like_ipv4(value: &str) -> bool {
    let parts: Vec<&str> = value.trim().split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    parts.iter().all(|part| part.parse::<u8>().is_ok())
}

fn total_traffic(api: &CoreVntApi, upstream: bool) -> u64 {
    if api.server_node_list().is_empty() {
        return 0;
    }
    api.all_traffic_info()
        .into_iter()
        .map(|info| if upstream { info.tx_bytes } else { info.rx_bytes })
        .sum()
}

fn current_device_from_api(api: &CoreVntApi) -> RustCurrentDeviceInfo {
    let Some(network) = api.network() else {
        return RustCurrentDeviceInfo::default();
    };
    let routes = api.server_node_list();
    let connect_server = routes
        .iter()
        .find(|node| node.connected)
        .or_else(|| routes.first())
        .map(|node| node.server_addr.to_string())
        .unwrap_or_default();
    let status = if routes.iter().any(|node| node.connected) {
        "Online"
    } else {
        "Connecting"
    };
    let network_net = network.network();
    RustCurrentDeviceInfo {
        virtual_ip: network.ip.to_string(),
        virtual_netmask: prefix_to_netmask(network.prefix_len).to_string(),
        virtual_gateway: network.gateway.to_string(),
        virtual_network: network_net.network().to_string(),
        broadcast_ip: network.broadcast.to_string(),
        connect_server,
        status: status.to_string(),
    }
}

fn build_route_from_api(api: &CoreVntApi, ip: Ipv4Addr) -> Option<RustRoute> {
    let is_direct = api.is_direct(&ip);
    let rt = api.get_rtt(&ip).unwrap_or(0);
    let server_nodes = api.server_node_list();
    let server_addr = server_nodes
        .iter()
        .find(|node| node.connected)
        .or_else(|| server_nodes.first())
        .map(|node| node.server_addr.to_string())
        .unwrap_or_else(|| ip.to_string());
    Some(RustRoute {
        protocol: if is_direct {
            "P2P".to_string()
        } else {
            "Relay".to_string()
        },
        addr: server_addr,
        metric: if is_direct { 1 } else { 2 },
        rt: i64::from(rt),
    })
}

fn prefix_to_netmask(prefix_len: u8) -> Ipv4Addr {
    let mask = if prefix_len == 0 {
        0
    } else {
        u32::MAX << (32 - prefix_len)
    };
    Ipv4Addr::from(mask)
}

fn error_info_from_error(error: &anyhow::Error) -> RustErrorInfo {
    let message = format!("{error:#}");
    let lowered = message.to_lowercase();
    let code = if lowered.contains("network_code") || lowered.contains("token") {
        RustErrorType::TokenError
    } else if lowered.contains("ip already exists") {
        RustErrorType::IpAlreadyExists
    } else if lowered.contains("invalid ip") {
        RustErrorType::InvalidIp
    } else if lowered.contains("failed to create device") || lowered.contains("启动虚拟网卡失败")
    {
        RustErrorType::FailedToCreateDevice
    } else if lowered.contains("disconnect") {
        RustErrorType::Disconnect
    } else {
        RustErrorType::Unknown
    };
    RustErrorInfo {
        code,
        msg: Some(message),
    }
}

fn convert(num: u64) -> String {
    let gigabytes = num / (1024 * 1024 * 1024);
    let remaining_bytes = num % (1024 * 1024 * 1024);
    let megabytes = remaining_bytes / (1024 * 1024);
    let remaining_bytes = remaining_bytes % (1024 * 1024);
    let kilobytes = remaining_bytes / 1024;
    let remaining_bytes = remaining_bytes % 1024;
    let mut s = String::new();
    if gigabytes > 0 {
        s.push_str(&format!("{} GB ", gigabytes));
    }
    if megabytes > 0 {
        s.push_str(&format!("{} MB ", megabytes));
    }
    if kilobytes > 0 {
        s.push_str(&format!("{} KB ", kilobytes));
    }
    if remaining_bytes > 0 {
        s.push_str(&format!("{} bytes", remaining_bytes));
    }
    s
}

#[derive(Clone)]
pub struct VntApiCallback {
    inner: Arc<VntApiCallbackInner>,
}

impl VntApiCallback {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(
        success_fn: impl Fn() -> DartFnFuture<()> + Send + Sync + 'static,
        create_tun_fn: impl Fn(RustDeviceInfo) -> DartFnFuture<()> + Send + Sync + 'static,
        connect_fn: impl Fn(RustConnectInfo) -> DartFnFuture<()> + Send + Sync + 'static,
        handshake_fn: impl Fn(RustHandshakeInfo) -> DartFnFuture<bool> + Send + Sync + 'static,
        register_fn: impl Fn(RustRegisterInfo) -> DartFnFuture<bool> + Send + Sync + 'static,
        generate_tun_fn: impl Fn(RustDeviceConfig) -> DartFnFuture<u32> + Send + Sync + 'static,
        peer_client_list_fn: impl Fn(Vec<RustPeerClientInfo>) -> DartFnFuture<()>
            + Send
            + Sync
            + 'static,
        error_fn: impl Fn(RustErrorInfo) -> DartFnFuture<()> + Send + Sync + 'static,
        stop_fn: impl Fn() -> DartFnFuture<()> + Send + Sync + 'static,
    ) -> VntApiCallback {
        Self {
            inner: Arc::new(VntApiCallbackInner {
                success_fn: Box::new(success_fn),
                create_tun_fn: Box::new(create_tun_fn),
                connect_fn: Box::new(connect_fn),
                handshake_fn: Box::new(handshake_fn),
                register_fn: Box::new(register_fn),
                generate_tun_fn: Box::new(generate_tun_fn),
                peer_client_list_fn: Box::new(peer_client_list_fn),
                error_fn: Box::new(error_fn),
                stop_fn: Box::new(stop_fn),
            }),
        }
    }

    fn emit_success(&self) {
        let inner = self.inner.clone();
        spawn_dart_future(move || {
            let f = &inner.success_fn;
            f()
        });
    }

    fn emit_connect(&self, info: RustConnectInfo) {
        let inner = self.inner.clone();
        spawn_dart_future(move || {
            let f = &inner.connect_fn;
            f(info)
        });
    }

    fn emit_handshake(&self, info: RustHandshakeInfo) {
        let inner = self.inner.clone();
        spawn_dart_future(move || {
            let f = &inner.handshake_fn;
            f(info)
        });
    }

    fn emit_register(&self, info: RustRegisterInfo) {
        let inner = self.inner.clone();
        spawn_dart_future(move || {
            let f = &inner.register_fn;
            f(info)
        });
    }

    fn emit_error(&self, info: RustErrorInfo) {
        let inner = self.inner.clone();
        spawn_dart_future(move || {
            let f = &inner.error_fn;
            f(info)
        });
    }

    async fn request_android_vpn_fd(&self, info: RustDeviceConfig) -> anyhow::Result<u32> {
        let fd = (self.inner.generate_tun_fn)(info).await;
        if fd == 0 {
            return Err(anyhow!("Android VPN 返回无效 fd"));
        }
        Ok(fd)
    }
}

fn spawn_dart_future<T, F>(factory: F)
where
    T: Send + 'static,
    F: FnOnce() -> DartFnFuture<T> + Send + 'static,
{
    if let Ok(handle) = Handle::try_current() {
        handle.spawn(async move {
            factory().await;
        });
    } else if let Ok(runtime) = Runtime::new() {
        runtime.block_on(async move {
            factory().await;
        });
    }
}

struct VntApiCallbackInner {
    success_fn: Box<dyn Fn() -> DartFnFuture<()> + Send + Sync + 'static>,
    #[allow(dead_code)]
    create_tun_fn: Box<dyn Fn(RustDeviceInfo) -> DartFnFuture<()> + Send + Sync + 'static>,
    connect_fn: Box<dyn Fn(RustConnectInfo) -> DartFnFuture<()> + Send + Sync + 'static>,
    handshake_fn: Box<dyn Fn(RustHandshakeInfo) -> DartFnFuture<bool> + Send + Sync + 'static>,
    register_fn: Box<dyn Fn(RustRegisterInfo) -> DartFnFuture<bool> + Send + Sync + 'static>,
    #[allow(dead_code)]
    generate_tun_fn: Box<dyn Fn(RustDeviceConfig) -> DartFnFuture<u32> + Send + Sync + 'static>,
    #[allow(dead_code)]
    peer_client_list_fn:
        Box<dyn Fn(Vec<RustPeerClientInfo>) -> DartFnFuture<()> + Send + Sync + 'static>,
    error_fn: Box<dyn Fn(RustErrorInfo) -> DartFnFuture<()> + Send + Sync + 'static>,
    #[allow(dead_code)]
    stop_fn: Box<dyn Fn() -> DartFnFuture<()> + Send + Sync + 'static>,
}

#[derive(Debug)]
pub struct RustDeviceInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug)]
pub struct RustConnectInfo {
    pub count: usize,
    pub address: String,
}

#[derive(Debug)]
pub struct RustHandshakeInfo {
    pub finger: Option<String>,
    pub version: String,
}

#[derive(Debug)]
pub struct RustRegisterInfo {
    pub virtual_ip: String,
    pub virtual_netmask: String,
    pub virtual_gateway: String,
}

impl RustRegisterInfo {
    fn from_network_addr(value: &NetworkAddr) -> Self {
        Self {
            virtual_ip: value.ip.to_string(),
            virtual_netmask: prefix_to_netmask(value.prefix_len).to_string(),
            virtual_gateway: value.gateway.to_string(),
        }
    }
}

#[derive(Debug)]
pub struct RustDeviceConfig {
    pub virtual_ip: String,
    pub virtual_netmask: String,
    pub virtual_gateway: String,
    pub virtual_network: String,
    pub external_route: Vec<(String, String)>,
}

#[derive(Debug)]
pub struct RustPeerClientInfo {
    pub virtual_ip: String,
    pub name: String,
    pub status: String,
    pub client_secret: bool,
}

#[derive(Debug)]
pub struct RustErrorInfo {
    pub code: RustErrorType,
    pub msg: Option<String>,
}

#[derive(Debug)]
pub enum RustErrorType {
    TokenError,
    Disconnect,
    AddressExhausted,
    IpAlreadyExists,
    InvalidIp,
    LocalIpExists,
    FailedToCreateDevice,
    Warn,
    Unknown,
}

#[derive(Debug)]
pub struct RustRoute {
    pub protocol: String,
    pub addr: String,
    pub metric: u8,
    pub rt: i64,
}

#[derive(Debug, Default)]
pub struct RustNatInfo {
    pub public_ips: Vec<String>,
    pub nat_type: String,
    pub local_ipv4: Option<String>,
    pub ipv6: Option<String>,
}

impl From<NatInfo> for RustNatInfo {
    fn from(value: NatInfo) -> Self {
        let local_ipv4 = if value.local_ipv4.is_unspecified() {
            None
        } else {
            Some(value.local_ipv4.to_string())
        };
        let ipv6 = value.ipv6.map(|v| v.to_string());
        Self {
            public_ips: value
                .public_ips
                .into_iter()
                .map(|v| v.to_string())
                .collect(),
            nat_type: format!("{:?}", value.nat_type),
            local_ipv4,
            ipv6,
        }
    }
}

#[derive(Debug, Default)]
pub struct RustCurrentDeviceInfo {
    pub virtual_ip: String,
    pub virtual_netmask: String,
    pub virtual_gateway: String,
    pub virtual_network: String,
    pub broadcast_ip: String,
    pub connect_server: String,
    pub status: String,
}

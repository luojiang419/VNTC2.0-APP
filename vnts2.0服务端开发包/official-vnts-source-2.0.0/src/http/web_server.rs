use crate::ControlService;
use crate::http::dashboard::{
    DashboardSampler, HostResourceSnapshot, ProcessResourceSnapshot, StorageSnapshot,
};
use crate::http::web_security::{self, AuthError, Claims, LoginLimiter};
use crate::server::control_server::service::{
    DeviceInfoVO, NetworkInfoVO, WireGuardPeerIpVO, WireGuardPeerVO,
};
use crate::server::control_server::{db, wireguard_identity, wireguard_profile};
use crate::server::network_state_provider::NetworkState;
use crate::server::wireguard_runtime;
use crate::utils::config::ConfigFile;
use anyhow::Context;
use axum::{
    Json, Router,
    body::Body,
    extract::{ConnectInfo, Path, Query, State},
    http::{HeaderValue, Request, StatusCode, Uri, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
};
use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
use chacha20poly1305::aead::OsRng;
use jsonwebtoken::EncodingKey;
use mime_guess::from_path;
use rand::Rng;
use rand::distr::Alphanumeric;
use rust_embed::RustEmbed;
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, oneshot};
use tokio_util::sync::CancellationToken;
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(RustEmbed)]
#[folder = "static"]
struct Assets;

#[derive(Serialize)]
pub struct ApiResponse<T> {
    pub code: i32,
    pub msg: String,
    pub data: Option<T>,
}

#[derive(Serialize)]
struct PeerServerInfoVO {
    addr: String,
    resolved_addr: Option<String>,
    last_resolved_at: Option<u64>,
    last_error: Option<String>,
    remote_server_id: Option<String>,
    protocol_version: u32,
    capabilities: u64,
    route_only: bool,
    cluster_compatible: bool,
    latency_ms: u32,
    connected: bool,
    is_outbound: bool,
}

#[derive(Serialize)]
struct PeerServersResponse {
    outbound: Vec<PeerServerInfoVO>,
    inbound: Vec<PeerServerInfoVO>,
}

impl<T> ApiResponse<T> {
    pub fn ok(data: T) -> Self {
        Self {
            code: 200,
            msg: "success".to_string(),
            data: Some(data),
        }
    }
    pub fn ok_msg(msg: impl Into<String>) -> Self {
        Self {
            code: 200,
            msg: msg.into(),
            data: None,
        }
    }
    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            code: 400,
            msg: msg.into(),
            data: None,
        }
    }
    pub fn err_code(code: i32, msg: impl Into<String>) -> Self {
        Self {
            code,
            msg: msg.into(),
            data: None,
        }
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::err_code(404, msg)
    }

    pub fn unavailable(msg: impl Into<String>) -> Self {
        Self::err_code(503, msg)
    }
}

impl<T> IntoResponse for ApiResponse<T>
where
    T: Serialize,
{
    fn into_response(self) -> Response {
        let status = u16::try_from(self.code)
            .ok()
            .and_then(|code| StatusCode::from_u16(code).ok())
            .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        (status, Json(self)).into_response()
    }
}

fn service_error(error: anyhow::Error) -> Response {
    let top_level = error.to_string();
    let details = format!("{error:#}").to_lowercase();
    let (status, fallback) = classify_service_error(&details);
    let message = if top_level
        .chars()
        .any(|character| ('\u{4e00}'..='\u{9fff}').contains(&character))
        && status != StatusCode::INTERNAL_SERVER_ERROR
    {
        top_level
    } else {
        fallback.to_string()
    };
    if status == StatusCode::INTERNAL_SERVER_ERROR {
        log::error!("Web API internal error: {error:#}");
    }
    ApiResponse::<()>::err_code(i32::from(status.as_u16()), message).into_response()
}

fn classify_service_error(details: &str) -> (StatusCode, &'static str) {
    if details.contains("不存在")
        || details.contains("does not exist")
        || details.contains("not found")
    {
        (StatusCode::NOT_FOUND, "请求的资源不存在")
    } else if details.contains("已存在")
        || details.contains("已使用")
        || details.contains("重复")
        || details.contains("无法编辑")
        || details.contains("无法删除")
        || details.contains("unique constraint")
        || details.contains("changed concurrently")
    {
        (StatusCode::CONFLICT, "资源状态冲突")
    } else if details.contains("不能为空")
        || details.contains("无效")
        || details.contains("invalid network")
        || details.contains("ip网段错误")
        || details.contains("网关ip")
    {
        (StatusCode::BAD_REQUEST, "请求参数无效")
    } else if details.contains("未启用")
        || details.contains("not available")
        || details.contains("not initialized")
    {
        (StatusCode::SERVICE_UNAVAILABLE, "服务暂不可用")
    } else {
        (StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误")
    }
}

#[derive(Clone)]
pub(crate) struct ServerStatusConfig {
    pub(crate) persistence_enabled: bool,
    pub(crate) database_ready: bool,
    pub(crate) web_bind: SocketAddr,
    pub(crate) tcp_bind: Option<SocketAddr>,
    pub(crate) quic_bind: Option<SocketAddr>,
    pub(crate) websocket_bind: Option<SocketAddr>,
    pub(crate) peer_server_bind: Option<SocketAddr>,
    pub(crate) wireguard_configured: bool,
    pub(crate) wireguard_public_endpoint: Option<String>,
    pub(crate) wireguard_max_active_peers: usize,
    pub(crate) wireguard_dns: Vec<std::net::IpAddr>,
    pub(crate) wireguard_master_key_file: Option<PathBuf>,
}

#[derive(Clone)]
pub(crate) struct WireGuardAutostart {
    config_path: Arc<PathBuf>,
    start_lock: Arc<Mutex<()>>,
    shutdown: CancellationToken,
}

struct WireGuardReady {
    listen_addr: SocketAddr,
    server_public_key: [u8; 32],
    endpoint: String,
    master_key_file: PathBuf,
    dns_servers: Vec<IpAddr>,
}

impl WireGuardAutostart {
    pub(crate) fn new(config_path: PathBuf, shutdown: CancellationToken) -> Self {
        Self {
            config_path: Arc::new(config_path),
            start_lock: Arc::new(Mutex::new(())),
            shutdown,
        }
    }

    async fn ensure_started(
        &self,
        control_service: &ControlService,
    ) -> anyhow::Result<WireGuardReady> {
        let _start_guard = self.start_lock.lock().await;
        let config =
            ConfigFile::load_from(Some((*self.config_path).clone())).with_context(|| {
                format!(
                    "重新加载 WireGuard 配置失败：{}",
                    self.config_path.display()
                )
            })?;
        let endpoint = config
            .effective_wireguard_public_endpoint()?
            .context("尚未配置 WireGuard UDP 监听地址，无法生成可连接的客户端配置")?;
        let master_key_file = config
            .wireguard_master_key_file
            .clone()
            .context("尚未配置 wireguard_master_key_file，无法安全管理客户端私钥")?;
        let dns_servers = config.validated_wireguard_dns()?;

        if let Some((listen_addr, server_public_key, _)) =
            control_service.wireguard_runtime_status()
        {
            return Ok(WireGuardReady {
                listen_addr,
                server_public_key,
                endpoint,
                master_key_file,
                dns_servers,
            });
        }

        anyhow::ensure!(
            config.persistence,
            "WireGuard UDP 自动启动要求 persistence = true"
        );
        let bind_addr = config
            .wireguard_bind
            .context("尚未配置 wireguard_bind，无法自动启动 WireGuard UDP 服务")?;
        let master_key_file_ref = master_key_file.as_path();

        db::init_db_pool()
            .await
            .context("WireGuard UDP 自动启动时初始化数据库失败")?;
        let identity = wireguard_identity::load_or_create(master_key_file_ref)
            .await
            .context("WireGuard UDP 自动启动时加载服务端身份失败")?;
        let (handle, task) = wireguard_runtime::start(
            bind_addr,
            &identity,
            config.wireguard_max_active_peers,
            control_service.clone(),
            self.shutdown.clone(),
        )
        .await
        .with_context(|| format!("WireGuard UDP 自动启动绑定 {bind_addr} 失败"))?;
        let listen_addr = handle.local_addr();
        let server_public_key = handle.public_key();
        control_service.set_wireguard_runtime(handle);
        log::info!("WireGuard UDP listener auto-started on {listen_addr}");

        let monitored_service = control_service.clone();
        tokio::spawn(async move {
            let result = task.await;
            monitored_service.clear_wireguard_runtime_if(listen_addr, server_public_key);
            match result {
                Ok(Ok(())) => log::info!("WireGuard UDP auto-started runtime stopped"),
                Ok(Err(error)) => {
                    log::error!("WireGuard UDP auto-started runtime failed: {error:#}")
                }
                Err(error) => log::error!("WireGuard UDP auto-started task failed: {error}"),
            }
        });

        Ok(WireGuardReady {
            listen_addr,
            server_public_key,
            endpoint,
            master_key_file,
            dns_servers,
        })
    }
}

#[derive(Clone)]
struct AppState {
    control_service: ControlService,
    auth_config: AuthConfig,
    login_limiter: LoginLimiter,
    status_config: ServerStatusConfig,
    wireguard_autostart: Option<WireGuardAutostart>,
    started_at: Instant,
    dashboard_sampler: Arc<DashboardSampler>,
}

#[derive(Clone)]
pub struct AuthConfig {
    pub username: String,
    pub password: String,
    pub jwt_secret: String,
}

#[derive(Serialize)]
struct ServerStatusResponse {
    version: &'static str,
    uptime_seconds: u64,
    database: DatabaseStatusResponse,
    listeners: ListenerStatusResponse,
    networks: NetworkStatusResponse,
    peer_servers: PeerServerStatusResponse,
    wireguard: WireGuardStatusResponse,
}

#[derive(Serialize)]
struct DatabaseStatusResponse {
    persistence_enabled: bool,
    ready: bool,
}

#[derive(Serialize)]
struct ListenerStatusResponse {
    web: String,
    vnt_tcp: Option<String>,
    vnt_quic: Option<String>,
    vnt_websocket: Option<String>,
    peer_server_quic: Option<String>,
}

#[derive(Serialize)]
struct NetworkStatusResponse {
    configured: usize,
    total_nodes: u64,
    online_nodes: u64,
}

#[derive(Serialize)]
struct PeerServerStatusResponse {
    enabled: bool,
    total_connections: usize,
    connected: usize,
    cluster_enabled: bool,
    cluster_ready: bool,
    server_id: Option<String>,
    lease_authority: Option<String>,
    lease_revision: u64,
    lease_conflicts: u64,
}

#[derive(Serialize)]
struct WireGuardStatusResponse {
    configured: bool,
    running: bool,
    listen_addr: Option<String>,
    public_key: Option<String>,
    active_peers: usize,
    max_active_peers: usize,
}

#[derive(Serialize)]
struct DashboardSnapshotResponse {
    sampled_at_ms: u64,
    server: DashboardServerResponse,
    listeners: DashboardListenerResponse,
    host: HostResourceSnapshot,
    process: ProcessResourceSnapshot,
    storage: StorageSnapshot,
    traffic: DashboardTrafficResponse,
    topology: DashboardTopologyResponse,
    peer_servers: DashboardPeerServerResponse,
    wireguard: DashboardWireGuardResponse,
}

#[derive(Serialize)]
struct DashboardServerResponse {
    version: &'static str,
    uptime_seconds: u64,
    persistence_enabled: bool,
    database_ready: bool,
}

#[derive(Serialize)]
struct DashboardListenerResponse {
    web: bool,
    vnt_tcp: bool,
    vnt_quic: bool,
    vnt_websocket: bool,
    peer_server_quic: bool,
    wireguard_udp: bool,
}

#[derive(Serialize)]
struct DashboardTrafficResponse {
    tx_bytes_total: u64,
    rx_bytes_total: u64,
    wireguard_drops_total: u64,
}

#[derive(Serialize)]
struct DashboardTopologyResponse {
    networks: usize,
    nodes_total: u64,
    nodes_online: u64,
    nodes_offline: u64,
    vnt_online: u64,
    wireguard_online: u64,
}

#[derive(Serialize)]
struct DashboardPeerServerResponse {
    enabled: bool,
    total: usize,
    connected: usize,
}

#[derive(Serialize)]
struct DashboardWireGuardResponse {
    configured: bool,
    running: bool,
    active_peers: usize,
    max_active_peers: usize,
}

async fn server_status(State(state): State<AppState>) -> ApiResponse<ServerStatusResponse> {
    let networks = state.control_service.get_network_info();
    let (total_nodes, online_nodes) = networks.iter().fold((0_u64, 0_u64), |totals, network| {
        (
            totals.0 + u64::from(network.all_count),
            totals.1 + u64::from(network.online_count),
        )
    });
    let peer_servers = state.control_service.get_peer_manager();
    let (
        peer_server_enabled,
        total_connections,
        connected,
        cluster_enabled,
        cluster_ready,
        server_id,
        lease_authority,
        lease_revision,
        lease_conflicts,
    ) = match peer_servers {
        Some(manager) => {
            let connections = manager.get_peer_servers();
            let connected = connections
                .iter()
                .filter(|connection| connection.is_connected())
                .count();
            (
                true,
                connections.len(),
                connected,
                manager.cluster_enabled(),
                manager.cluster_ready(),
                (!manager.server_id().is_empty()).then(|| manager.server_id().to_string()),
                (!manager.lease_authority().is_empty())
                    .then(|| manager.lease_authority().to_string()),
                manager.cluster_revision(),
                manager.cluster_conflicts(),
            )
        }
        None => (false, 0, 0, false, true, None, None, 0, 0),
    };
    let wireguard_runtime = state.control_service.wireguard_runtime_status();
    let (wireguard_running, wireguard_listen_addr, wireguard_public_key, active_peers) =
        match wireguard_runtime {
            Some((listen_addr, public_key, active_peers)) => (
                true,
                Some(listen_addr.to_string()),
                Some(BASE64_STANDARD.encode(public_key)),
                active_peers,
            ),
            None => (false, None, None, 0),
        };
    let config = &state.status_config;

    ApiResponse::ok(ServerStatusResponse {
        version: env!("CARGO_PKG_VERSION"),
        uptime_seconds: state.started_at.elapsed().as_secs(),
        database: DatabaseStatusResponse {
            persistence_enabled: config.persistence_enabled,
            ready: config.database_ready,
        },
        listeners: ListenerStatusResponse {
            web: config.web_bind.to_string(),
            vnt_tcp: config.tcp_bind.map(|address| address.to_string()),
            vnt_quic: config.quic_bind.map(|address| address.to_string()),
            vnt_websocket: config.websocket_bind.map(|address| address.to_string()),
            peer_server_quic: config.peer_server_bind.map(|address| address.to_string()),
        },
        networks: NetworkStatusResponse {
            configured: networks.len(),
            total_nodes,
            online_nodes,
        },
        peer_servers: PeerServerStatusResponse {
            enabled: peer_server_enabled,
            total_connections,
            connected,
            cluster_enabled,
            cluster_ready,
            server_id,
            lease_authority,
            lease_revision,
            lease_conflicts,
        },
        wireguard: WireGuardStatusResponse {
            configured: config.wireguard_configured || wireguard_running,
            running: wireguard_running,
            listen_addr: wireguard_listen_addr,
            public_key: wireguard_public_key,
            active_peers,
            max_active_peers: config.wireguard_max_active_peers,
        },
    })
}

async fn dashboard_snapshot(
    State(state): State<AppState>,
) -> ApiResponse<DashboardSnapshotResponse> {
    let resources = state.dashboard_sampler.sample();
    let networks = state.control_service.get_network_info();
    let (nodes_total, nodes_online) = networks.iter().fold((0_u64, 0_u64), |totals, network| {
        (
            totals.0.saturating_add(u64::from(network.all_count)),
            totals.1.saturating_add(u64::from(network.online_count)),
        )
    });
    let provider = state.control_service.get_network_state_provider();
    let traffic = provider.dashboard_traffic_snapshot();
    let endpoints = provider.dashboard_endpoint_snapshot();

    let peer_servers = state.control_service.get_peer_manager();
    let (peer_server_enabled, peer_server_total, peer_server_connected) = match peer_servers {
        Some(manager) => {
            let connections = manager.get_peer_servers();
            let connected = connections
                .iter()
                .filter(|connection| connection.is_connected())
                .count();
            (true, connections.len(), connected)
        }
        None => (false, 0, 0),
    };
    let wireguard_runtime = state.control_service.wireguard_runtime_status();
    let (wireguard_running, active_peers) = wireguard_runtime
        .map(|(_, _, active_peers)| (true, active_peers))
        .unwrap_or((false, 0));
    let config = &state.status_config;

    ApiResponse::ok(DashboardSnapshotResponse {
        sampled_at_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX),
        server: DashboardServerResponse {
            version: env!("CARGO_PKG_VERSION"),
            uptime_seconds: state.started_at.elapsed().as_secs(),
            persistence_enabled: config.persistence_enabled,
            database_ready: config.database_ready,
        },
        listeners: DashboardListenerResponse {
            web: true,
            vnt_tcp: config.tcp_bind.is_some(),
            vnt_quic: config.quic_bind.is_some(),
            vnt_websocket: config.websocket_bind.is_some(),
            peer_server_quic: config.peer_server_bind.is_some(),
            wireguard_udp: config.wireguard_configured,
        },
        host: resources.host,
        process: resources.process,
        storage: resources.storage,
        traffic: DashboardTrafficResponse {
            tx_bytes_total: traffic.tx_bytes_total,
            rx_bytes_total: traffic.rx_bytes_total,
            wireguard_drops_total: traffic.wireguard_drops_total,
        },
        topology: DashboardTopologyResponse {
            networks: networks.len(),
            nodes_total,
            nodes_online,
            nodes_offline: nodes_total.saturating_sub(nodes_online),
            vnt_online: endpoints.vnt_online,
            wireguard_online: endpoints.wireguard_online,
        },
        peer_servers: DashboardPeerServerResponse {
            enabled: peer_server_enabled,
            total: peer_server_total,
            connected: peer_server_connected,
        },
        wireguard: DashboardWireGuardResponse {
            configured: config.wireguard_configured || wireguard_running,
            running: wireguard_running,
            active_peers,
            max_active_peers: config.wireguard_max_active_peers,
        },
    })
}

async fn list_network_code(State(state): State<AppState>) -> ApiResponse<Vec<String>> {
    let codes = state.control_service.get_network_codes();
    ApiResponse::ok(codes)
}

async fn list_networks(State(state): State<AppState>) -> ApiResponse<Vec<NetworkInfoVO>> {
    let info = state.control_service.get_network_info();
    ApiResponse::ok(info)
}

#[derive(Deserialize)]
struct DeviceQueryParams {
    code: String,
}

async fn list_devices(
    State(state): State<AppState>,
    Query(params): Query<DeviceQueryParams>,
) -> Response {
    match state.control_service.get_device_info(&params.code).await {
        Ok(Some(devices)) => ApiResponse::ok(devices).into_response(),
        Ok(None) => ApiResponse::<Vec<DeviceInfoVO>>::not_found(format!(
            "网络编号 '{}' 不存在",
            params.code
        ))
        .into_response(),
        Err(error) => service_error(error),
    }
}

async fn list_peer_servers(State(state): State<AppState>) -> ApiResponse<PeerServersResponse> {
    let peer_manager = match state.control_service.get_peer_manager() {
        Some(manager) => manager,
        None => {
            return ApiResponse::ok(PeerServersResponse {
                outbound: vec![],
                inbound: vec![],
            });
        }
    };

    let peer_servers = peer_manager.get_peer_servers();
    let mut outbound = Vec::new();
    let mut inbound = Vec::new();

    for peer_info in peer_servers {
        let info = PeerServerInfoVO {
            addr: peer_info.get_addr(),
            resolved_addr: peer_info
                .get_resolved_addr()
                .map(|address| address.to_string()),
            last_resolved_at: peer_info.get_last_resolved_at(),
            last_error: peer_info.get_last_error(),
            remote_server_id: peer_info.get_remote_server_id(),
            protocol_version: peer_info.get_remote_protocol_version(),
            capabilities: peer_info.get_remote_capabilities(),
            route_only: peer_info.is_route_only(),
            cluster_compatible: peer_info.is_cluster_compatible(),
            latency_ms: peer_info.get_latency(),
            connected: peer_info.is_connected(),
            is_outbound: peer_info.is_outbound(),
        };

        if info.is_outbound {
            outbound.push(info);
        } else {
            inbound.push(info);
        }
    }

    ApiResponse::ok(PeerServersResponse { outbound, inbound })
}

#[derive(Deserialize)]
struct AddPeerServerRequest {
    server_addr: String,
}

async fn add_peer_server(
    State(state): State<AppState>,
    Json(body): Json<AddPeerServerRequest>,
) -> Response {
    let peer_manager = match state.control_service.get_peer_manager() {
        Some(manager) => manager,
        None => {
            return ApiResponse::<()>::unavailable("服务器互联功能未启用").into_response();
        }
    };

    match peer_manager.add_peer_server(body.server_addr).await {
        Ok(()) => ApiResponse::<()>::ok_msg("添加成功").into_response(),
        Err(error) => service_error(error),
    }
}

async fn delete_peer_server(
    State(state): State<AppState>,
    Path(server_addr): Path<String>,
) -> Response {
    let peer_manager = match state.control_service.get_peer_manager() {
        Some(manager) => manager,
        None => {
            return ApiResponse::<()>::unavailable("服务器互联功能未启用").into_response();
        }
    };

    match peer_manager.remove_peer_server(&server_addr).await {
        Ok(()) => ApiResponse::<()>::ok_msg("删除成功").into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct CreateNetworkRequest {
    network_code: String,
    gateway: String,
    netmask: u8,
    lease_duration: Option<u64>,
}

async fn create_network(
    State(state): State<AppState>,
    Json(body): Json<CreateNetworkRequest>,
) -> Response {
    let gateway: Ipv4Addr = match body.gateway.parse() {
        Ok(ip) => ip,
        Err(_) => {
            return ApiResponse::<()>::err("无效的网关地址").into_response();
        }
    };

    if body.netmask > 32 {
        return ApiResponse::<()>::err("无效的掩码").into_response();
    }

    let lease_duration = body.lease_duration.map(std::time::Duration::from_secs);

    match state
        .control_service
        .add_network(body.network_code, gateway, body.netmask, lease_duration)
        .await
    {
        Ok(()) => ApiResponse::<()>::ok_msg("创建成功").into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct UpdateNetworkRequest {
    gateway: String,
    netmask: u8,
    lease_duration: u64,
}

async fn update_network(
    State(state): State<AppState>,
    Path(network_code): Path<String>,
    Json(body): Json<UpdateNetworkRequest>,
) -> Response {
    let gateway: Ipv4Addr = match body.gateway.parse() {
        Ok(ip) => ip,
        Err(_) => {
            return ApiResponse::<()>::err("无效的网关地址").into_response();
        }
    };

    if body.netmask > 32 {
        return ApiResponse::<()>::err("无效的掩码").into_response();
    }

    let lease_duration = std::time::Duration::from_secs(body.lease_duration);

    match state
        .control_service
        .update_network(&network_code, gateway, body.netmask, lease_duration)
        .await
    {
        Ok(()) => ApiResponse::<()>::ok_msg("更新成功").into_response(),
        Err(error) => service_error(error),
    }
}

async fn delete_network(
    State(state): State<AppState>,
    Path(network_code): Path<String>,
) -> Response {
    match state.control_service.delete_network(&network_code).await {
        Ok(()) => ApiResponse::<()>::ok_msg("删除成功").into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct DeleteDeviceParams {
    code: String,
    device_id: String,
}

async fn delete_device(
    State(state): State<AppState>,
    Query(params): Query<DeleteDeviceParams>,
) -> Response {
    match state
        .control_service
        .delete_device(&params.code, &params.device_id)
        .await
    {
        Ok(()) => ApiResponse::<()>::ok_msg("删除成功").into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct WireGuardPeerListParams {
    network_code: String,
}

#[derive(Serialize)]
struct WireGuardPeerResponse {
    network_code: String,
    peer_id: String,
    public_key: String,
    enabled: bool,
    ip: Option<Ipv4Addr>,
    created_at: i64,
    updated_at: i64,
    dns_servers: Vec<IpAddr>,
    dns_inherited: bool,
    persistent_keepalive: u16,
    routes: Vec<db::WireGuardPeerRouteRecord>,
    config_available: bool,
    online: bool,
    status: &'static str,
}

impl From<WireGuardPeerVO> for WireGuardPeerResponse {
    fn from(peer: WireGuardPeerVO) -> Self {
        Self {
            network_code: peer.network_code,
            peer_id: peer.peer_id,
            public_key: BASE64_STANDARD.encode(peer.public_key),
            enabled: peer.enabled,
            ip: peer.ip,
            created_at: peer.created_at,
            updated_at: peer.updated_at,
            dns_servers: vec![],
            dns_inherited: true,
            persistent_keepalive: 25,
            routes: vec![],
            config_available: false,
            online: false,
            status: "offline",
        }
    }
}

fn default_wireguard_peer_enabled() -> bool {
    true
}

fn default_wireguard_keepalive() -> u16 {
    25
}

#[derive(Deserialize)]
struct CreateWireGuardPeerRequest {
    network_code: String,
    peer_id: String,
    public_key: String,
    #[serde(default = "default_wireguard_peer_enabled")]
    enabled: bool,
    #[serde(default)]
    dns_servers: Option<Vec<IpAddr>>,
    #[serde(default = "default_wireguard_keepalive")]
    persistent_keepalive: u16,
    #[serde(default)]
    routes: Vec<db::WireGuardPeerRouteRecord>,
}

#[derive(Deserialize)]
struct GenerateWireGuardPeerRequest {
    network_code: String,
    peer_id: String,
    #[serde(default = "default_wireguard_peer_enabled")]
    enabled: bool,
    #[serde(default)]
    dns_servers: Option<Vec<IpAddr>>,
    #[serde(default = "default_wireguard_keepalive")]
    persistent_keepalive: u16,
    #[serde(default)]
    routes: Vec<db::WireGuardPeerRouteRecord>,
}

#[derive(Serialize)]
struct GeneratedWireGuardPeerResponse {
    peer: WireGuardPeerResponse,
    private_key: String,
    server_public_key: String,
    listen_addr: String,
    endpoint: String,
    allowed_ips: String,
    dns_servers: Vec<IpAddr>,
    persistent_keepalive: u16,
    routes: Vec<db::WireGuardPeerRouteRecord>,
    client_config: String,
}

#[derive(Deserialize)]
struct UpdateWireGuardPeerProfileRequest {
    network_code: String,
    peer_id: String,
    #[serde(default)]
    dns_servers: Option<Vec<IpAddr>>,
    #[serde(default = "default_wireguard_keepalive")]
    persistent_keepalive: u16,
    #[serde(default)]
    routes: Vec<db::WireGuardPeerRouteRecord>,
}

#[derive(Deserialize)]
struct WireGuardPeerConfigParams {
    network_code: String,
    peer_id: String,
}

#[derive(Deserialize)]
struct SetWireGuardPeerEnabledRequest {
    network_code: String,
    peer_id: String,
    enabled: bool,
}

#[derive(Deserialize)]
struct DeleteWireGuardPeerParams {
    network_code: String,
    peer_id: String,
}

#[derive(Serialize)]
struct DeleteWireGuardPeerResponse {
    peer_removed: bool,
    ip_released: bool,
}

fn decode_wireguard_public_key(value: &str) -> Result<[u8; 32], &'static str> {
    let decoded = BASE64_STANDARD
        .decode(value)
        .map_err(|_| "WireGuard 公钥必须是规范的标准填充 Base64，且解码后恰为 32 字节")?;
    let public_key: [u8; 32] = decoded
        .try_into()
        .map_err(|_| "WireGuard 公钥必须是规范的标准填充 Base64，且解码后恰为 32 字节")?;
    if BASE64_STANDARD.encode(public_key) != value {
        return Err("WireGuard 公钥必须是规范的标准填充 Base64，且解码后恰为 32 字节");
    }
    Ok(public_key)
}

fn normalized_profile(
    network: ipnet::Ipv4Net,
    gateway: Ipv4Addr,
    network_code: &str,
    peer_id: &str,
    dns_servers: Option<Vec<IpAddr>>,
    persistent_keepalive: u16,
    mut routes: Vec<db::WireGuardPeerRouteRecord>,
    created_at: i64,
) -> anyhow::Result<db::WireGuardPeerProfileRecord> {
    let dns_servers = dns_servers
        .map(|servers| {
            anyhow::ensure!(
                servers.len() <= 4,
                "每个 WireGuard Peer 最多配置 4 个 DNS 地址"
            );
            let mut normalized = Vec::new();
            for server in servers {
                if !normalized.contains(&server) {
                    normalized.push(server);
                }
            }
            Ok(normalized)
        })
        .transpose()?;
    anyhow::ensure!(
        routes.len() <= 64,
        "每个 WireGuard Peer 最多配置 64 条局域网路由"
    );
    let mut seen = std::collections::HashSet::new();
    for route in &routes {
        anyhow::ensure!(
            !network.contains(&route.lan_network.network())
                && !route.lan_network.contains(&network.network()),
            "局域网路由 {} 不能与 VNT 网段 {} 重叠",
            route.lan_network,
            network
        );
        anyhow::ensure!(
            network.contains(&route.vnt_cli_ip)
                && route.vnt_cli_ip != network.network()
                && route.vnt_cli_ip != network.broadcast()
                && route.vnt_cli_ip != gateway,
            "局域网路由网关 {} 不是有效的 VNT 客户端地址",
            route.vnt_cli_ip
        );
        anyhow::ensure!(
            seen.insert(route.lan_network),
            "局域网路由 {} 重复",
            route.lan_network
        );
    }
    routes.sort_unstable_by_key(|route| {
        (
            std::cmp::Reverse(route.lan_network.prefix_len()),
            u32::from(route.lan_network.network()),
        )
    });
    Ok(db::WireGuardPeerProfileRecord {
        network_code: network_code.to_string(),
        peer_id: peer_id.to_string(),
        dns_servers,
        persistent_keepalive,
        routes,
        config_available: false,
        created_at,
        updated_at: unix_timestamp_i64(),
    })
}

async fn wireguard_peer_response(
    peer: WireGuardPeerVO,
    global_dns: &[IpAddr],
    network_state: &NetworkState,
) -> anyhow::Result<WireGuardPeerResponse> {
    let profile = db::load_wireguard_peer_profile(&peer.network_code, &peer.peer_id)
        .await?
        .ok_or_else(|| anyhow::anyhow!("WireGuard Peer 在读取 Profile 时消失"))?;
    let mut response = WireGuardPeerResponse::from(peer);
    response.dns_inherited = profile.dns_servers.is_none();
    response.dns_servers = profile
        .dns_servers
        .clone()
        .unwrap_or_else(|| global_dns.to_vec());
    response.persistent_keepalive = profile.persistent_keepalive;
    response.routes = profile.routes;
    response.config_available = profile.config_available;
    response.online = response
        .ip
        .is_some_and(|ip| network_state.is_wireguard_endpoint(ip));
    response.status = if !response.enabled {
        "disabled"
    } else if response.online {
        "online"
    } else if response.ip.is_none() {
        "unassigned"
    } else {
        "offline"
    };
    Ok(response)
}

fn allowed_ips(network: ipnet::Ipv4Net, routes: &[db::WireGuardPeerRouteRecord]) -> String {
    std::iter::once(network.to_string())
        .chain(routes.iter().map(|route| route.lan_network.to_string()))
        .collect::<Vec<_>>()
        .join(", ")
}

fn render_wireguard_client_config(
    private_key: &str,
    address: Ipv4Addr,
    dns_servers: &[IpAddr],
    server_public_key: &str,
    allowed_ips: &str,
    endpoint: &str,
    persistent_keepalive: u16,
) -> String {
    let dns_line = (!dns_servers.is_empty())
        .then(|| {
            format!(
                "DNS = {}\n",
                dns_servers
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })
        .unwrap_or_default();
    format!(
        "[Interface]\nPrivateKey = {private_key}\nAddress = {address}/32\n{dns_line}\n[Peer]\nPublicKey = {server_public_key}\nAllowedIPs = {allowed_ips}\nEndpoint = {endpoint}\nPersistentKeepalive = {persistent_keepalive}\n"
    )
}

fn unix_timestamp_i64() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

async fn list_wireguard_peers(
    State(state): State<AppState>,
    Query(params): Query<WireGuardPeerListParams>,
) -> Response {
    let network_state = match state
        .control_service
        .wireguard_network_state(&params.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    match state
        .control_service
        .list_wireguard_peers(&params.network_code)
        .await
    {
        Ok(peers) => {
            let mut responses = Vec::with_capacity(peers.len());
            for peer in peers {
                match wireguard_peer_response(
                    peer,
                    &state.status_config.wireguard_dns,
                    &network_state,
                )
                .await
                {
                    Ok(response) => responses.push(response),
                    Err(error) => return service_error(error),
                }
            }
            ApiResponse::ok(responses).into_response()
        }
        Err(error) => service_error(error),
    }
}

async fn create_wireguard_peer(
    State(state): State<AppState>,
    Json(body): Json<CreateWireGuardPeerRequest>,
) -> Response {
    let public_key = match decode_wireguard_public_key(&body.public_key) {
        Ok(public_key) => public_key,
        Err(error) => return ApiResponse::<WireGuardPeerResponse>::err(error).into_response(),
    };
    let network_state = match state
        .control_service
        .wireguard_network_state(&body.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    let profile = match normalized_profile(
        *network_state.network(),
        network_state.gateway(),
        &body.network_code,
        &body.peer_id,
        body.dns_servers,
        body.persistent_keepalive,
        body.routes,
        unix_timestamp_i64(),
    ) {
        Ok(profile) => profile,
        Err(error) => {
            return ApiResponse::<WireGuardPeerResponse>::err(error.to_string()).into_response();
        }
    };
    match state
        .control_service
        .create_wireguard_peer(&body.network_code, &body.peer_id, public_key, body.enabled)
        .await
    {
        Ok(peer) => {
            if let Err(error) = wireguard_profile::save_profile(&profile).await {
                let _ = state
                    .control_service
                    .delete_wireguard_peer(&body.network_code, &body.peer_id)
                    .await;
                return service_error(error);
            }
            match wireguard_peer_response(peer, &state.status_config.wireguard_dns, &network_state)
                .await
            {
                Ok(response) => ApiResponse::ok(response).into_response(),
                Err(error) => service_error(error),
            }
        }
        Err(error) => service_error(error),
    }
}

async fn generate_wireguard_peer(
    State(state): State<AppState>,
    Json(body): Json<GenerateWireGuardPeerRequest>,
) -> Response {
    let ready = if let Some(autostart) = &state.wireguard_autostart {
        match autostart.ensure_started(&state.control_service).await {
            Ok(ready) => ready,
            Err(error) => {
                log::warn!("WireGuard UDP automatic startup rejected: {error:#}");
                return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                    error.to_string(),
                )
                .into_response();
            }
        }
    } else {
        let Some((listen_addr, server_public_key, _)) =
            state.control_service.wireguard_runtime_status()
        else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "WireGuard UDP 服务尚未运行，无法生成客户端配置",
            )
            .into_response();
        };
        let Some(endpoint) = state.status_config.wireguard_public_endpoint.clone() else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "尚未配置 wireguard_public_endpoint，无法生成可连接的客户端配置",
            )
            .into_response();
        };
        let Some(master_key_file) = state.status_config.wireguard_master_key_file.clone() else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "尚未配置 wireguard_master_key_file，不能安全保存客户端私钥",
            )
            .into_response();
        };
        WireGuardReady {
            listen_addr,
            server_public_key,
            endpoint,
            master_key_file,
            dns_servers: state.status_config.wireguard_dns.clone(),
        }
    };
    let network_state = match state
        .control_service
        .wireguard_network_state(&body.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    let mut profile = match normalized_profile(
        *network_state.network(),
        network_state.gateway(),
        &body.network_code,
        &body.peer_id,
        body.dns_servers,
        body.persistent_keepalive,
        body.routes,
        unix_timestamp_i64(),
    ) {
        Ok(profile) => profile,
        Err(error) => {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::err(error.to_string())
                .into_response();
        }
    };
    let private_key = StaticSecret::random_from_rng(OsRng);
    let public_key = PublicKey::from(&private_key).to_bytes();
    match state
        .control_service
        .create_wireguard_peer_with_automatic_ip(
            &body.network_code,
            &body.peer_id,
            public_key,
            body.enabled,
        )
        .await
    {
        Ok((peer, network)) => {
            profile.config_available = true;
            if let Err(error) = wireguard_profile::save_generated_profile(
                &ready.master_key_file,
                &profile,
                public_key,
                private_key.to_bytes(),
            )
            .await
            {
                let _ = state
                    .control_service
                    .delete_wireguard_peer(&body.network_code, &body.peer_id)
                    .await;
                return service_error(error);
            }
            let peer_response =
                match wireguard_peer_response(peer, &ready.dns_servers, &network_state).await {
                    Ok(response) => response,
                    Err(error) => return service_error(error),
                };
            let Some(address) = peer_response.ip else {
                return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                    "WireGuard Peer 没有分配客户端地址",
                )
                .into_response();
            };
            let private_key_base64 = BASE64_STANDARD.encode(private_key.to_bytes());
            let server_public_key = BASE64_STANDARD.encode(ready.server_public_key);
            let allowed_ips = allowed_ips(network, &profile.routes);
            let dns_servers = profile
                .dns_servers
                .clone()
                .unwrap_or_else(|| ready.dns_servers.clone());
            let client_config = render_wireguard_client_config(
                &private_key_base64,
                address,
                &dns_servers,
                &server_public_key,
                &allowed_ips,
                &ready.endpoint,
                profile.persistent_keepalive,
            );
            let mut response = ApiResponse::ok(GeneratedWireGuardPeerResponse {
                peer: peer_response,
                private_key: private_key_base64,
                server_public_key,
                listen_addr: ready.listen_addr.to_string(),
                endpoint: ready.endpoint,
                allowed_ips,
                dns_servers,
                persistent_keepalive: profile.persistent_keepalive,
                routes: profile.routes,
                client_config,
            })
            .into_response();
            response
                .headers_mut()
                .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
            response
        }
        Err(error) => service_error(error),
    }
}

async fn update_wireguard_peer_profile(
    State(state): State<AppState>,
    Json(body): Json<UpdateWireGuardPeerProfileRequest>,
) -> Response {
    let network_state = match state
        .control_service
        .wireguard_network_state(&body.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    let existing = match db::load_wireguard_peer_profile(&body.network_code, &body.peer_id).await {
        Ok(Some(profile)) => profile,
        Ok(None) => return (StatusCode::NOT_FOUND, "WireGuard Peer 不存在").into_response(),
        Err(error) => return service_error(error),
    };
    let profile = match normalized_profile(
        *network_state.network(),
        network_state.gateway(),
        &body.network_code,
        &body.peer_id,
        body.dns_servers,
        body.persistent_keepalive,
        body.routes,
        existing.created_at,
    ) {
        Ok(profile) => profile,
        Err(error) => {
            return ApiResponse::<WireGuardPeerResponse>::err(error.to_string()).into_response();
        }
    };
    if let Err(error) = wireguard_profile::save_profile(&profile).await {
        return service_error(error);
    }
    if let Err(error) = state
        .control_service
        .reload_wireguard_peer_profile(&body.network_code, &body.peer_id)
        .await
    {
        return service_error(error);
    }
    match state
        .control_service
        .list_wireguard_peers(&body.network_code)
        .await
    {
        Ok(peers) => {
            let Some(peer) = peers.into_iter().find(|peer| peer.peer_id == body.peer_id) else {
                return (StatusCode::NOT_FOUND, "WireGuard Peer 不存在").into_response();
            };
            match wireguard_peer_response(peer, &state.status_config.wireguard_dns, &network_state)
                .await
            {
                Ok(response) => ApiResponse::ok(response).into_response(),
                Err(error) => service_error(error),
            }
        }
        Err(error) => service_error(error),
    }
}

async fn get_wireguard_peer_config(
    State(state): State<AppState>,
    Query(params): Query<WireGuardPeerConfigParams>,
) -> Response {
    let profile = match db::load_wireguard_peer_profile(&params.network_code, &params.peer_id).await
    {
        Ok(Some(profile)) if profile.config_available => profile,
        Ok(Some(_)) => {
            return (
                StatusCode::CONFLICT,
                Json(ApiResponse::<()>::err(
                    "该 Peer 是公钥导入项，服务端没有客户端私钥",
                )),
            )
                .into_response();
        }
        Ok(None) => return (StatusCode::NOT_FOUND, "WireGuard Peer 不存在").into_response(),
        Err(error) => return service_error(error),
    };
    let ready = if let Some(autostart) = &state.wireguard_autostart {
        match autostart.ensure_started(&state.control_service).await {
            Ok(ready) => ready,
            Err(error) => return service_error(error),
        }
    } else {
        let Some((listen_addr, server_public_key, _)) =
            state.control_service.wireguard_runtime_status()
        else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "WireGuard UDP 服务尚未运行",
            )
            .into_response();
        };
        let Some(endpoint) = state.status_config.wireguard_public_endpoint.clone() else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "尚未配置 wireguard_public_endpoint",
            )
            .into_response();
        };
        let Some(master_key_file) = state.status_config.wireguard_master_key_file.clone() else {
            return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
                "尚未配置 wireguard_master_key_file",
            )
            .into_response();
        };
        WireGuardReady {
            listen_addr,
            server_public_key,
            endpoint,
            master_key_file,
            dns_servers: state.status_config.wireguard_dns.clone(),
        }
    };
    let private_key = match wireguard_profile::load_private_key(
        &ready.master_key_file,
        &params.network_code,
        &params.peer_id,
    )
    .await
    {
        Ok(Some(private_key)) => private_key,
        Ok(None) => {
            return (
                StatusCode::CONFLICT,
                Json(ApiResponse::<()>::err("该 Peer 没有可用的客户端私钥")),
            )
                .into_response();
        }
        Err(error) => return service_error(error),
    };
    let network_state = match state
        .control_service
        .wireguard_network_state(&params.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    let peers = match state
        .control_service
        .list_wireguard_peers(&params.network_code)
        .await
    {
        Ok(peers) => peers,
        Err(error) => return service_error(error),
    };
    let Some(peer) = peers
        .into_iter()
        .find(|peer| peer.peer_id == params.peer_id)
    else {
        return (StatusCode::NOT_FOUND, "WireGuard Peer 不存在").into_response();
    };
    let Some(address) = peer.ip else {
        return ApiResponse::<GeneratedWireGuardPeerResponse>::unavailable(
            "WireGuard Peer 尚未分配 IP",
        )
        .into_response();
    };
    let peer_response =
        match wireguard_peer_response(peer, &ready.dns_servers, &network_state).await {
            Ok(response) => response,
            Err(error) => return service_error(error),
        };
    let private_key = BASE64_STANDARD.encode(*private_key);
    let server_public_key = BASE64_STANDARD.encode(ready.server_public_key);
    let allowed_ips = allowed_ips(*network_state.network(), &profile.routes);
    let dns_servers = profile
        .dns_servers
        .clone()
        .unwrap_or_else(|| ready.dns_servers.clone());
    let client_config = render_wireguard_client_config(
        &private_key,
        address,
        &dns_servers,
        &server_public_key,
        &allowed_ips,
        &ready.endpoint,
        profile.persistent_keepalive,
    );
    let mut response = ApiResponse::ok(GeneratedWireGuardPeerResponse {
        peer: peer_response,
        private_key,
        server_public_key,
        listen_addr: ready.listen_addr.to_string(),
        endpoint: ready.endpoint,
        allowed_ips,
        dns_servers,
        persistent_keepalive: profile.persistent_keepalive,
        routes: profile.routes,
        client_config,
    })
    .into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

async fn set_wireguard_peer_enabled(
    State(state): State<AppState>,
    Json(body): Json<SetWireGuardPeerEnabledRequest>,
) -> Response {
    let network_state = match state
        .control_service
        .wireguard_network_state(&body.network_code)
        .await
    {
        Ok(network_state) => network_state,
        Err(error) => return service_error(error),
    };
    match state
        .control_service
        .set_wireguard_peer_enabled(&body.network_code, &body.peer_id, body.enabled)
        .await
    {
        Ok(peer) => {
            match wireguard_peer_response(peer, &state.status_config.wireguard_dns, &network_state)
                .await
            {
                Ok(response) => ApiResponse::ok(response).into_response(),
                Err(error) => service_error(error),
            }
        }
        Err(error) => service_error(error),
    }
}

async fn delete_wireguard_peer(
    State(state): State<AppState>,
    Query(params): Query<DeleteWireGuardPeerParams>,
) -> Response {
    match state
        .control_service
        .delete_wireguard_peer(&params.network_code, &params.peer_id)
        .await
    {
        Ok(result) => ApiResponse::ok(DeleteWireGuardPeerResponse {
            peer_removed: result.peer_removed,
            ip_released: result.ip_released,
        })
        .into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct WireGuardPeerIpListParams {
    network_code: String,
}

async fn list_wireguard_peer_ips(
    State(state): State<AppState>,
    Query(params): Query<WireGuardPeerIpListParams>,
) -> Response {
    match state
        .control_service
        .list_wireguard_peer_ips(&params.network_code)
        .await
    {
        Ok(allocations) => ApiResponse::<Vec<WireGuardPeerIpVO>>::ok(allocations).into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct ReserveWireGuardPeerIpRequest {
    network_code: String,
    peer_id: String,
    ip: String,
}

async fn reserve_wireguard_peer_ip(
    State(state): State<AppState>,
    Json(body): Json<ReserveWireGuardPeerIpRequest>,
) -> Response {
    let ip = match body.ip.parse() {
        Ok(ip) => ip,
        Err(_) => return ApiResponse::<()>::err("无效的 IPv4 地址").into_response(),
    };

    match state
        .control_service
        .reserve_wireguard_peer_ip(&body.network_code, &body.peer_id, ip)
        .await
    {
        Ok(()) => ApiResponse::<()>::ok_msg("预留成功").into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct ReleaseWireGuardPeerIpParams {
    network_code: String,
    peer_id: String,
}

async fn release_wireguard_peer_ip(
    State(state): State<AppState>,
    Query(params): Query<ReleaseWireGuardPeerIpParams>,
) -> Response {
    match state
        .control_service
        .release_wireguard_peer_ip(&params.network_code, &params.peer_id)
        .await
    {
        Ok(removed) => ApiResponse::ok(removed).into_response(),
        Err(error) => service_error(error),
    }
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct LoginResponse {
    token: String,
    csrf_token: String,
    expires_in_seconds: u64,
}

async fn login(
    ConnectInfo(remote_addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> Response {
    let auth_cfg = &state.auth_config;
    let source = remote_addr.ip();

    if let Some(retry_after) = state.login_limiter.retry_after(source) {
        let resp = ApiResponse::<()>::err_code(429, "登录尝试过多，请稍后重试");
        let mut response = (StatusCode::TOO_MANY_REQUESTS, Json(resp)).into_response();
        if let Ok(value) = retry_after.to_string().parse() {
            response.headers_mut().insert(header::RETRY_AFTER, value);
        }
        return response;
    }

    let username_matches = web_security::constant_time_eq(&body.username, &auth_cfg.username);
    let password_matches = web_security::constant_time_eq(&body.password, &auth_cfg.password);
    if username_matches & password_matches {
        state.login_limiter.clear(source);
        let exp = time::OffsetDateTime::now_utc() + time::Duration::days(1);
        let csrf_token: String = rand::rng()
            .sample_iter(&Alphanumeric)
            .take(48)
            .map(char::from)
            .collect();
        let claims = Claims {
            sub: body.username,
            exp: exp.unix_timestamp(),
            csrf: Some(csrf_token.clone()),
        };

        let token = match jsonwebtoken::encode(
            &jsonwebtoken::Header::default(),
            &claims,
            &EncodingKey::from_secret(auth_cfg.jwt_secret.as_bytes()),
        ) {
            Ok(token) => token,
            Err(error) => {
                log::error!("创建管理会话失败: {error}");
                let resp = ApiResponse::<()>::err_code(500, "创建管理会话失败");
                return (StatusCode::INTERNAL_SERVER_ERROR, Json(resp)).into_response();
            }
        };

        let mut response = ApiResponse::ok(LoginResponse {
            token: token.clone(),
            csrf_token,
            expires_in_seconds: 24 * 60 * 60,
        })
        .into_response();
        if let Ok(value) = web_security::session_cookie(&token).parse() {
            response.headers_mut().insert(header::SET_COOKIE, value);
        }
        response
    } else {
        state.login_limiter.record_failure(source);
        let resp = ApiResponse::<()>::err_code(401, "用户名或密码错误");
        (StatusCode::UNAUTHORIZED, Json(resp)).into_response()
    }
}

async fn logout() -> Response {
    let mut response = ApiResponse::<()>::ok_msg("已退出登录").into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        web_security::expired_session_cookie().parse().unwrap(),
    );
    response
}

async fn auth_middleware(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, Response> {
    match web_security::authorize(
        request.headers(),
        request.method(),
        &state.auth_config.jwt_secret,
    ) {
        Ok(_) => Ok(next.run(request).await),
        Err(AuthError::Csrf) => {
            let resp = ApiResponse::<()>::err_code(403, "CSRF 校验失败");
            Err((StatusCode::FORBIDDEN, Json(resp)).into_response())
        }
        Err(AuthError::Missing | AuthError::Invalid) => {
            let resp = ApiResponse::<()>::err_code(401, "登录已失效");
            Err((StatusCode::UNAUTHORIZED, Json(resp)).into_response())
        }
    }
}

async fn static_handler(uri: Uri) -> impl IntoResponse {
    let mut path = uri.path().trim_start_matches('/').to_string();

    if path.is_empty() {
        path = "index.html".to_string();
    }

    if path.contains('\\') || path.split('/').any(|segment| matches!(segment, "." | "..")) {
        return (StatusCode::NOT_FOUND, "404 Not Found").into_response();
    }

    if let Some(content) = Assets::get(&path) {
        log::debug!("Serving file from embedded assets: {}", path);
        let mime = from_path(&path).first_or_octet_stream();
        return (
            [(header::CONTENT_TYPE, mime.as_ref())],
            Body::from(content.data),
        )
            .into_response();
    }

    (StatusCode::NOT_FOUND, "404 Not Found").into_response()
}

fn build_app(app_state: AppState) -> Router {
    let api_routes = Router::new()
        .route("/status", get(server_status))
        .route("/dashboard/snapshot", get(dashboard_snapshot))
        .route("/network_codes", get(list_network_code))
        .route("/networks", get(list_networks))
        .route("/networks", post(create_network))
        .route("/networks/{network_code}", put(update_network))
        .route("/networks/{network_code}", delete(delete_network))
        .route("/devices", get(list_devices))
        .route("/devices", delete(delete_device))
        .route("/peer_servers", get(list_peer_servers))
        .route("/peer_servers", post(add_peer_server))
        .route("/peer_servers/{server_addr}", delete(delete_peer_server))
        .route("/wireguard/peers", get(list_wireguard_peers))
        .route("/wireguard/peers", post(create_wireguard_peer))
        .route("/wireguard/peers/generated", post(generate_wireguard_peer))
        .route(
            "/wireguard/peers/profile",
            put(update_wireguard_peer_profile),
        )
        .route("/wireguard/peers/config", get(get_wireguard_peer_config))
        .route("/wireguard/peers/enabled", put(set_wireguard_peer_enabled))
        .route("/wireguard/peers", delete(delete_wireguard_peer))
        .route("/wireguard/peer_ips", get(list_wireguard_peer_ips))
        .route("/wireguard/peer_ips", put(reserve_wireguard_peer_ip))
        .route("/wireguard/peer_ips", delete(release_wireguard_peer_ip))
        .route_layer(middleware::from_fn_with_state(
            app_state.clone(),
            auth_middleware,
        ));

    Router::new()
        .nest("/api", api_routes)
        .route("/api/login", post(login))
        .route("/api/logout", post(logout))
        .fallback(static_handler)
        .layer(middleware::from_fn(web_security::security_headers))
        .with_state(app_state)
}

pub async fn start_http_server(
    control_service: ControlService,
    username: String,
    password: String,
    web_bind: SocketAddr,
    status_config: ServerStatusConfig,
    wireguard_autostart: WireGuardAutostart,
    shutdown: CancellationToken,
    startup_tx: Option<oneshot::Sender<Result<(), String>>>,
) -> anyhow::Result<()> {
    let jwt_secret: String = rand::rng()
        .sample_iter(&Alphanumeric)
        .take(64)
        .map(char::from)
        .collect();

    let app = build_app(AppState {
        control_service,
        auth_config: AuthConfig {
            username,
            password,
            jwt_secret,
        },
        login_limiter: LoginLimiter::default(),
        status_config,
        wireguard_autostart: Some(wireguard_autostart),
        started_at: Instant::now(),
        dashboard_sampler: Arc::new(DashboardSampler::new(
            std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        )),
    });

    let listener = match tokio::net::TcpListener::bind(web_bind).await {
        Ok(listener) => listener,
        Err(error) => {
            let message = format!("HTTP 监听失败 {web_bind}: {error}");
            if let Some(startup_tx) = startup_tx {
                let _ = startup_tx.send(Err(message.clone()));
            }
            anyhow::bail!(message);
        }
    };
    log::info!("HTTP Server running at http://{}", web_bind);
    if let Some(startup_tx) = startup_tx {
        let _ = startup_tx.send(Ok(()));
    }
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown.cancelled_owned())
    .await
    .map_err(|err| anyhow::anyhow!("HTTP 服务运行失败 {}: {}", web_bind, err))?;
    log::info!("HTTP Server stopped");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        AppState, Assets, AuthConfig, Claims, LoginLimiter, ServerStatusConfig, build_app,
        classify_service_error, decode_wireguard_public_key,
    };
    use crate::server::control_server::service::ControlService;
    use axum::body::{Body, to_bytes};
    use axum::extract::ConnectInfo;
    use axum::http::{Request, StatusCode, Uri, header};
    use axum::response::IntoResponse;
    use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
    use ipnet::Ipv4Net;
    use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
    use std::collections::HashMap;
    use std::net::{Ipv4Addr, SocketAddr};
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tower::ServiceExt;

    fn test_status_config() -> ServerStatusConfig {
        ServerStatusConfig {
            persistence_enabled: false,
            database_ready: false,
            web_bind: "127.0.0.1:29871".parse().unwrap(),
            tcp_bind: Some("0.0.0.0:29872".parse().unwrap()),
            quic_bind: Some("0.0.0.0:29872".parse().unwrap()),
            websocket_bind: Some("0.0.0.0:29872".parse().unwrap()),
            peer_server_bind: None,
            wireguard_configured: false,
            wireguard_dns: vec![],
            wireguard_master_key_file: None,
            wireguard_public_endpoint: None,
            wireguard_max_active_peers: 4096,
        }
    }

    #[test]
    fn wireguard_public_key_requires_canonical_padded_base64_for_32_bytes() {
        let public_key = [0x11; 32];
        let canonical = BASE64_STANDARD.encode(public_key);
        assert_eq!(canonical.len(), 44);
        assert_eq!(decode_wireguard_public_key(&canonical).unwrap(), public_key);
        assert!(
            decode_wireguard_public_key(canonical.trim_end_matches('=')).is_err(),
            "unpadded Base64 must be rejected"
        );
        assert!(decode_wireguard_public_key(&format!("{canonical} ")).is_err());
        assert!(decode_wireguard_public_key(&BASE64_STANDARD.encode([0x22; 31])).is_err());
    }

    #[test]
    fn hs256_jwt_keeps_the_shared_secret_contract() {
        const SECRET: &[u8] = b"module-1-1-jwt-secret";
        let claims = Claims {
            sub: "admin".to_string(),
            exp: 4_102_444_800,
            csrf: None,
        };

        let token = jsonwebtoken::encode(
            &Header::default(),
            &claims,
            &EncodingKey::from_secret(SECRET),
        )
        .expect("HS256 token encoding must succeed");
        assert_eq!(
            jsonwebtoken::decode_header(&token)
                .expect("encoded token header must be valid")
                .alg,
            Algorithm::HS256
        );

        let decoded = jsonwebtoken::decode::<Claims>(
            &token,
            &DecodingKey::from_secret(SECRET),
            &Validation::default(),
        )
        .expect("HS256 token decoding must succeed");
        assert_eq!(decoded.claims.sub, "admin");
        assert_eq!(decoded.claims.exp, 4_102_444_800);
    }

    #[test]
    fn service_errors_map_to_stable_http_statuses() {
        assert_eq!(
            classify_service_error("网络编号不存在").0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            classify_service_error("unique constraint failed").0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            classify_service_error("wireguard peer id 不能为空").0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            classify_service_error("runtime is not available").0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        assert_eq!(
            classify_service_error("unexpected database failure").0,
            StatusCode::INTERNAL_SERVER_ERROR
        );
    }

    #[test]
    fn embedded_console_is_offline_precompiled_and_status_aware() {
        let index = Assets::get("index.html").expect("embedded index.html must exist");
        let index = String::from_utf8(index.data.into_owned()).expect("index.html must be UTF-8");
        assert!(index.contains("/assets/vue.runtime.global.prod.js"));
        assert!(index.contains("/assets/qrcode.min.js"));
        assert!(index.contains("/assets/app.js"));
        assert!(index.contains("/assets/app.css"));
        assert!(index.contains("/assets/fontawesome.min.css"));
        assert!(!index.contains("http://"));
        assert!(!index.contains("https://"));
        assert!(!index.contains("<style"));
        assert!(!index.contains("style="));

        let application = Assets::get("assets/app.js").expect("embedded app.js must exist");
        let application = String::from_utf8(application.data.into_owned())
            .expect("embedded app.js must be UTF-8");
        assert!(application.contains("request('/status')"));
        assert!(application.contains("服务暂不可用"));
        assert!(application.contains("WireGuard 管理"));
        assert!(application.contains("客户端配置只显示这一次"));
        assert!(application.contains("放弃并删除 Peer"));
        assert!(application.contains("navigator.clipboard.writeText"));
        assert!(
            application.contains("if (generated?.client_config) return generated.client_config")
        );
        assert!(application.contains("PrivateKey = ${generated.private_key}"));
        assert!(application.contains("PersistentKeepalive = ${keepalive}"));
        assert!(application.contains("window.QRCode.toCanvas"));
        assert!(application.contains("downloadGeneratedWireGuardConfig"));
        for endpoint in [
            "/wireguard/peers?network_code=",
            "request('/wireguard/peers/generated'",
            "/wireguard/peers/enabled",
            "/wireguard/peers/profile",
            "/wireguard/peers/config?network_code=",
            "/wireguard/peer_ips?network_code=",
            "request('/wireguard/peers'",
            "request('/wireguard/peer_ips'",
        ] {
            assert!(
                application.contains(endpoint),
                "embedded console must include WireGuard endpoint {endpoint}"
            );
        }
        assert!(!application.contains("new Function"));
        assert!(!application.contains("cdn.tailwindcss.com"));
        assert!(!application.contains("unpkg.com"));
        assert!(!application.contains("cdnjs.cloudflare.com"));

        let qrcode = Assets::get("assets/qrcode.min.js")
            .expect("embedded qrcode.min.js must exist for offline QR generation");
        assert!(qrcode.data.len() > 10_000);
        assert!(Assets::get("licenses/qrcode.txt").is_some());
        assert!(Assets::get("licenses/dijkstrajs.txt").is_some());
    }

    #[tokio::test]
    async fn wireguard_peer_ip_routes_require_auth_and_use_runtime_service() {
        const SECRET: &str = "module-2-2-api-secret";
        let control_service = ControlService::new(
            Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24),
            HashMap::new(),
            Duration::from_secs(60),
        )
        .await;
        control_service
            .add_network(
                "network-a".to_string(),
                Ipv4Addr::new(10, 26, 0, 1),
                24,
                None,
            )
            .await
            .unwrap();
        let network_state = control_service
            .wireguard_network_state("network-a")
            .await
            .unwrap();
        network_state.record_tx_traffic(Ipv4Addr::new(10, 26, 0, 2), 123);
        network_state.record_rx_traffic(Ipv4Addr::new(10, 26, 0, 3), 456);
        let app = build_app(AppState {
            control_service,
            auth_config: AuthConfig {
                username: "admin".to_string(),
                password: "admin".to_string(),
                jwt_secret: SECRET.to_string(),
            },
            login_limiter: LoginLimiter::default(),
            status_config: test_status_config(),
            wireguard_autostart: None,
            started_at: Instant::now(),
            dashboard_sampler: Arc::new(super::DashboardSampler::new(PathBuf::from("."))),
        });

        let unauthorized = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/api/wireguard/peer_ips")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"network_code":"network-a","peer_id":"peer-a","ip":"10.26.0.2"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);

        let unauthorized_dashboard = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/dashboard/snapshot")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthorized_dashboard.status(), StatusCode::UNAUTHORIZED);

        let token = jsonwebtoken::encode(
            &Header::default(),
            &Claims {
                sub: "admin".to_string(),
                exp: 4_102_444_800,
                csrf: None,
            },
            &EncodingKey::from_secret(SECRET.as_bytes()),
        )
        .unwrap();
        let authorization = format!("Bearer {token}");

        let status = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/status")
                    .header(header::AUTHORIZATION, &authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(status.status(), StatusCode::OK);
        let status_body = to_bytes(status.into_body(), usize::MAX).await.unwrap();
        let status_body = String::from_utf8_lossy(&status_body);
        assert!(status_body.contains(r#""version":"2.0.0""#));
        assert!(status_body.contains(r#""persistence_enabled":false"#));
        assert!(status_body.contains(r#""web":"127.0.0.1:29871""#));
        assert!(status_body.contains(r#""active_peers":0"#));
        assert!(!status_body.contains(SECRET));
        assert!(!status_body.contains("password"));

        let dashboard = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/dashboard/snapshot")
                    .header(header::AUTHORIZATION, &authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(dashboard.status(), StatusCode::OK);
        let dashboard_body = to_bytes(dashboard.into_body(), usize::MAX).await.unwrap();
        let dashboard_body = String::from_utf8_lossy(&dashboard_body);
        assert!(dashboard_body.contains(r#""tx_bytes_total":123"#));
        assert!(dashboard_body.contains(r#""rx_bytes_total":456"#));
        assert!(dashboard_body.contains(r#""cpu_percent":null"#));
        for forbidden in [SECRET, "password", "jwt_secret", "private_key", "data_root"] {
            assert!(!dashboard_body.contains(forbidden));
        }

        let missing_network = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/devices?code=missing")
                    .header(header::AUTHORIZATION, &authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(missing_network.status(), StatusCode::NOT_FOUND);

        let duplicate_network = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/networks")
                    .header(header::AUTHORIZATION, &authorization)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"network_code":"network-a","gateway":"10.26.0.1","netmask":24}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(duplicate_network.status(), StatusCode::CONFLICT);

        let unavailable_peer_server = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/peer_servers")
                    .header(header::AUTHORIZATION, &authorization)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(r#"{"server_addr":"127.0.0.1:29873"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            unavailable_peer_server.status(),
            StatusCode::SERVICE_UNAVAILABLE
        );

        let invalid_ip = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/api/wireguard/peer_ips")
                    .header(header::AUTHORIZATION, &authorization)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"network_code":"network-a","peer_id":"peer-a","ip":"not-an-ip"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(invalid_ip.status(), StatusCode::BAD_REQUEST);
        let invalid_ip_body = to_bytes(invalid_ip.into_body(), usize::MAX).await.unwrap();
        assert!(String::from_utf8_lossy(&invalid_ip_body).contains(r#""code":400"#));

        let reserve = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/api/wireguard/peer_ips")
                    .header(header::AUTHORIZATION, &authorization)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"network_code":"network-a","peer_id":"peer-a","ip":"10.26.0.2"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(reserve.status(), StatusCode::OK);
        let reserve_body = to_bytes(reserve.into_body(), usize::MAX).await.unwrap();
        assert!(String::from_utf8_lossy(&reserve_body).contains("预留成功"));

        let list = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/wireguard/peer_ips?network_code=network-a")
                    .header(header::AUTHORIZATION, &authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(list.status(), StatusCode::OK);
        let list_body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
        let list_body = String::from_utf8_lossy(&list_body);
        assert!(list_body.contains(r#""peer_id":"peer-a""#));
        assert!(list_body.contains(r#""ip":"10.26.0.2""#));

        let release = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri("/api/wireguard/peer_ips?network_code=network-a&peer_id=peer-a")
                    .header(header::AUTHORIZATION, &authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(release.status(), StatusCode::OK);
        let release_body = to_bytes(release.into_body(), usize::MAX).await.unwrap();
        assert!(String::from_utf8_lossy(&release_body).contains(r#""data":true"#));

        let empty_list = app
            .oneshot(
                Request::builder()
                    .uri("/api/wireguard/peer_ips?network_code=network-a")
                    .header(header::AUTHORIZATION, authorization)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let empty_list_body = to_bytes(empty_list.into_body(), usize::MAX).await.unwrap();
        assert!(String::from_utf8_lossy(&empty_list_body).contains(r#""data":[]"#));
    }

    #[tokio::test]
    async fn browser_session_uses_httponly_cookie_csrf_and_security_headers() {
        const SECRET: &str = "module-6-1-browser-secret";
        let control_service = ControlService::new(
            Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24),
            HashMap::new(),
            Duration::from_secs(60),
        )
        .await;
        let app = build_app(AppState {
            control_service,
            auth_config: AuthConfig {
                username: "admin".to_string(),
                password: "strong-password-123".to_string(),
                jwt_secret: SECRET.to_string(),
            },
            login_limiter: LoginLimiter::default(),
            status_config: test_status_config(),
            wireguard_autostart: None,
            started_at: Instant::now(),
            dashboard_sampler: Arc::new(super::DashboardSampler::new(PathBuf::from("."))),
        });
        let remote: SocketAddr = "127.0.0.1:41000".parse().unwrap();
        let login = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/login")
                    .header(header::CONTENT_TYPE, "application/json")
                    .extension(ConnectInfo(remote))
                    .body(Body::from(
                        r#"{"username":"admin","password":"strong-password-123"}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(login.status(), StatusCode::OK);
        let content_security_policy = login
            .headers()
            .get("content-security-policy")
            .unwrap()
            .to_str()
            .unwrap();
        assert!(content_security_policy.contains("script-src 'self'"));
        assert!(content_security_policy.contains("style-src 'self'"));
        assert!(content_security_policy.contains("script-src-attr 'none'"));
        assert!(content_security_policy.contains("style-src-attr 'none'"));
        assert!(!content_security_policy.contains("unsafe-inline"));
        assert!(!content_security_policy.contains("cdn.tailwindcss.com"));
        assert!(!content_security_policy.contains("unpkg.com"));
        assert!(!content_security_policy.contains("cdnjs.cloudflare.com"));
        assert!(!login.headers().contains_key("access-control-allow-origin"));
        let set_cookie = login
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap()
            .to_string();
        assert!(set_cookie.contains("HttpOnly"));
        assert!(set_cookie.contains("SameSite=Strict"));
        let cookie = set_cookie.split(';').next().unwrap().to_string();
        let body = to_bytes(login.into_body(), usize::MAX).await.unwrap();
        let body = String::from_utf8(body.to_vec()).unwrap();
        let csrf = body
            .split_once(r#""csrf_token":""#)
            .unwrap()
            .1
            .split('"')
            .next()
            .unwrap();

        let get_networks = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/networks")
                    .header(header::COOKIE, &cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(get_networks.status(), StatusCode::OK);
        assert_eq!(
            get_networks.headers().get(header::CACHE_CONTROL).unwrap(),
            "no-store"
        );

        let without_csrf = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/networks")
                    .header(header::COOKIE, &cookie)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        r#"{"network_code":"cookie-test","gateway":"10.26.0.1","netmask":24}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(without_csrf.status(), StatusCode::FORBIDDEN);

        let with_csrf = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/networks")
                    .header(header::COOKIE, cookie)
                    .header(header::CONTENT_TYPE, "application/json")
                    .header(super::web_security::CSRF_HEADER, csrf)
                    .body(Body::from(
                        r#"{"network_code":"cookie-test","gateway":"10.26.0.1","netmask":24}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(with_csrf.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn embedded_static_handler_rejects_parent_segments() {
        let response = super::static_handler(Uri::from_static("/../Cargo.toml"))
            .await
            .into_response();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
}

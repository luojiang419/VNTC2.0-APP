use crate::protocol::ProtoToBytesMut;
use crate::protocol::server_message::{Payload, *};
use crate::server::control_server::db::{self, PeerServerRecord, PeerServerSource};
use crate::server::network_state_provider::NetworkStateProvider;
use crate::server::wireguard_bridge::RelayOrigin;
use anyhow::{Context, Result, bail};
use bytes::Bytes;
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use prost::Message;
use quinn::crypto::rustls::QuicClientConfig;
use quinn::{ClientConfig, Endpoint, RecvStream, SendStream};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use sha2::{Digest, Sha256};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::task::JoinHandle;
use tokio_util::codec::{FramedRead, FramedWrite, LengthDelimitedCodec};

const DEFAULT_CLIENT_LATENCY_MS: u32 = 10;
const DEFAULT_SERVER_LATENCY_MS: u32 = 10;
const PING_INTERVAL_SECS: u64 = 30;
const NETWORK_SYNC_INTERVAL_SECS: u64 = 30;
const MAX_ROUTES_PER_IP: usize = 5;
const PEER_PROTOCOL_VERSION: u32 = 2;
const CAPABILITY_PEER_IDENTITY_V1: u64 = 1;
const CAPABILITY_CLUSTER_LEASE_V1: u64 = 1 << 1;
const CAPABILITY_WIREGUARD_BROADCAST_V1: u64 = 1 << 2;
const CAPABILITY_WIREGUARD_ENDPOINT_SYNC_V1: u64 = 1 << 3;
const PEER_RESOLVE_TIMEOUT: Duration = Duration::from_secs(10);
const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const BROADCAST_HOP_LIMIT: u32 = 8;
const BROADCAST_SEEN_TTL: Duration = Duration::from_secs(120);
const MAX_BROADCAST_SEEN: usize = 4096;

#[derive(Clone)]
pub struct PeerServerInfo {
    inner: Arc<parking_lot::RwLock<PeerServerInfoInner>>,
}

struct PeerServerInfoInner {
    addr: String,
    resolved_addr: Option<SocketAddr>,
    last_resolved_at: Option<u64>,
    last_error: Option<String>,
    remote_server_id: Option<String>,
    remote_protocol_version: u32,
    remote_capabilities: u64,
    cluster_compatible: bool,
    route_only: bool,
    latency_ms: u32,
    sender: Option<tokio::sync::mpsc::Sender<Bytes>>,
    connection: Option<quinn::Connection>,
    connected: bool,
    is_outbound: bool,
}

impl PeerServerInfo {
    pub fn new(addr: String, is_outbound: bool) -> Self {
        Self {
            inner: Arc::new(parking_lot::RwLock::new(PeerServerInfoInner {
                addr,
                resolved_addr: None,
                last_resolved_at: None,
                last_error: None,
                remote_server_id: None,
                remote_protocol_version: 0,
                remote_capabilities: 0,
                cluster_compatible: false,
                route_only: true,
                latency_ms: DEFAULT_SERVER_LATENCY_MS,
                sender: None,
                connection: None,
                connected: false,
                is_outbound,
            })),
        }
    }

    pub fn set_connected(
        &self,
        sender: tokio::sync::mpsc::Sender<Bytes>,
        connection: quinn::Connection,
    ) {
        let mut inner = self.inner.write();
        inner.sender = Some(sender);
        inner.connection = Some(connection);
        inner.connected = true;
        inner.last_error = None;
    }

    pub fn set_disconnected(&self) {
        let mut inner = self.inner.write();
        inner.sender = None;
        inner.connection = None;
        inner.connected = false;
    }

    pub fn set_resolution(&self, address: SocketAddr) {
        let mut inner = self.inner.write();
        inner.resolved_addr = Some(address);
        inner.last_resolved_at = Some(unix_timestamp_secs());
        inner.last_error = None;
    }

    pub fn set_last_error(&self, error: impl Into<String>) {
        self.inner.write().last_error = Some(error.into());
    }

    pub fn set_remote_metadata(
        &self,
        server_id: String,
        version: u32,
        capabilities: u64,
        cluster_compatible: bool,
    ) {
        let mut inner = self.inner.write();
        inner.remote_server_id = (!server_id.is_empty()).then_some(server_id);
        inner.remote_protocol_version = version;
        inner.remote_capabilities = capabilities;
        inner.cluster_compatible = cluster_compatible;
        inner.route_only =
            version < PEER_PROTOCOL_VERSION || capabilities & CAPABILITY_PEER_IDENTITY_V1 == 0;
    }

    pub fn get_resolved_addr(&self) -> Option<SocketAddr> {
        self.inner.read().resolved_addr
    }

    pub fn get_last_resolved_at(&self) -> Option<u64> {
        self.inner.read().last_resolved_at
    }

    pub fn get_last_error(&self) -> Option<String> {
        self.inner.read().last_error.clone()
    }

    pub fn get_remote_server_id(&self) -> Option<String> {
        self.inner.read().remote_server_id.clone()
    }

    pub fn get_remote_protocol_version(&self) -> u32 {
        self.inner.read().remote_protocol_version
    }

    pub fn get_remote_capabilities(&self) -> u64 {
        self.inner.read().remote_capabilities
    }

    pub fn is_route_only(&self) -> bool {
        self.inner.read().route_only
    }

    pub fn is_cluster_compatible(&self) -> bool {
        self.inner.read().cluster_compatible
    }

    pub fn update_latency(&self, latency: u32) {
        self.inner.write().latency_ms = latency;
    }

    pub fn get_latency(&self) -> u32 {
        self.inner.read().latency_ms
    }

    pub fn is_connected(&self) -> bool {
        self.inner.read().connected
    }

    pub fn get_addr(&self) -> String {
        self.inner.read().addr.clone()
    }

    pub fn is_outbound(&self) -> bool {
        self.inner.read().is_outbound
    }

    pub async fn send(&self, data: Bytes) -> Result<()> {
        let sender = {
            let guard = self.inner.read();
            guard.sender.clone()
        };

        if let Some(sender) = sender {
            sender.send(data).await?;
            Ok(())
        } else {
            bail!("Not connected")
        }
    }

    pub fn send_datagram(&self, data: Bytes) -> Result<()> {
        let conn = {
            let guard = self.inner.read();
            guard.connection.clone()
        };

        if let Some(conn) = conn {
            conn.send_datagram(data)?;
            Ok(())
        } else {
            bail!("Not connected")
        }
    }
}

#[derive(Clone)]
pub struct IpRouteInfo {
    pub peer_info: Arc<PeerServerInfo>,
    pub client_latency_ms: u32,
}

impl IpRouteInfo {
    /// 服务器间延迟 + 客户端延迟
    pub fn total_latency(&self) -> u32 {
        self.peer_info.get_latency() + self.client_latency_ms + 2
    }
}

pub struct PeerServerManager {
    token_hash: String,
    server_id: String,
    lease_authority: String,
    network_config_digest: String,
    capabilities: u64,
    network_state_provider: NetworkStateProvider,
    peer_servers: Arc<parking_lot::RwLock<Vec<Arc<PeerServerInfo>>>>,
    // network_code -> (ip -> 路由列表)，按延迟排序取 top N
    ip_to_routes: Arc<DashMap<String, Arc<DashMap<Ipv4Addr, Vec<IpRouteInfo>>>>>,
    last_resolved_addresses: Arc<DashMap<String, SocketAddr>>,
    pending_lease_acquires:
        Arc<DashMap<String, tokio::sync::oneshot::Sender<ServerLeaseAcquireResponse>>>,
    pending_lease_releases:
        Arc<DashMap<String, tokio::sync::oneshot::Sender<ServerLeaseReleaseResponse>>>,
    broadcast_seen: Arc<DashMap<String, std::time::Instant>>,
    cluster_ready: Arc<AtomicBool>,
    cluster_conflicts: Arc<AtomicU64>,
    cluster_revision: Arc<AtomicU64>,
    outbound_tasks: Arc<DashMap<String, (JoinHandle<()>, tokio::sync::oneshot::Sender<()>)>>,
}

impl PeerServerManager {
    pub fn new(token: String, network_state_provider: NetworkStateProvider) -> Self {
        Self::new_with_identity(token, network_state_provider, None, None, String::new())
    }

    pub fn new_with_identity(
        token: String,
        network_state_provider: NetworkStateProvider,
        server_id: Option<String>,
        lease_authority: Option<String>,
        network_config_digest: String,
    ) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let token_hash = hex::encode(hasher.finalize());
        let server_id = server_id.unwrap_or_default();
        let lease_authority = lease_authority.unwrap_or_default();
        let cluster_enabled = !server_id.is_empty() && !lease_authority.is_empty();
        let capabilities = CAPABILITY_PEER_IDENTITY_V1
            | CAPABILITY_WIREGUARD_BROADCAST_V1
            | CAPABILITY_WIREGUARD_ENDPOINT_SYNC_V1
            | if cluster_enabled {
                CAPABILITY_CLUSTER_LEASE_V1
            } else {
                0
            };

        Self {
            token_hash,
            server_id: server_id.clone(),
            lease_authority: lease_authority.clone(),
            network_config_digest,
            capabilities,
            network_state_provider,
            peer_servers: Arc::new(parking_lot::RwLock::new(Vec::new())),
            ip_to_routes: Arc::new(DashMap::new()),
            last_resolved_addresses: Arc::new(DashMap::new()),
            pending_lease_acquires: Arc::new(DashMap::new()),
            pending_lease_releases: Arc::new(DashMap::new()),
            broadcast_seen: Arc::new(DashMap::new()),
            cluster_ready: Arc::new(AtomicBool::new(
                !cluster_enabled || server_id == lease_authority,
            )),
            cluster_conflicts: Arc::new(AtomicU64::new(0)),
            cluster_revision: Arc::new(AtomicU64::new(0)),
            outbound_tasks: Arc::new(DashMap::new()),
        }
    }

    fn auth_request(&self) -> ServerAuthRequest {
        ServerAuthRequest {
            token_hash: self.token_hash.clone(),
            server_id: self.server_id.clone(),
            protocol_version: PEER_PROTOCOL_VERSION,
            capabilities: self.capabilities,
            network_config_digest: self.network_config_digest.clone(),
            lease_authority: self.lease_authority.clone(),
        }
    }

    fn auth_response(&self, success: bool, message: impl Into<String>) -> ServerAuthResponse {
        ServerAuthResponse {
            success,
            message: message.into(),
            server_id: self.server_id.clone(),
            protocol_version: PEER_PROTOCOL_VERSION,
            capabilities: self.capabilities,
            network_config_digest: self.network_config_digest.clone(),
            lease_authority: self.lease_authority.clone(),
        }
    }

    fn peer_cluster_compatible(
        &self,
        remote_server_id: &str,
        remote_capabilities: u64,
        remote_digest: &str,
        remote_authority: &str,
    ) -> bool {
        !self.server_id.is_empty()
            && !remote_server_id.is_empty()
            && remote_server_id != self.server_id
            && remote_capabilities & CAPABILITY_CLUSTER_LEASE_V1 != 0
            && remote_authority == self.lease_authority
            && remote_digest == self.network_config_digest
    }

    pub fn cluster_enabled(&self) -> bool {
        !self.server_id.is_empty() && !self.lease_authority.is_empty()
    }

    pub fn cluster_ready(&self) -> bool {
        self.cluster_ready.load(Ordering::Acquire)
    }

    pub fn cluster_conflicts(&self) -> u64 {
        self.cluster_conflicts.load(Ordering::Relaxed)
    }

    pub fn cluster_revision(&self) -> u64 {
        self.cluster_revision.load(Ordering::Relaxed)
    }

    pub fn server_id(&self) -> &str {
        &self.server_id
    }

    pub fn lease_authority(&self) -> &str {
        &self.lease_authority
    }

    fn is_lease_authority(&self) -> bool {
        self.cluster_enabled() && self.server_id == self.lease_authority
    }

    fn authority_peer(&self) -> Option<Arc<PeerServerInfo>> {
        self.peer_servers.read().iter().find_map(|peer| {
            (peer.is_connected()
                && peer.is_cluster_compatible()
                && peer.get_remote_server_id().as_deref() == Some(self.lease_authority.as_str()))
            .then(|| peer.clone())
        })
    }

    pub async fn acquire_lease(
        &self,
        network_code: &str,
        owner_type: &str,
        owner_id: &str,
        requested_ip: Option<Ipv4Addr>,
        network: ipnet::Ipv4Net,
        gateway: Ipv4Addr,
        lease_duration: Duration,
        static_reservation: bool,
    ) -> Result<Option<db::ClusterLeaseGrant>> {
        if !self.cluster_enabled() {
            return Ok(None);
        }
        if !self.is_lease_authority() && !self.cluster_ready() {
            bail!("集群租约尚未就绪，拒绝本地地址分配");
        }
        let request = ServerLeaseAcquireRequest {
            request_id: new_request_id(),
            network_code: network_code.to_string(),
            owner_type: owner_type.to_string(),
            owner_id: owner_id.to_string(),
            requested_ip: requested_ip.map(u32::from).unwrap_or_default(),
            has_requested_ip: requested_ip.is_some(),
            network_base: u32::from(network.network()),
            prefix_len: u32::from(network.prefix_len()),
            gateway: u32::from(gateway),
            lease_duration_secs: lease_duration.as_secs(),
            static_reservation,
            origin_server_id: self.server_id.clone(),
        };
        self.acquire_lease_request(request).await.map(Some)
    }

    async fn acquire_lease_request(
        &self,
        request: ServerLeaseAcquireRequest,
    ) -> Result<db::ClusterLeaseGrant> {
        if self.is_lease_authority() {
            let grant = db::acquire_cluster_lease(&self.db_lease_request(&request)?).await?;
            self.cluster_revision
                .store(grant.revision, Ordering::Release);
            return Ok(grant);
        }
        let peer = self
            .authority_peer()
            .ok_or_else(|| anyhow::anyhow!("租约权威服务器不可用"))?;
        let request_id = request.request_id.clone();
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        self.pending_lease_acquires
            .insert(request_id.clone(), response_tx);
        let message = ServerMessage {
            payload: Some(Payload::LeaseAcquireReq(request)),
        };
        if let Err(error) = peer.send(message.encode_bytes_mut().freeze()).await {
            self.pending_lease_acquires.remove(&request_id);
            return Err(error);
        }
        let response = tokio::time::timeout(Duration::from_secs(5), response_rx)
            .await
            .map_err(|_| anyhow::anyhow!("申请集群租约超时"))?
            .map_err(|_| anyhow::anyhow!("集群租约响应通道已关闭"))?;
        if !response.success {
            bail!("集群租约申请失败: {}", response.message);
        }
        self.cluster_revision
            .store(response.revision, Ordering::Release);
        Ok(db::ClusterLeaseGrant {
            ip: Ipv4Addr::from(response.ip),
            revision: response.revision,
            expires_at: response.expires_at,
        })
    }

    pub async fn release_lease(
        &self,
        network_code: &str,
        owner_type: &str,
        owner_id: &str,
    ) -> Result<()> {
        if !self.cluster_enabled() {
            return Ok(());
        }
        if self.is_lease_authority() {
            let revision =
                db::release_cluster_lease(network_code, owner_type, owner_id, &self.server_id)
                    .await?;
            self.cluster_revision.store(revision, Ordering::Release);
            return Ok(());
        }
        let peer = self
            .authority_peer()
            .ok_or_else(|| anyhow::anyhow!("租约权威服务器不可用"))?;
        let request_id = new_request_id();
        let request = ServerLeaseReleaseRequest {
            request_id: request_id.clone(),
            network_code: network_code.to_string(),
            owner_type: owner_type.to_string(),
            owner_id: owner_id.to_string(),
        };
        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        self.pending_lease_releases
            .insert(request_id.clone(), response_tx);
        if let Err(error) = peer
            .send(
                ServerMessage {
                    payload: Some(Payload::LeaseReleaseReq(request)),
                }
                .encode_bytes_mut()
                .freeze(),
            )
            .await
        {
            self.pending_lease_releases.remove(&request_id);
            return Err(error);
        }
        let response = tokio::time::timeout(Duration::from_secs(5), response_rx)
            .await
            .map_err(|_| anyhow::anyhow!("释放集群租约超时"))?
            .map_err(|_| anyhow::anyhow!("集群租约响应通道已关闭"))?;
        if !response.success {
            bail!("释放集群租约失败: {}", response.message);
        }
        self.cluster_revision
            .store(response.revision, Ordering::Release);
        Ok(())
    }

    fn db_lease_request(
        &self,
        request: &ServerLeaseAcquireRequest,
    ) -> Result<db::ClusterLeaseRequest> {
        anyhow::ensure!(request.prefix_len <= 32, "集群租约网段前缀无效");
        let network = ipnet::Ipv4Net::new(
            Ipv4Addr::from(request.network_base),
            request.prefix_len as u8,
        )?;
        Ok(db::ClusterLeaseRequest {
            network_code: request.network_code.clone(),
            owner_type: request.owner_type.clone(),
            owner_id: request.owner_id.clone(),
            requested_ip: request
                .has_requested_ip
                .then(|| Ipv4Addr::from(request.requested_ip)),
            network,
            gateway: Ipv4Addr::from(request.gateway),
            lease_duration_secs: request.lease_duration_secs,
            static_reservation: request.static_reservation,
            authority_id: self.server_id.clone(),
            origin_server_id: request.origin_server_id.clone(),
        })
    }

    async fn reconcile_local_allocations(&self) -> Result<()> {
        if !self.cluster_enabled() || self.is_lease_authority() {
            self.cluster_ready.store(true, Ordering::Release);
            return Ok(());
        }
        self.cluster_ready.store(false, Ordering::Release);
        let allocations = db::load_local_ip_allocations().await?;
        let mut conflicts = 0_u64;
        for allocation in allocations {
            let request = ServerLeaseAcquireRequest {
                request_id: new_request_id(),
                network_code: allocation.network_code.clone(),
                owner_type: allocation.owner_type.clone(),
                owner_id: allocation.owner_id.clone(),
                requested_ip: allocation.ip.into(),
                has_requested_ip: true,
                network_base: allocation.network.network().into(),
                prefix_len: u32::from(allocation.network.prefix_len()),
                gateway: allocation.gateway.into(),
                lease_duration_secs: allocation.lease_duration_secs,
                static_reservation: allocation.owner_type == "wireguard_peer",
                origin_server_id: self.server_id.clone(),
            };
            match self.acquire_lease_request(request).await {
                Ok(grant) if grant.ip == allocation.ip => {}
                Ok(grant) => {
                    conflicts += 1;
                    log::error!(
                        "Cluster reconciliation changed allocation unexpectedly: network={}, owner={}/{}, local={}, authority={}",
                        allocation.network_code,
                        allocation.owner_type,
                        allocation.owner_id,
                        allocation.ip,
                        grant.ip
                    );
                }
                Err(error) => {
                    conflicts += 1;
                    log::error!(
                        "Cluster allocation conflict: network={}, owner={}/{}, ip={}, error={}",
                        allocation.network_code,
                        allocation.owner_type,
                        allocation.owner_id,
                        allocation.ip,
                        error
                    );
                }
            }
        }
        self.cluster_conflicts.store(conflicts, Ordering::Release);
        self.cluster_ready.store(conflicts == 0, Ordering::Release);
        anyhow::ensure!(conflicts == 0, "检测到 {conflicts} 个集群地址冲突");
        Ok(())
    }

    pub async fn start_server(
        self: Arc<Self>,
        bind_addr: SocketAddr,
        certs: Vec<CertificateDer<'static>>,
        key: PrivateKeyDer<'static>,
    ) -> Result<()> {
        let config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .context("TLS config error")?;

        let server_crypto = quinn::crypto::rustls::QuicServerConfig::try_from(config)
            .map_err(|e| anyhow::anyhow!("QUIC TLS config error: {:?}", e))?;
        let server_config = quinn::ServerConfig::with_crypto(Arc::new(server_crypto));
        let endpoint = quinn::Endpoint::server(server_config, bind_addr)
            .context(format!("peer server error:{}", bind_addr))?;

        log::info!("Peer server listening on: {}", bind_addr);

        tokio::spawn(async move {
            if let Err(e) = self.accept_loop(endpoint).await {
                log::error!("peer server accept_loop error: {:?}", e);
            }
        });

        Ok(())
    }

    async fn accept_loop(self: Arc<Self>, endpoint: Endpoint) -> Result<()> {
        loop {
            let connecting = endpoint.accept().await.context("peer accept error")?;
            let remote_addr = connecting.remote_address();
            let manager = self.clone();

            tokio::spawn(async move {
                match connecting.await {
                    Ok(connection) => {
                        log::info!("Peer connection from: {}", remote_addr);
                        match tokio::time::timeout(Duration::from_secs(10), connection.accept_bi())
                            .await
                        {
                            Ok(Ok((send_stream, recv_stream))) => {
                                if let Err(e) = manager
                                    .handle_peer_connection(
                                        connection,
                                        send_stream,
                                        recv_stream,
                                        remote_addr,
                                    )
                                    .await
                                {
                                    log::error!(
                                        "handle_peer_connection error: {:?}, addr={}",
                                        e,
                                        remote_addr
                                    );
                                }
                            }
                            Ok(Err(e)) => {
                                log::info!("peer connection closed: {}, {:?}", remote_addr, e);
                            }
                            Err(_) => {
                                log::error!("peer accept_bi timeout: {}", remote_addr);
                            }
                        }
                    }
                    Err(e) => {
                        log::error!("peer connect error: {:?}, addr={}", e, remote_addr);
                    }
                }
            });
        }
    }

    async fn run_peer_communication_loop(
        &self,
        peer_info: Arc<PeerServerInfo>,
        connection: quinn::Connection,
        mut framed_write: FramedWrite<SendStream, LengthDelimitedCodec>,
        mut framed_read: FramedRead<RecvStream, LengthDelimitedCodec>,
        mut rx: tokio::sync::mpsc::Receiver<Bytes>,
    ) {
        let manager = self.clone();
        let mut network_codes = std::collections::HashSet::<String>::new();

        let mut network_sync_interval =
            tokio::time::interval(Duration::from_secs(NETWORK_SYNC_INTERVAL_SECS));
        network_sync_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        let mut ping_interval = tokio::time::interval(Duration::from_secs(PING_INTERVAL_SECS));
        ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                Some(data) = rx.recv() => {
                    if let Err(e) = framed_write.send(data).await {
                        log::warn!("peer send error: {}", e);
                        break;
                    }
                }
                Some(rs) = framed_read.next() => {
                    match rs {
                        Ok(bytes) => {
                            if let Err(e) = manager.handle_peer_message(&peer_info, &mut network_codes, bytes.freeze()).await {
                                log::error!("handle_peer_message error: {:?}", e);
                            }
                        }
                        Err(e) => {
                            log::warn!("peer recv error: {}", e);
                            break;
                        }
                    }
                }
                datagram = connection.read_datagram() => {
                    match datagram {
                        Ok(bytes) => {
                            if let Err(e) = manager.handle_peer_message(&peer_info, &mut network_codes, bytes).await {
                                log::error!("handle peer datagram error: {:?}", e);
                            }
                        }
                        Err(e) => {
                            log::warn!("peer datagram receive error: {}", e);
                            break;
                        }
                    }
                }
                _ = network_sync_interval.tick() => {
                    if let Err(e) = manager.pull_client_info_from_peer(&peer_info).await {
                        log::warn!("Failed to pull client info from peer {}: {:?}", peer_info.get_addr(), e);
                    }
                }
                _ = ping_interval.tick() => {
                    if let Err(e) = manager.ping_peer(&peer_info).await {
                        log::warn!("Failed to ping peer {}: {:?}", peer_info.get_addr(), e);
                    }
                }
                else => break,
            }
        }

        peer_info.set_disconnected();
        if self.cluster_enabled()
            && !self.is_lease_authority()
            && peer_info.get_remote_server_id().as_deref() == Some(self.lease_authority.as_str())
        {
            self.cluster_ready.store(false, Ordering::Release);
        }
        manager.cleanup_routes(&peer_info, &network_codes);
        if !peer_info.is_outbound() {
            manager
                .peer_servers
                .write()
                .retain(|p| !Arc::ptr_eq(p, &peer_info));
        }

        log::info!("Peer connection closed: {}", peer_info.get_addr());
    }

    async fn handle_peer_connection(
        &self,
        connection: quinn::Connection,
        send_stream: SendStream,
        recv_stream: RecvStream,
        addr: SocketAddr,
    ) -> Result<()> {
        let mut framed_write = FramedWrite::new(send_stream, LengthDelimitedCodec::new());
        let mut framed_read = FramedRead::new(recv_stream, LengthDelimitedCodec::new());

        let first = tokio::time::timeout(Duration::from_secs(5), framed_read.next()).await;
        let Ok(first) = first else {
            bail!("peer auth timeout");
        };
        let Some(first) = first else {
            bail!("peer connection closed");
        };
        let buf = first?;

        let msg = ServerMessage::decode(&buf[..])?;
        let ServerMessage {
            payload: Some(Payload::AuthReq(auth_req)),
        } = msg
        else {
            bail!("expected auth request");
        };

        if auth_req.token_hash != self.token_hash {
            let response = ServerMessage {
                payload: Some(Payload::AuthRes(self.auth_response(false, "Invalid token"))),
            };
            let _ = framed_write
                .send(response.encode_bytes_mut().freeze())
                .await;
            bail!("Invalid token from peer");
        }
        if !self.server_id.is_empty() && auth_req.server_id == self.server_id {
            let response = ServerMessage {
                payload: Some(Payload::AuthRes(
                    self.auth_response(false, "Duplicate server_id"),
                )),
            };
            let _ = framed_write
                .send(response.encode_bytes_mut().freeze())
                .await;
            bail!("Duplicate server_id from peer");
        }

        log::info!("Peer server authenticated from: {}", addr);

        let response = ServerMessage {
            payload: Some(Payload::AuthRes(self.auth_response(true, "OK"))),
        };
        framed_write
            .send(response.encode_bytes_mut().freeze())
            .await?;

        let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(1024);
        let peer_info = Arc::new(PeerServerInfo::new(addr.to_string(), false));
        peer_info.set_resolution(addr);
        let cluster_compatible = self.peer_cluster_compatible(
            &auth_req.server_id,
            auth_req.capabilities,
            &auth_req.network_config_digest,
            &auth_req.lease_authority,
        );
        peer_info.set_remote_metadata(
            auth_req.server_id,
            auth_req.protocol_version,
            auth_req.capabilities,
            cluster_compatible,
        );
        peer_info.set_connected(tx, connection.clone());
        self.peer_servers.write().push(peer_info.clone());

        let manager = self.clone();
        tokio::spawn(async move {
            manager
                .run_peer_communication_loop(peer_info, connection, framed_write, framed_read, rx)
                .await;
        });

        Ok(())
    }

    /// 连接到对端，断线后自动重连
    pub fn connect_to_peer(
        self: Arc<Self>,
        peer_addr: String,
    ) -> (JoinHandle<()>, tokio::sync::oneshot::Sender<()>) {
        let (stop_tx, mut stop_rx) = tokio::sync::oneshot::channel::<()>();
        let peer_info = Arc::new(PeerServerInfo::new(peer_addr.clone(), true));
        self.peer_servers.write().push(peer_info.clone());

        let handle = tokio::spawn(async move {
            loop {
                log::info!("Connecting to peer server: {}", peer_addr);

                tokio::select! {
                    result = self.clone().connect_to_peer_once(peer_addr.clone(), peer_info.clone()) => {
                        match result {
                            Ok(_) => {
                                log::info!("Peer connection closed: {}, will reconnect...", peer_addr);
                            }
                            Err(e) => {
                                peer_info.set_disconnected();
                                peer_info.set_last_error(e.to_string());
                                log::warn!(
                                    "Failed to connect to peer {}: {:?}, will retry...",
                                    peer_addr,
                                    e
                                );
                            }
                        }
                    }
                    _ = &mut stop_rx => {
                        log::info!("Stop signal received for peer: {}", peer_addr);
                        break;
                    }
                }

                let delay_secs = rand::random::<u64>() % 8 + 3;
                log::info!("Reconnecting to {} in {} seconds...", peer_addr, delay_secs);

                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(delay_secs)) => {}
                    _ = &mut stop_rx => {
                        log::info!("Stop signal received during reconnect delay for peer: {}", peer_addr);
                        break;
                    }
                }
            }
            peer_info.set_disconnected();
            self.peer_servers
                .write()
                .retain(|peer| !Arc::ptr_eq(peer, &peer_info));
            log::info!("Connection task stopped for peer: {}", peer_addr);
        });

        (handle, stop_tx)
    }

    async fn connect_to_peer_once(
        self: Arc<Self>,
        peer_addr: String,
        peer_info: Arc<PeerServerInfo>,
    ) -> Result<()> {
        let peer_endpoint = PeerEndpoint::parse(&peer_addr)?;
        let client_crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
            .with_no_client_auth();

        let client_config = ClientConfig::new(Arc::new(
            QuicClientConfig::try_from(client_crypto)
                .map_err(|e| anyhow::anyhow!("QUIC client config error: {:?}", e))?,
        ));

        let mut addresses = peer_endpoint.resolve().await?;
        if let Some(last) = self
            .last_resolved_addresses
            .get(&peer_addr)
            .map(|entry| *entry)
        {
            addresses.sort_by_key(|address| *address != last);
        }

        let mut last_error = None;
        let mut connected = None;
        for addr in addresses {
            let bind_addr = if addr.is_ipv4() {
                "0.0.0.0:0".parse()?
            } else {
                "[::]:0".parse()?
            };
            let mut endpoint = Endpoint::client(bind_addr)?;
            endpoint.set_default_client_config(client_config.clone());
            let connecting = match endpoint.connect(addr, &peer_endpoint.server_name) {
                Ok(connecting) => connecting,
                Err(error) => {
                    last_error = Some(anyhow::anyhow!(error));
                    continue;
                }
            };
            match tokio::time::timeout(PEER_CONNECT_TIMEOUT, connecting).await {
                Ok(Ok(connection)) => {
                    connected = Some((endpoint, connection, addr));
                    break;
                }
                Ok(Err(error)) => last_error = Some(anyhow::anyhow!(error)),
                Err(_) => {
                    last_error = Some(anyhow::anyhow!("连接地址 {addr} 超时"));
                }
            }
        }
        let Some((_endpoint_guard, connection, resolved_addr)) = connected else {
            return Err(last_error.unwrap_or_else(|| anyhow::anyhow!("域名未解析出可连接地址")));
        };
        self.last_resolved_addresses
            .insert(peer_addr.clone(), resolved_addr);
        let (send_stream, recv_stream) = connection.open_bi().await?;

        let mut framed_write = FramedWrite::new(send_stream, LengthDelimitedCodec::new());
        let mut framed_read = FramedRead::new(recv_stream, LengthDelimitedCodec::new());

        let auth_req = ServerMessage {
            payload: Some(Payload::AuthReq(self.auth_request())),
        };
        framed_write
            .send(auth_req.encode_bytes_mut().freeze())
            .await?;

        let response = tokio::time::timeout(Duration::from_secs(5), framed_read.next()).await;
        let Ok(Some(Ok(buf))) = response else {
            bail!("auth response timeout or error");
        };

        let msg = ServerMessage::decode(&buf[..])?;
        let ServerMessage {
            payload: Some(Payload::AuthRes(auth_res)),
        } = msg
        else {
            bail!("expected auth response");
        };

        if !auth_res.success {
            bail!("auth failed: {}", auth_res.message);
        }

        log::info!("Connected to peer server: {}", peer_addr);

        let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(1024);
        peer_info.set_resolution(resolved_addr);
        let cluster_compatible = self.peer_cluster_compatible(
            &auth_res.server_id,
            auth_res.capabilities,
            &auth_res.network_config_digest,
            &auth_res.lease_authority,
        );
        peer_info.set_remote_metadata(
            auth_res.server_id,
            auth_res.protocol_version,
            auth_res.capabilities,
            cluster_compatible,
        );
        peer_info.set_connected(tx, connection.clone());

        if peer_info.is_cluster_compatible()
            && peer_info.get_remote_server_id().as_deref() == Some(self.lease_authority.as_str())
        {
            self.cluster_ready.store(false, Ordering::Release);
            let manager = self.clone();
            tokio::spawn(async move {
                if let Err(error) = manager.reconcile_local_allocations().await {
                    log::error!("集群租约启动同步失败: {error}");
                }
            });
        }

        self.run_peer_communication_loop(peer_info, connection, framed_write, framed_read, rx)
            .await;

        Ok(())
    }

    async fn handle_peer_message(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        network_codes: &mut std::collections::HashSet<String>,
        data: Bytes,
    ) -> Result<()> {
        let msg = ServerMessage::decode(&data[..])?;

        match msg.payload {
            Some(Payload::PingReq(ping)) => {
                self.handle_ping_request(peer_info, ping).await?;
            }
            Some(Payload::PingRes(pong)) => {
                self.handle_ping_response(peer_info, pong).await;
            }
            Some(Payload::ForwardData(forward)) => {
                self.handle_forward_data(forward).await;
            }
            Some(Payload::BroadcastData(broadcast)) => {
                self.handle_broadcast_data(peer_info, broadcast).await;
            }
            Some(Payload::ClientInfoReq(req)) => {
                self.handle_client_info_request_msg(peer_info, req).await?;
            }
            Some(Payload::ClientInfoRes(res)) => {
                self.handle_client_info_response(peer_info, network_codes, res)
                    .await;
            }
            Some(Payload::LeaseAcquireReq(request)) => {
                self.handle_lease_acquire_request(peer_info, request)
                    .await?;
            }
            Some(Payload::LeaseAcquireRes(response)) => {
                if let Some((_, sender)) = self.pending_lease_acquires.remove(&response.request_id)
                {
                    let _ = sender.send(response);
                }
            }
            Some(Payload::LeaseReleaseReq(request)) => {
                self.handle_lease_release_request(peer_info, request)
                    .await?;
            }
            Some(Payload::LeaseReleaseRes(response)) => {
                if let Some((_, sender)) = self.pending_lease_releases.remove(&response.request_id)
                {
                    let _ = sender.send(response);
                }
            }
            _ => {
                log::warn!("unexpected message from peer: {}", peer_info.get_addr());
            }
        }

        Ok(())
    }

    async fn handle_lease_acquire_request(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        request: ServerLeaseAcquireRequest,
    ) -> Result<()> {
        let request_id = request.request_id.clone();
        let response = if !self.is_lease_authority() {
            ServerLeaseAcquireResponse {
                request_id,
                success: false,
                message: "当前节点不是租约权威".to_string(),
                ip: 0,
                revision: self.cluster_revision(),
                expires_at: 0,
            }
        } else if !peer_info.is_cluster_compatible() {
            ServerLeaseAcquireResponse {
                request_id,
                success: false,
                message: "Peer 集群能力或网络配置不兼容".to_string(),
                ip: 0,
                revision: self.cluster_revision(),
                expires_at: 0,
            }
        } else {
            match self.db_lease_request(&request) {
                Ok(db_request) => match db::acquire_cluster_lease(&db_request).await {
                    Ok(grant) => {
                        self.cluster_revision
                            .store(grant.revision, Ordering::Release);
                        ServerLeaseAcquireResponse {
                            request_id,
                            success: true,
                            message: "OK".to_string(),
                            ip: grant.ip.into(),
                            revision: grant.revision,
                            expires_at: grant.expires_at,
                        }
                    }
                    Err(error) => ServerLeaseAcquireResponse {
                        request_id,
                        success: false,
                        message: error.to_string(),
                        ip: 0,
                        revision: self.cluster_revision(),
                        expires_at: 0,
                    },
                },
                Err(error) => ServerLeaseAcquireResponse {
                    request_id,
                    success: false,
                    message: error.to_string(),
                    ip: 0,
                    revision: self.cluster_revision(),
                    expires_at: 0,
                },
            }
        };
        peer_info
            .send(
                ServerMessage {
                    payload: Some(Payload::LeaseAcquireRes(response)),
                }
                .encode_bytes_mut()
                .freeze(),
            )
            .await
    }

    async fn handle_lease_release_request(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        request: ServerLeaseReleaseRequest,
    ) -> Result<()> {
        let result = if !self.is_lease_authority() || !peer_info.is_cluster_compatible() {
            Err(anyhow::anyhow!("当前连接不能释放权威租约"))
        } else {
            db::release_cluster_lease(
                &request.network_code,
                &request.owner_type,
                &request.owner_id,
                &self.server_id,
            )
            .await
        };
        let response = match result {
            Ok(revision) => {
                self.cluster_revision.store(revision, Ordering::Release);
                ServerLeaseReleaseResponse {
                    request_id: request.request_id,
                    success: true,
                    message: "OK".to_string(),
                    revision,
                }
            }
            Err(error) => ServerLeaseReleaseResponse {
                request_id: request.request_id,
                success: false,
                message: error.to_string(),
                revision: self.cluster_revision(),
            },
        };
        peer_info
            .send(
                ServerMessage {
                    payload: Some(Payload::LeaseReleaseRes(response)),
                }
                .encode_bytes_mut()
                .freeze(),
            )
            .await
    }

    async fn handle_forward_data(&self, forward: ServerForwardData) {
        if let Some(state) = self
            .network_state_provider
            .get_network_state(&forward.network_code)
        {
            use crate::protocol::ip_packet_protocol::NetPacket;
            if let Ok(packet) = NetPacket::new(forward.data) {
                let dest = Ipv4Addr::from(packet.dest_id());
                let origin = if forward.source_is_wireguard {
                    RelayOrigin::WireGuard
                } else {
                    RelayOrigin::Vnt
                };
                let data = Bytes::from(packet.into_buffer());
                if state.try_deliver(dest, data.clone(), origin)
                    == crate::server::network_state_provider::LocalDeliveryResult::Delivered
                {
                    state.record_rx_traffic(dest, data.len());
                    log::debug!("Forwarded data to local client: {}", dest);
                }
            }
        }
    }

    async fn handle_broadcast_data(
        &self,
        incoming_peer: &Arc<PeerServerInfo>,
        mut broadcast: ServerBroadcastData,
    ) {
        if incoming_peer.get_remote_capabilities() & CAPABILITY_WIREGUARD_BROADCAST_V1 == 0
            || broadcast.network_code.is_empty()
            || broadcast.broadcast_id.is_empty()
            || broadcast.broadcast_id.len() > 128
            || broadcast.data.len() > crate::server::wireguard_bridge::MAX_INNER_IPV4_PACKET_SIZE
            || broadcast.hops_remaining == 0
            || broadcast.hops_remaining > BROADCAST_HOP_LIMIT
        {
            return;
        }
        if !self.mark_broadcast_seen(&broadcast.broadcast_id) {
            return;
        }

        let source = Ipv4Addr::from(broadcast.source_ip);
        let origin = if broadcast.source_is_wireguard {
            RelayOrigin::WireGuard
        } else {
            RelayOrigin::Vnt
        };
        if let Some(state) = self
            .network_state_provider
            .get_network_state(&broadcast.network_code)
        {
            let _ = state.relay_wireguard_broadcast(source, &broadcast.data, origin);
        }

        broadcast.hops_remaining -= 1;
        if broadcast.hops_remaining > 0 {
            self.forward_broadcast_message(broadcast, Some(incoming_peer));
        }
    }

    fn mark_broadcast_seen(&self, broadcast_id: &str) -> bool {
        let now = std::time::Instant::now();
        if self.broadcast_seen.len() >= MAX_BROADCAST_SEEN {
            self.broadcast_seen
                .retain(|_, seen| now.saturating_duration_since(*seen) < BROADCAST_SEEN_TTL);
        }
        if let Some(mut seen) = self.broadcast_seen.get_mut(broadcast_id) {
            if now.saturating_duration_since(*seen) < BROADCAST_SEEN_TTL {
                return false;
            }
            *seen = now;
            return true;
        }
        self.broadcast_seen.insert(broadcast_id.to_string(), now);
        true
    }

    pub(crate) fn broadcast_wireguard(
        &self,
        network_code: &str,
        source: Ipv4Addr,
        data: &[u8],
        origin: RelayOrigin,
    ) -> usize {
        if data.len() > crate::server::wireguard_bridge::MAX_INNER_IPV4_PACKET_SIZE {
            return 0;
        }
        let broadcast_id = format!("{}:{}", self.server_id, new_request_id());
        self.mark_broadcast_seen(&broadcast_id);
        self.forward_broadcast_message(
            ServerBroadcastData {
                network_code: network_code.to_string(),
                data: data.to_vec(),
                source_ip: source.into(),
                broadcast_id,
                origin_server_id: self.server_id.clone(),
                hops_remaining: BROADCAST_HOP_LIMIT,
                source_is_wireguard: origin == RelayOrigin::WireGuard,
            },
            None,
        )
    }

    fn forward_broadcast_message(
        &self,
        broadcast: ServerBroadcastData,
        incoming_peer: Option<&Arc<PeerServerInfo>>,
    ) -> usize {
        let message = ServerMessage {
            payload: Some(Payload::BroadcastData(broadcast)),
        }
        .encode_bytes_mut()
        .freeze();
        let mut sent = 0;
        let mut remote_ids = std::collections::HashSet::new();
        for peer in self.get_peer_servers() {
            if !peer.is_connected()
                || peer.get_remote_capabilities() & CAPABILITY_WIREGUARD_BROADCAST_V1 == 0
                || incoming_peer.is_some_and(|incoming| Arc::ptr_eq(incoming, &peer))
            {
                continue;
            }
            let remote_id = peer
                .get_remote_server_id()
                .unwrap_or_else(|| peer.get_addr());
            if !remote_ids.insert(remote_id) {
                continue;
            }
            if peer.send_datagram(message.clone()).is_ok() {
                sent += 1;
            }
        }
        sent
    }

    async fn handle_ping_request(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        ping: ServerPingRequest,
    ) -> Result<()> {
        let response = ServerMessage {
            payload: Some(Payload::PingRes(ServerPingResponse {
                request_timestamp: ping.timestamp,
                response_timestamp: SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis()
                    as u64,
            })),
        };
        peer_info.send(response.encode_bytes_mut().freeze()).await?;
        Ok(())
    }

    async fn handle_ping_response(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        pong: ServerPingResponse,
    ) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let rtt = now.saturating_sub(pong.request_timestamp);

        let latency = (rtt / 2) as u32; // 单向延迟
        peer_info.update_latency(latency);
        log::debug!("Peer {} latency: {} ms", peer_info.get_addr(), latency);
    }

    async fn handle_client_info_request_msg(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        req: ServerClientInfoRequest,
    ) -> Result<()> {
        let response = self.handle_client_info_request(req.network_codes).await;

        let response_msg = ServerMessage {
            payload: Some(Payload::ClientInfoRes(response)),
        };

        peer_info
            .send(response_msg.encode_bytes_mut().freeze())
            .await?;
        Ok(())
    }

    /// 收到对端的客户端列表后更新路由表
    async fn handle_client_info_response(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        network_codes: &mut std::collections::HashSet<String>,
        res: ServerClientInfoResponse,
    ) {
        let accepts_endpoint_type =
            peer_info.get_remote_capabilities() & CAPABILITY_WIREGUARD_ENDPOINT_SYNC_V1 != 0;
        let remote_source = peer_info.get_addr();
        for net_info in res.networks {
            let network_code = net_info.network_code.clone();
            network_codes.insert(network_code.clone());

            let ip_map = self
                .ip_to_routes
                .entry(network_code.clone())
                .or_insert_with(Default::default)
                .value()
                .clone();

            let mut synced_ips = std::collections::HashSet::new();
            let mut remote_wireguard_ips = std::collections::HashSet::new();

            for client in net_info.clients {
                let ip = Ipv4Addr::from(client.ip);
                synced_ips.insert(ip);
                let is_wireguard = accepts_endpoint_type && client.is_wireguard;
                if is_wireguard {
                    remote_wireguard_ips.insert(ip);
                }

                let route_info = IpRouteInfo {
                    peer_info: peer_info.clone(),
                    client_latency_ms: client.latency_ms,
                };

                ip_map
                    .entry(ip)
                    .and_modify(|routes| {
                        if let Some(existing) = routes
                            .iter_mut()
                            .find(|r| Arc::ptr_eq(&r.peer_info, peer_info))
                        {
                            existing.client_latency_ms = client.latency_ms;
                        } else {
                            routes.push(route_info.clone());
                        }
                        routes.sort_by_key(|r| r.total_latency());
                        routes.truncate(MAX_ROUTES_PER_IP);
                    })
                    .or_insert_with(|| vec![route_info]);
            }

            // 不在同步列表中的 IP，移除该 peer 的路由
            ip_map.retain(|ip, routes| {
                if !synced_ips.contains(ip) {
                    routes.retain(|route| !Arc::ptr_eq(&route.peer_info, peer_info));
                }
                !routes.is_empty()
            });
            if let Some(state) = self.network_state_provider.get_network_state(&network_code) {
                state.update_remote_wireguard_ips(&remote_source, remote_wireguard_ips);
            }
        }

        log::debug!("Updated network routes from peer: {}", peer_info.get_addr());
    }

    fn cleanup_routes(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        network_codes: &std::collections::HashSet<String>,
    ) {
        let remote_source = peer_info.get_addr();
        for network_code in network_codes {
            if let Some(ip_map) = self
                .ip_to_routes
                .get(network_code)
                .map(|v| v.value().clone())
            {
                ip_map.retain(|_ip, routes| {
                    routes.retain(|route| !Arc::ptr_eq(&route.peer_info, peer_info));
                    !routes.is_empty()
                });
            }
            if let Some(state) = self.network_state_provider.get_network_state(network_code) {
                state.remove_remote_wireguard_source(&remote_source);
            }
        }
        log::debug!("Cleaned up routes for peer: {}", peer_info.get_addr());
    }

    async fn pull_client_info_from_peer(&self, peer_info: &Arc<PeerServerInfo>) -> Result<()> {
        let network_codes = self.network_state_provider.get_network_codes();

        if network_codes.is_empty() {
            return Ok(());
        }

        let request_msg = ServerMessage {
            payload: Some(Payload::ClientInfoReq(ServerClientInfoRequest {
                network_codes,
            })),
        };
        let data = request_msg.encode_bytes_mut().freeze();

        peer_info.send(data).await?;
        Ok(())
    }

    pub async fn handle_client_info_request(
        &self,
        network_codes: Vec<String>,
    ) -> ServerClientInfoResponse {
        let mut networks = Vec::new();

        for network_code in network_codes {
            let clients =
                if let Some(state) = self.network_state_provider.get_network_state(&network_code) {
                    let clients: Vec<ClientLatencyInfo> = state
                        .sender_map()
                        .iter()
                        .map(|entry| {
                            let ip = *entry.key();
                            let latency_ms = state
                                .get_device_entry_by_ip(ip)
                                .and_then(|device| device.latency_ms)
                                .unwrap_or(DEFAULT_CLIENT_LATENCY_MS);

                            ClientLatencyInfo {
                                ip: u32::from(ip),
                                latency_ms,
                                is_wireguard: state.is_wireguard_endpoint(ip),
                            }
                        })
                        .collect();
                    clients
                } else {
                    Vec::new()
                };
            networks.push(NetworkInfo {
                network_code,
                clients,
            });
        }

        ServerClientInfoResponse { networks }
    }

    async fn ping_peer(&self, peer_info: &Arc<PeerServerInfo>) -> Result<()> {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        let ping_msg = ServerMessage {
            payload: Some(Payload::PingReq(ServerPingRequest { timestamp })),
        };
        let data = ping_msg.encode_bytes_mut().freeze();

        peer_info.send(data).await?;
        Ok(())
    }

    /// 返回 (最优peer, 远程总延迟, 本地延迟)，None 表示不可达
    pub fn find_best_route(
        &self,
        network_code: &str,
        target_ip: Ipv4Addr,
    ) -> Option<(Arc<PeerServerInfo>, u32, Option<u32>)> {
        let local_latency = self
            .network_state_provider
            .get_network_state(network_code)
            .and_then(|state| state.get_device_entry_by_ip(target_ip))
            .and_then(|device| device.latency_ms);

        if let Some(ip_map) = self.ip_to_routes.get(network_code) {
            if let Some(routes) = ip_map.get(&target_ip) {
                let mut best_route: Option<(Arc<PeerServerInfo>, u32)> = None;

                for route in routes.value() {
                    if !route.peer_info.is_connected() {
                        continue;
                    }

                    let total_latency = route.total_latency();

                    match &best_route {
                        None => {
                            best_route = Some((route.peer_info.clone(), total_latency));
                        }
                        Some((_, current_best)) => {
                            if total_latency < *current_best {
                                best_route = Some((route.peer_info.clone(), total_latency));
                            }
                        }
                    }
                }

                if let Some((peer_info, total_latency)) = best_route {
                    return Some((peer_info, total_latency, local_latency));
                }
            }
        }

        None
    }

    pub fn get_peer_servers(&self) -> Vec<Arc<PeerServerInfo>> {
        self.peer_servers.read().clone()
    }

    pub async fn load_and_start_outbound_peers(self: Arc<Self>) -> Result<()> {
        let records = db::load_all_peer_servers().await?;

        for record in records {
            let peer_addr = record.server_addr.clone();
            log::info!(
                "Starting outbound connection to: {} (source: {:?})",
                peer_addr,
                record.source
            );

            let (handle, stop_tx) = self.clone().connect_to_peer(peer_addr.clone());
            self.outbound_tasks.insert(peer_addr, (handle, stop_tx));
        }

        Ok(())
    }

    pub async fn add_outbound_peer(self: Arc<Self>, server_addr: String) -> Result<()> {
        PeerEndpoint::parse(&server_addr)?;
        if self.outbound_tasks.contains_key(&server_addr) {
            bail!("服务器 '{}' 已存在", server_addr);
        }

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        let record = PeerServerRecord {
            server_addr: server_addr.clone(),
            source: PeerServerSource::Manual,
            created_at: now,
        };

        db::save_peer_server(&record).await?;

        let (handle, stop_tx) = self.clone().connect_to_peer(server_addr.clone());
        self.outbound_tasks
            .insert(server_addr.clone(), (handle, stop_tx));

        log::info!("Added outbound peer: {}", server_addr);
        Ok(())
    }

    pub async fn remove_outbound_peer(self: Arc<Self>, server_addr: &str) -> Result<()> {
        if let Some((_, (handle, stop_tx))) = self.outbound_tasks.remove(server_addr) {
            let _ = stop_tx.send(());
            let _ = tokio::time::timeout(Duration::from_secs(5), handle).await;
            log::info!("Stopped connection task for: {}", server_addr);
        }

        let mut to_remove = Vec::new();
        {
            let peers = self.peer_servers.read();
            for peer in peers.iter() {
                if peer.get_addr() == server_addr && peer.is_outbound() {
                    peer.set_disconnected();
                    to_remove.push(peer.clone());
                }
            }
        }

        if !to_remove.is_empty() {
            let mut peers = self.peer_servers.write();
            for peer in &to_remove {
                peers.retain(|p| !Arc::ptr_eq(p, peer));
            }
        }

        db::delete_peer_server(server_addr).await?;

        log::info!("Removed outbound peer: {}", server_addr);
        Ok(())
    }

    pub async fn add_peer_server(self: Arc<Self>, server_addr: String) -> Result<()> {
        self.add_outbound_peer(server_addr).await
    }

    pub async fn remove_peer_server(self: Arc<Self>, server_addr: &str) -> Result<()> {
        self.remove_outbound_peer(server_addr).await
    }

    pub fn get_remote_devices(&self, network_code: &str) -> Vec<(Ipv4Addr, String, u32)> {
        let mut result = Vec::new();

        if let Some(network_routes) = self.ip_to_routes.get(network_code) {
            for entry in network_routes.iter() {
                let ip = *entry.key();
                let routes = entry.value();
                for route in routes {
                    let server_addr = route.peer_info.get_addr();
                    let total_latency = route.total_latency();
                    result.push((ip, server_addr, total_latency));
                }
            }
        }

        result
    }

    /// 通过 QUIC datagram 转发到指定 peer
    pub async fn forward_to_peer(
        &self,
        peer_info: &Arc<PeerServerInfo>,
        network_code: String,
        data: Bytes,
        origin: RelayOrigin,
    ) -> bool {
        let forward_msg = ServerMessage {
            payload: Some(Payload::ForwardData(ServerForwardData {
                network_code,
                data: data.to_vec(),
                source_is_wireguard: origin == RelayOrigin::WireGuard,
            })),
        };

        let msg_bytes = forward_msg.encode_bytes_mut().freeze();

        if let Err(e) = peer_info.send_datagram(msg_bytes) {
            log::warn!("Failed to send datagram to peer: {:?}", e);
            false
        } else {
            log::debug!("Forwarded data to peer server: {}", peer_info.get_addr());
            true
        }
    }

    /// 找到最优路径并转发，返回 true 表示已转发到远端
    pub async fn forward_with_best_route(
        &self,
        network_code: &str,
        target_ip: Ipv4Addr,
        data: Bytes,
        origin: RelayOrigin,
    ) -> bool {
        let local_has_client =
            if let Some(state) = self.network_state_provider.get_network_state(network_code) {
                state.sender_map().contains_key(&target_ip)
            } else {
                false
            };

        if let Some((peer_info, remote_latency, local_latency)) =
            self.find_best_route(network_code, target_ip)
        {
            let should_forward = if let Some(local_lat) = local_latency {
                if remote_latency < local_lat {
                    log::debug!(
                        "Remote path is faster: local={} ms, remote={} ms, forwarding to {}",
                        local_lat,
                        remote_latency,
                        peer_info.get_addr()
                    );
                    true
                } else {
                    log::debug!(
                        "Local path is faster: local={} ms, remote={} ms, using local",
                        local_lat,
                        remote_latency
                    );
                    false
                }
            } else if local_has_client {
                if remote_latency < DEFAULT_CLIENT_LATENCY_MS {
                    log::debug!(
                        "Remote path may be faster: local={}(default) ms, remote={} ms, forwarding to {}",
                        DEFAULT_CLIENT_LATENCY_MS,
                        remote_latency,
                        peer_info.get_addr()
                    );
                    true
                } else {
                    false
                }
            } else {
                true
            };

            if should_forward {
                log::debug!(
                    "Forwarding to peer server {} for {}, total latency: {} ms",
                    peer_info.get_addr(),
                    target_ip,
                    remote_latency
                );
                return self
                    .forward_to_peer(&peer_info, network_code.to_string(), data, origin)
                    .await;
            }
        }

        false
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PeerEndpoint {
    host: String,
    port: u16,
    server_name: String,
}

impl PeerEndpoint {
    fn parse(raw: &str) -> Result<Self> {
        let value = raw.trim();
        anyhow::ensure!(!value.is_empty(), "Peer 服务端地址不能为空");
        anyhow::ensure!(
            value == raw && !value.chars().any(char::is_whitespace),
            "Peer 服务端地址不能包含空白字符"
        );
        anyhow::ensure!(
            !value.contains("://")
                && !value.contains('/')
                && !value.contains('?')
                && !value.contains('#')
                && !value.contains('@'),
            "Peer 服务端地址必须使用 host:port"
        );

        if let Ok(address) = value.parse::<SocketAddr>() {
            validate_peer_ip(address.ip())?;
            anyhow::ensure!(address.port() != 0, "Peer 服务端端口不能为 0");
            return Ok(Self {
                host: address.ip().to_string(),
                port: address.port(),
                server_name: address.ip().to_string(),
            });
        }

        anyhow::ensure!(
            !value.starts_with('['),
            "Peer IPv6 地址必须使用 [IPv6]:port"
        );
        let (host, port) = value
            .rsplit_once(':')
            .ok_or_else(|| anyhow::anyhow!("Peer 服务端地址必须包含端口"))?;
        anyhow::ensure!(
            !host.is_empty() && !host.contains(':'),
            "Peer IPv6 地址必须使用 [IPv6]:port"
        );
        validate_peer_hostname(host)?;
        let port: u16 = port
            .parse()
            .map_err(|_| anyhow::anyhow!("Peer 服务端端口无效"))?;
        anyhow::ensure!(port != 0, "Peer 服务端端口不能为 0");
        Ok(Self {
            host: host.to_ascii_lowercase(),
            port,
            server_name: host.to_ascii_lowercase(),
        })
    }

    async fn resolve(&self) -> Result<Vec<SocketAddr>> {
        if let Ok(ip) = self.host.parse::<IpAddr>() {
            return Ok(vec![SocketAddr::new(ip, self.port)]);
        }
        let addresses = tokio::time::timeout(
            PEER_RESOLVE_TIMEOUT,
            tokio::net::lookup_host((self.host.as_str(), self.port)),
        )
        .await
        .map_err(|_| anyhow::anyhow!("解析 Peer 域名 {} 超时", self.host))??;
        let mut result = Vec::new();
        for address in addresses {
            if validate_peer_ip(address.ip()).is_ok() && !result.contains(&address) {
                result.push(address);
            }
        }
        anyhow::ensure!(
            !result.is_empty(),
            "Peer 域名 {} 没有可用的 A/AAAA 记录",
            self.host
        );
        Ok(result)
    }
}

fn validate_peer_hostname(host: &str) -> Result<()> {
    anyhow::ensure!(host.len() <= 253, "Peer 服务端域名过长");
    for label in host.split('.') {
        anyhow::ensure!(
            !label.is_empty() && label.len() <= 63,
            "Peer 服务端域名无效"
        );
        let bytes = label.as_bytes();
        anyhow::ensure!(
            bytes.first().is_some_and(u8::is_ascii_alphanumeric)
                && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
                && bytes
                    .iter()
                    .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-'),
            "Peer 服务端域名无效"
        );
    }
    Ok(())
}

fn validate_peer_ip(ip: IpAddr) -> Result<()> {
    match ip {
        IpAddr::V4(address) => anyhow::ensure!(
            !address.is_unspecified() && !address.is_multicast(),
            "Peer 服务端不能使用未指定或组播地址"
        ),
        IpAddr::V6(address) => anyhow::ensure!(
            !address.is_unspecified() && !address.is_multicast(),
            "Peer 服务端不能使用未指定或组播地址"
        ),
    }
    Ok(())
}

fn unix_timestamp_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn new_request_id() -> String {
    format!("{:032x}", rand::random::<u128>())
}

impl Clone for PeerServerManager {
    fn clone(&self) -> Self {
        Self {
            token_hash: self.token_hash.clone(),
            server_id: self.server_id.clone(),
            lease_authority: self.lease_authority.clone(),
            network_config_digest: self.network_config_digest.clone(),
            capabilities: self.capabilities,
            network_state_provider: self.network_state_provider.clone(),
            peer_servers: self.peer_servers.clone(),
            ip_to_routes: self.ip_to_routes.clone(),
            last_resolved_addresses: self.last_resolved_addresses.clone(),
            pending_lease_acquires: self.pending_lease_acquires.clone(),
            pending_lease_releases: self.pending_lease_releases.clone(),
            broadcast_seen: self.broadcast_seen.clone(),
            cluster_ready: self.cluster_ready.clone(),
            cluster_conflicts: self.cluster_conflicts.clone(),
            cluster_revision: self.cluster_revision.clone(),
            outbound_tasks: self.outbound_tasks.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_endpoint_accepts_domains_and_ip_literals() {
        let domain = PeerEndpoint::parse("relay.example.com:29873").unwrap();
        assert_eq!(domain.host, "relay.example.com");
        assert_eq!(domain.port, 29873);
        assert_eq!(domain.server_name, "relay.example.com");

        let ipv4 = PeerEndpoint::parse("127.0.0.1:29873").unwrap();
        assert_eq!(ipv4.host, "127.0.0.1");

        let ipv6 = PeerEndpoint::parse("[2001:db8::1]:29873").unwrap();
        assert_eq!(ipv6.host, "2001:db8::1");
    }

    #[test]
    fn peer_endpoint_rejects_unsafe_or_ambiguous_values() {
        for value in [
            "",
            " relay.example.com:29873",
            "https://relay.example.com:29873",
            "relay.example.com",
            "relay.example.com:0",
            "bad_host.example.com:29873",
            "0.0.0.0:29873",
            "[::]:29873",
            "2001:db8::1:29873",
        ] {
            assert!(PeerEndpoint::parse(value).is_err(), "accepted {value:?}");
        }
    }

    #[test]
    fn forward_origin_field_is_backward_compatible_and_preserves_wireguard_source() {
        let legacy = ServerForwardData {
            network_code: "network-a".to_string(),
            data: vec![1, 2, 3],
            source_is_wireguard: false,
        }
        .encode_to_vec();
        let legacy = ServerForwardData::decode(legacy.as_slice()).unwrap();
        assert!(!legacy.source_is_wireguard);

        let wireguard = ServerForwardData {
            network_code: "network-a".to_string(),
            data: vec![4, 5, 6],
            source_is_wireguard: true,
        }
        .encode_to_vec();
        let wireguard = ServerForwardData::decode(wireguard.as_slice()).unwrap();
        assert!(wireguard.source_is_wireguard);
    }

    #[test]
    fn broadcast_forward_payload_preserves_origin_and_hop_limit() {
        let broadcast = ServerBroadcastData {
            network_code: "network-a".to_string(),
            data: vec![0x45; 20],
            source_ip: Ipv4Addr::new(10, 26, 0, 2).into(),
            broadcast_id: "server-a:1".to_string(),
            origin_server_id: "server-a".to_string(),
            hops_remaining: BROADCAST_HOP_LIMIT,
            source_is_wireguard: true,
        };
        let decoded = ServerBroadcastData::decode(broadcast.encode_to_vec().as_slice()).unwrap();
        assert_eq!(decoded.source_ip, u32::from(Ipv4Addr::new(10, 26, 0, 2)));
        assert_eq!(decoded.hops_remaining, 8);
        assert!(decoded.source_is_wireguard);
    }
}

// 自签名证书，跳过验证
#[derive(Debug)]
struct SkipServerVerification;

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ED25519,
        ]
    }
}

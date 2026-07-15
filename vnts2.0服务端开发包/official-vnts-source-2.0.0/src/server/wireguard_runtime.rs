use crate::protocol::ip_packet_protocol::NetPacket;
use crate::server::control_server::db::{self, WireGuardRuntimePeer};
use crate::server::control_server::service::ControlService;
use crate::server::control_server::wireguard_identity::WireGuardIdentity;
use crate::server::network_state_provider::{
    LocalDeliveryResult, NetworkState, WireGuardBridgePacket,
};
use crate::server::wireguard_bridge::{
    RelayOrigin, build_wireguard_relay, validate_inner_ipv4, validate_vnt_relay,
};
use crate::server::wireguard_p2p::{
    AgentControlParse, AgentControlRequest, build_agent_response, parse_agent_control,
    resolve_agent_request, revoke_lease,
};
use anyhow::Context;
use boringtun::noise::errors::WireGuardError;
use boringtun::noise::handshake::parse_handshake_anon;
use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Packet, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use rand::Rng;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tokio_util::sync::CancellationToken;

const HANDSHAKE_RATE_LIMIT: u64 = 100;
const NON_LIMITING_RATE: u64 = u64::MAX;
const TIMER_INTERVAL: Duration = Duration::from_millis(250);
const RATE_LIMIT_RESET_INTERVAL: Duration = Duration::from_secs(1);
const UDP_BUFFER_SIZE: usize = 65_535;
const MAX_RECEIVER_INDEX: u32 = 0x00ff_ffff;
const INDEX_ALLOCATION_ATTEMPTS: usize = 128;
const BRIDGE_QUEUE_CAPACITY: usize = 1024;
const P2P_REQUEST_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct PeerKey {
    network_code: String,
    peer_id: String,
}

struct ActivePeer {
    public_key: [u8; 32],
    reserved_ip: Ipv4Addr,
    receiver_index: u32,
    endpoint: Option<SocketAddr>,
    tunnel: Tunn,
    network_state: Arc<NetworkState>,
    stats: ActivePeerStats,
    last_p2p_request: Option<Instant>,
    p2p_leases: HashMap<Ipv4Addr, u64>,
}

#[derive(Default)]
struct ActivePeerStats {
    rx_bytes: u64,
    tx_bytes: u64,
    rejected_packets: u64,
    dropped_packets: u64,
}

enum RuntimeCommand {
    Revoke {
        key: PeerKey,
        acknowledged: oneshot::Sender<()>,
    },
}

#[derive(Clone)]
pub(crate) struct WireGuardRuntimeHandle {
    commands: mpsc::Sender<RuntimeCommand>,
    local_addr: SocketAddr,
    public_key: [u8; 32],
}

impl WireGuardRuntimeHandle {
    pub(crate) fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub(crate) fn public_key(&self) -> [u8; 32] {
        self.public_key
    }

    pub(crate) async fn revoke_peer(
        &self,
        network_code: &str,
        peer_id: &str,
    ) -> anyhow::Result<()> {
        let (acknowledged, receiver) = oneshot::channel();
        self.commands
            .send(RuntimeCommand::Revoke {
                key: PeerKey {
                    network_code: network_code.to_string(),
                    peer_id: peer_id.to_string(),
                },
                acknowledged,
            })
            .await
            .context("WireGuard runtime is not available")?;
        receiver
            .await
            .context("WireGuard runtime stopped before revocation was acknowledged")
    }
}

pub(crate) async fn start(
    bind_addr: SocketAddr,
    identity: &WireGuardIdentity,
    max_active_peers: usize,
    control_service: ControlService,
    shutdown: CancellationToken,
) -> anyhow::Result<(WireGuardRuntimeHandle, JoinHandle<anyhow::Result<()>>)> {
    let socket = UdpSocket::bind(bind_addr)
        .await
        .with_context(|| format!("Failed to bind WireGuard UDP listener on {bind_addr}"))?;
    let local_addr = socket
        .local_addr()
        .context("Failed to read WireGuard UDP listener address")?;
    let static_private = identity.static_secret();
    let static_public = PublicKey::from(&static_private);
    let (commands, command_rx) = mpsc::channel(64);
    let (bridge_sender, bridge_rx) = mpsc::channel(BRIDGE_QUEUE_CAPACITY);
    let runtime = WireGuardRuntime {
        socket,
        static_private,
        static_public,
        global_rate_limiter: RateLimiter::new(&static_public, HANDSHAKE_RATE_LIMIT),
        peer_verifier: Arc::new(RateLimiter::new(&static_public, NON_LIMITING_RATE)),
        max_active_peers,
        control_service,
        peers: HashMap::new(),
        peers_by_public_key: HashMap::new(),
        peers_by_receiver_index: HashMap::new(),
        peers_by_reserved_ip: HashMap::new(),
        command_rx,
        bridge_sender,
        bridge_rx,
        shutdown,
        receive_buffer: vec![0; UDP_BUFFER_SIZE],
        output_buffer: vec![0; UDP_BUFFER_SIZE],
    };
    let task = tokio::spawn(runtime.run());
    Ok((
        WireGuardRuntimeHandle {
            commands,
            local_addr,
            public_key: static_public.to_bytes(),
        },
        task,
    ))
}

struct WireGuardRuntime {
    socket: UdpSocket,
    static_private: StaticSecret,
    static_public: PublicKey,
    global_rate_limiter: RateLimiter,
    peer_verifier: Arc<RateLimiter>,
    max_active_peers: usize,
    control_service: ControlService,
    peers: HashMap<PeerKey, ActivePeer>,
    peers_by_public_key: HashMap<[u8; 32], PeerKey>,
    peers_by_receiver_index: HashMap<u32, PeerKey>,
    peers_by_reserved_ip: HashMap<(String, Ipv4Addr), PeerKey>,
    command_rx: mpsc::Receiver<RuntimeCommand>,
    bridge_sender: mpsc::Sender<WireGuardBridgePacket>,
    bridge_rx: mpsc::Receiver<WireGuardBridgePacket>,
    shutdown: CancellationToken,
    receive_buffer: Vec<u8>,
    output_buffer: Vec<u8>,
}

enum PacketDestination {
    PublicKey([u8; 32]),
    ReceiverIndex(u32),
}

impl WireGuardRuntime {
    async fn run(mut self) -> anyhow::Result<()> {
        let mut timer = tokio::time::interval(TIMER_INTERVAL);
        timer.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let mut rate_limit_reset = tokio::time::interval(RATE_LIMIT_RESET_INTERVAL);
        rate_limit_reset.set_missed_tick_behavior(MissedTickBehavior::Skip);

        let result = loop {
            tokio::select! {
                biased;
                _ = self.shutdown.cancelled() => break Ok(()),
                Some(command) = self.command_rx.recv() => self.handle_command(command),
                Some(packet) = self.bridge_rx.recv() => self.handle_bridge_packet(packet).await,
                receive = self.socket.recv_from(&mut self.receive_buffer) => {
                    let (length, source) = match receive.context("WireGuard UDP receive failed") {
                        Ok(receive) => receive,
                        Err(error) => break Err(error),
                    };
                    let packet = self.receive_buffer[..length].to_vec();
                    self.handle_datagram(&packet, source).await;
                }
                _ = timer.tick() => self.update_timers().await,
                _ = rate_limit_reset.tick() => self.global_rate_limiter.reset_count(),
            }
        };
        self.remove_all_peers();
        result
    }

    fn handle_command(&mut self, command: RuntimeCommand) {
        match command {
            RuntimeCommand::Revoke { key, acknowledged } => {
                self.remove_peer(&key);
                let _ = acknowledged.send(());
            }
        }
    }

    async fn handle_datagram(&mut self, packet: &[u8], source: SocketAddr) {
        let destination = match self.global_rate_limiter.verify_packet(
            Some(source.ip()),
            packet,
            &mut self.output_buffer,
        ) {
            Ok(Packet::HandshakeInit(init)) => {
                let Ok(handshake) =
                    parse_handshake_anon(&self.static_private, &self.static_public, &init)
                else {
                    return;
                };
                PacketDestination::PublicKey(handshake.peer_static_public)
            }
            Ok(Packet::HandshakeResponse(response)) => {
                PacketDestination::ReceiverIndex(response.receiver_idx >> 8)
            }
            Ok(Packet::PacketCookieReply(reply)) => {
                PacketDestination::ReceiverIndex(reply.receiver_idx >> 8)
            }
            Ok(Packet::PacketData(data)) => {
                PacketDestination::ReceiverIndex(data.receiver_idx >> 8)
            }
            Err(TunnResult::WriteToNetwork(cookie)) => {
                let cookie = cookie.to_vec();
                let _ = self.socket.send_to(&cookie, source).await;
                return;
            }
            Err(_) => return,
        };

        let key = match destination {
            PacketDestination::PublicKey(public_key) => {
                match self.peer_for_handshake(public_key).await {
                    Some(key) => key,
                    None => return,
                }
            }
            PacketDestination::ReceiverIndex(receiver_index) => {
                match self.peers_by_receiver_index.get(&receiver_index) {
                    Some(key) => key.clone(),
                    None => return,
                }
            }
        };
        self.process_peer_packet(&key, packet, source).await;
    }

    async fn peer_for_handshake(&mut self, public_key: [u8; 32]) -> Option<PeerKey> {
        if let Some(key) = self.peers_by_public_key.get(&public_key) {
            return Some(key.clone());
        }
        if self.peers.len() >= self.max_active_peers {
            return None;
        }

        let record = match db::load_wireguard_runtime_peer_by_public_key(&public_key).await {
            Ok(Some(record)) => record,
            Ok(None) | Err(_) => return None,
        };
        self.activate_peer(record).await
    }

    async fn activate_peer(&mut self, record: WireGuardRuntimePeer) -> Option<PeerKey> {
        if self.peers.len() >= self.max_active_peers {
            return None;
        }
        let network_state = self
            .control_service
            .wireguard_network_state(&record.network_code)
            .await
            .ok()?;
        let used: HashSet<_> = self.peers_by_receiver_index.keys().copied().collect();
        let receiver_index = allocate_receiver_index(&used)?;
        let key = PeerKey {
            network_code: record.network_code,
            peer_id: record.peer_id,
        };
        let tunnel = Tunn::new(
            self.static_private.clone(),
            PublicKey::from(record.public_key),
            None,
            None,
            receiver_index,
            Some(self.peer_verifier.clone()),
        );
        if !network_state.connect_wireguard_peer(
            &key.peer_id,
            record.ip,
            self.bridge_sender.clone(),
        ) {
            return None;
        }
        self.peers_by_public_key
            .insert(record.public_key, key.clone());
        self.peers_by_receiver_index
            .insert(receiver_index, key.clone());
        self.peers_by_reserved_ip
            .insert((key.network_code.clone(), record.ip), key.clone());
        self.peers.insert(
            key.clone(),
            ActivePeer {
                public_key: record.public_key,
                reserved_ip: record.ip,
                receiver_index,
                endpoint: None,
                tunnel,
                network_state,
                stats: ActivePeerStats::default(),
                last_p2p_request: None,
                p2p_leases: HashMap::new(),
            },
        );
        Some(key)
    }

    async fn process_peer_packet(&mut self, key: &PeerKey, packet: &[u8], source: SocketAddr) {
        let (outbound, relay, agent_control) = {
            let Some(peer) = self.peers.get_mut(key) else {
                return;
            };
            let mut outbound = Vec::new();
            let mut relay = None;
            let mut agent_control = None;
            let processed =
                match peer
                    .tunnel
                    .decapsulate(Some(source.ip()), packet, &mut self.output_buffer)
                {
                    TunnResult::Done => true,
                    TunnResult::Err(_) => {
                        peer.stats.rejected_packets += 1;
                        false
                    }
                    TunnResult::WriteToNetwork(response) => {
                        outbound.push(response.to_vec());
                        true
                    }
                    TunnResult::WriteToTunnelV4(inner, source_ip) => {
                        if !accepts_inner_source(peer.reserved_ip, IpAddr::V4(source_ip)) {
                            peer.stats.rejected_packets += 1;
                        } else {
                            match parse_agent_control(
                                inner,
                                peer.reserved_ip,
                                peer.network_state.gateway(),
                            ) {
                                AgentControlParse::Request(request) => {
                                    let now = Instant::now();
                                    if peer.last_p2p_request.is_some_and(|last| {
                                        now.saturating_duration_since(last) < P2P_REQUEST_INTERVAL
                                    }) {
                                        peer.stats.dropped_packets += 1;
                                    } else {
                                        peer.last_p2p_request = Some(now);
                                        agent_control = Some(request);
                                    }
                                }
                                AgentControlParse::Invalid => peer.stats.rejected_packets += 1,
                                AgentControlParse::NotControl => {
                                    match validate_inner_ipv4(
                                        inner,
                                        peer.reserved_ip,
                                        *peer.network_state.network(),
                                        peer.network_state.gateway(),
                                    ) {
                                        Ok(route) => {
                                            peer.stats.rx_bytes += inner.len() as u64;
                                            relay = Some((
                                                route.destination,
                                                build_wireguard_relay(inner, route),
                                            ));
                                        }
                                        Err(_) => peer.stats.rejected_packets += 1,
                                    }
                                }
                            }
                        }
                        true
                    }
                    TunnResult::WriteToTunnelV6(_, source_ip) => {
                        let _ = accepts_inner_source(peer.reserved_ip, IpAddr::V6(source_ip));
                        peer.stats.rejected_packets += 1;
                        true
                    }
                };
            if !processed {
                return;
            }

            peer.endpoint = Some(source);
            while let TunnResult::WriteToNetwork(packet) =
                peer.tunnel.decapsulate(None, &[], &mut self.output_buffer)
            {
                outbound.push(packet.to_vec());
            }
            (outbound, relay, agent_control)
        };

        for packet in outbound {
            if self.socket.send_to(&packet, source).await.is_err()
                && let Some(peer) = self.peers.get_mut(key)
            {
                peer.stats.dropped_packets += 1;
            }
        }
        if let Some((destination, data)) = relay {
            let result = self
                .control_service
                .route_wireguard_relay(&key.network_code, destination, data, RelayOrigin::WireGuard)
                .await;
            if result != LocalDeliveryResult::Delivered
                && let Some(peer) = self.peers.get_mut(key)
            {
                peer.stats.dropped_packets += 1;
            }
        }
        if let Some(request) = agent_control {
            self.handle_agent_control(key, request, source).await;
        }
    }

    async fn handle_agent_control(
        &mut self,
        key: &PeerKey,
        request: AgentControlRequest,
        source: SocketAddr,
    ) {
        let Some(peer) = self.peers.get(key) else {
            return;
        };
        let resolution = resolve_agent_request(
            &peer.network_state,
            peer.reserved_ip,
            peer.public_key,
            source,
            request,
        );
        let Some(inner) = build_agent_response(
            peer.network_state.gateway(),
            peer.reserved_ip,
            request.source_port,
            &resolution.response,
        ) else {
            return;
        };
        if let Some(granted) = resolution.granted
            && let Some(peer) = self.peers.get_mut(key)
        {
            peer.p2p_leases.insert(granted.target_ip, granted.lease_id);
        }
        let payload_length = inner.len();
        let (network_packet, endpoint) = {
            let Some(peer) = self.peers.get_mut(key) else {
                return;
            };
            let Some(endpoint) = peer.endpoint else {
                peer.stats.dropped_packets += 1;
                return;
            };
            let network_packet = match peer.tunnel.encapsulate(&inner, &mut self.output_buffer) {
                TunnResult::WriteToNetwork(packet) => packet.to_vec(),
                TunnResult::Err(_) => {
                    peer.stats.rejected_packets += 1;
                    return;
                }
                _ => {
                    peer.stats.dropped_packets += 1;
                    return;
                }
            };
            (network_packet, endpoint)
        };
        let sent = self.socket.send_to(&network_packet, endpoint).await.is_ok();
        if let Some(peer) = self.peers.get_mut(key) {
            if sent {
                peer.stats.tx_bytes += payload_length as u64;
            } else {
                peer.stats.dropped_packets += 1;
            }
        }
    }

    async fn handle_bridge_packet(&mut self, bridge: WireGuardBridgePacket) {
        let Ok(packet) = NetPacket::new(bridge.data) else {
            return;
        };
        let destination = Ipv4Addr::from(packet.dest_id());
        let Some(key) = self
            .peers_by_reserved_ip
            .get(&(bridge.network_code, destination))
            .cloned()
        else {
            return;
        };

        let (network_packet, endpoint, payload_length) = {
            let Some(peer) = self.peers.get_mut(&key) else {
                return;
            };
            if validate_vnt_relay(
                &packet,
                Ipv4Addr::from(packet.src_id()),
                *peer.network_state.network(),
                peer.network_state.gateway(),
            )
            .is_err()
            {
                peer.stats.rejected_packets += 1;
                return;
            }
            let Some(endpoint) = peer.endpoint else {
                peer.stats.dropped_packets += 1;
                return;
            };
            let payload_length = packet.payload().len();
            let network_packet = match peer
                .tunnel
                .encapsulate(packet.payload(), &mut self.output_buffer)
            {
                TunnResult::WriteToNetwork(network_packet) => network_packet.to_vec(),
                TunnResult::Err(_) => {
                    peer.stats.rejected_packets += 1;
                    return;
                }
                _ => {
                    peer.stats.dropped_packets += 1;
                    return;
                }
            };
            (network_packet, endpoint, payload_length)
        };

        let sent = self.socket.send_to(&network_packet, endpoint).await.is_ok();
        if let Some(peer) = self.peers.get_mut(&key) {
            if sent {
                peer.stats.tx_bytes += payload_length as u64;
            } else {
                peer.stats.dropped_packets += 1;
            }
        }
    }

    async fn update_timers(&mut self) {
        let keys: Vec<_> = self.peers.keys().cloned().collect();
        let mut expired = Vec::new();
        let mut outbound = Vec::new();
        for key in keys {
            let Some(peer) = self.peers.get_mut(&key) else {
                continue;
            };
            match peer.tunnel.update_timers(&mut self.output_buffer) {
                TunnResult::Done => {}
                TunnResult::Err(WireGuardError::ConnectionExpired) => expired.push(key),
                TunnResult::Err(_) => {}
                TunnResult::WriteToNetwork(packet) => {
                    if let Some(endpoint) = peer.endpoint {
                        outbound.push((packet.to_vec(), endpoint));
                    }
                }
                TunnResult::WriteToTunnelV4(_, _) | TunnResult::WriteToTunnelV6(_, _) => {}
            }
        }
        for key in expired {
            self.remove_peer(&key);
        }
        for (packet, endpoint) in outbound {
            let _ = self.socket.send_to(&packet, endpoint).await;
        }
    }

    fn remove_peer(&mut self, key: &PeerKey) {
        if let Some(peer) = self.peers.remove(key) {
            for (target_ip, lease_id) in peer.p2p_leases {
                revoke_lease(&peer.network_state, target_ip, lease_id);
            }
            self.peers_by_public_key.remove(&peer.public_key);
            self.peers_by_receiver_index.remove(&peer.receiver_index);
            self.peers_by_reserved_ip
                .remove(&(key.network_code.clone(), peer.reserved_ip));
            peer.network_state
                .disconnect_wireguard_peer(&key.peer_id, peer.reserved_ip);
            log::debug!(
                "WireGuard peer session removed: network_code={}, peer_id={}, rx_bytes={}, tx_bytes={}, rejected_packets={}, dropped_packets={}",
                key.network_code,
                key.peer_id,
                peer.stats.rx_bytes,
                peer.stats.tx_bytes,
                peer.stats.rejected_packets,
                peer.stats.dropped_packets,
            );
        }
    }

    fn remove_all_peers(&mut self) {
        let keys: Vec<_> = self.peers.keys().cloned().collect();
        for key in keys {
            self.remove_peer(&key);
        }
    }
}

fn allocate_receiver_index(used: &HashSet<u32>) -> Option<u32> {
    let mut rng = rand::rng();
    allocate_receiver_index_with(used, || rng.random_range(0..=MAX_RECEIVER_INDEX))
}

fn accepts_inner_source(reserved_ip: Ipv4Addr, source_ip: IpAddr) -> bool {
    source_ip == IpAddr::V4(reserved_ip)
}

fn allocate_receiver_index_with(
    used: &HashSet<u32>,
    mut generate: impl FnMut() -> u32,
) -> Option<u32> {
    (0..INDEX_ALLOCATION_ATTEMPTS)
        .map(|_| generate() & MAX_RECEIVER_INDEX)
        .find(|candidate| !used.contains(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn network_packet(result: TunnResult<'_>) -> Vec<u8> {
        match result {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            other => panic!("expected network packet, got {other:?}"),
        }
    }

    #[test]
    fn receiver_index_is_24_bit_and_retries_collisions() {
        let used = HashSet::from([7]);
        let mut candidates = [0xff00_0007, 0xab00_0008].into_iter();
        let selected = allocate_receiver_index_with(&used, || candidates.next().unwrap()).unwrap();
        assert_eq!(selected, 8);
        assert!(selected <= MAX_RECEIVER_INDEX);
    }

    #[test]
    fn receiver_index_allocation_stops_after_repeated_collisions() {
        let used = HashSet::from([7]);
        assert_eq!(allocate_receiver_index_with(&used, || 7), None);
    }

    #[test]
    fn only_reserved_ipv4_source_is_accepted() {
        let reserved = Ipv4Addr::new(10, 26, 0, 2);
        assert!(accepts_inner_source(reserved, IpAddr::V4(reserved)));
        assert!(!accepts_inner_source(
            reserved,
            IpAddr::V4(Ipv4Addr::new(10, 26, 0, 3))
        ));
        assert!(!accepts_inner_source(
            reserved,
            "2001:db8::1".parse().unwrap()
        ));
    }

    #[tokio::test]
    async fn cancellation_releases_udp_port() {
        let identity = WireGuardIdentity::for_test([0x55; 32]);
        let shutdown = CancellationToken::new();
        let control_service = ControlService::new(
            "10.26.0.0/24".parse().unwrap(),
            HashMap::new(),
            Duration::from_secs(60),
        )
        .await;
        let (handle, task) = start(
            "127.0.0.1:0".parse().unwrap(),
            &identity,
            1,
            control_service,
            shutdown.clone(),
        )
        .await
        .unwrap();
        let address = handle.local_addr();

        shutdown.cancel();
        task.await.unwrap().unwrap();

        let rebound = UdpSocket::bind(address).await.unwrap();
        assert_eq!(rebound.local_addr().unwrap(), address);
    }

    #[tokio::test]
    async fn endpoint_roams_only_after_authenticated_tunnel_processing() {
        let server_private = StaticSecret::from([0x31; 32]);
        let server_public = PublicKey::from(&server_private);
        let client_private = StaticSecret::from([0x32; 32]);
        let client_public = PublicKey::from(&client_private);
        let verifier = Arc::new(RateLimiter::new(&server_public, NON_LIMITING_RATE));
        let mut client = Tunn::new(client_private, server_public, None, None, 1, None);
        let mut server = Tunn::new(
            server_private.clone(),
            client_public,
            None,
            None,
            2,
            Some(verifier.clone()),
        );
        let mut client_buffer = vec![0; 2048];
        let mut server_buffer = vec![0; 2048];
        let original_endpoint: SocketAddr = "127.0.0.1:30001".parse().unwrap();
        let roamed_endpoint: SocketAddr = "127.0.0.1:30002".parse().unwrap();
        let forged_endpoint: SocketAddr = "127.0.0.1:30003".parse().unwrap();

        let initiation =
            network_packet(client.format_handshake_initiation(&mut client_buffer, false));
        let response = network_packet(server.decapsulate(
            Some(original_endpoint.ip()),
            &initiation,
            &mut server_buffer,
        ));
        let keepalive = network_packet(client.decapsulate(
            Some("127.0.0.1".parse().unwrap()),
            &response,
            &mut client_buffer,
        ));
        assert!(matches!(
            server.decapsulate(Some(original_endpoint.ip()), &keepalive, &mut server_buffer),
            TunnResult::Done
        ));

        let key = PeerKey {
            network_code: "network-a".to_string(),
            peer_id: "peer-a".to_string(),
        };
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_, command_rx) = mpsc::channel(1);
        let (bridge_sender, bridge_rx) = mpsc::channel(1);
        let control_service = ControlService::new(
            "10.26.0.0/24".parse().unwrap(),
            HashMap::new(),
            Duration::from_secs(60),
        )
        .await;
        let network_state = Arc::new(
            NetworkState::new_from_db(
                "network-a".to_string(),
                "10.26.0.0/24".parse().unwrap(),
                Duration::from_secs(60),
            )
            .await,
        );
        let mut runtime = WireGuardRuntime {
            socket,
            static_private: server_private,
            static_public: server_public,
            global_rate_limiter: RateLimiter::new(&server_public, HANDSHAKE_RATE_LIMIT),
            peer_verifier: verifier,
            max_active_peers: 1,
            control_service,
            peers: HashMap::from([(
                key.clone(),
                ActivePeer {
                    public_key: client_public.to_bytes(),
                    reserved_ip: Ipv4Addr::new(10, 26, 0, 2),
                    receiver_index: 2,
                    endpoint: Some(original_endpoint),
                    tunnel: server,
                    network_state,
                    stats: ActivePeerStats::default(),
                    last_p2p_request: None,
                    p2p_leases: HashMap::new(),
                },
            )]),
            peers_by_public_key: HashMap::from([(client_public.to_bytes(), key.clone())]),
            peers_by_receiver_index: HashMap::from([(2, key.clone())]),
            peers_by_reserved_ip: HashMap::from([(
                ("network-a".to_string(), Ipv4Addr::new(10, 26, 0, 2)),
                key.clone(),
            )]),
            command_rx,
            bridge_sender,
            bridge_rx,
            shutdown: CancellationToken::new(),
            receive_buffer: vec![0; UDP_BUFFER_SIZE],
            output_buffer: vec![0; UDP_BUFFER_SIZE],
        };

        let valid_packet = network_packet(client.encapsulate(
            &{
                let mut packet = vec![0; 20];
                packet[0] = 0x45;
                packet[2..4].copy_from_slice(&20_u16.to_be_bytes());
                packet[12..16].copy_from_slice(&[10, 26, 0, 2]);
                packet
            },
            &mut client_buffer,
        ));
        runtime
            .process_peer_packet(&key, &valid_packet, roamed_endpoint)
            .await;
        assert_eq!(
            runtime.peers.get(&key).unwrap().endpoint,
            Some(roamed_endpoint)
        );

        let mut forged_packet = network_packet(client.encapsulate(
            &{
                let mut packet = vec![0; 20];
                packet[0] = 0x45;
                packet[2..4].copy_from_slice(&20_u16.to_be_bytes());
                packet[12..16].copy_from_slice(&[10, 26, 0, 2]);
                packet
            },
            &mut client_buffer,
        ));
        *forged_packet.last_mut().unwrap() ^= 1;
        runtime
            .process_peer_packet(&key, &forged_packet, forged_endpoint)
            .await;
        assert_eq!(
            runtime.peers.get(&key).unwrap().endpoint,
            Some(roamed_endpoint)
        );
    }
}

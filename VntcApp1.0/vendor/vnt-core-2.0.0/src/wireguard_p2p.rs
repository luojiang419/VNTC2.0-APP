use crate::context::NetworkAddr;
use crate::enhanced_tunnel::inbound::EnhancedInbound;
use crate::protocol::control_message::WireGuardP2pRegistration;
use crate::protocol::control_message::proto::wire_guard_p2p_control::Payload;
use crate::protocol::control_message::proto::{WireGuardP2pControl, WireGuardP2pOffer};
use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use crate::protocol::transmission::TransmissionBytes;
use crate::utils::task_control::TaskGroup;
use boringtun::noise::handshake::parse_handshake_anon;
use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Packet as WireGuardPacket, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use rand::Rng;
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};

const UDP_BUFFER_SIZE: usize = 65_535;
const COMMAND_CAPACITY: usize = 256;
const MAX_ACTIVE_PEERS: usize = 64;
const MAX_RECEIVER_INDEX: u32 = 0x00ff_ffff;
const TIMER_INTERVAL: Duration = Duration::from_millis(250);
const AUTHENTICATED_ROUTE_TTL: Duration = Duration::from_secs(45);
const MAX_LEASE_AHEAD: Duration = Duration::from_secs(120);
const STUN_TIMEOUT: Duration = Duration::from_secs(2);

enum Command {
    Control(WireGuardP2pControl),
    Send {
        destination: Ipv4Addr,
        packet: Vec<u8>,
        result: oneshot::Sender<bool>,
    },
}

#[derive(Clone)]
pub(crate) struct WireGuardP2pHandle {
    commands: mpsc::Sender<Command>,
}

impl WireGuardP2pHandle {
    pub(crate) fn apply_control(&self, control: WireGuardP2pControl) {
        let _ = self.commands.try_send(Command::Control(control));
    }

    pub(crate) async fn send_ipv4(&self, destination: Ipv4Addr, packet: &[u8]) -> bool {
        let (result, receiver) = oneshot::channel();
        if self
            .commands
            .send(Command::Send {
                destination,
                packet: packet.to_vec(),
                result,
            })
            .await
            .is_err()
        {
            return false;
        }
        receiver.await.unwrap_or(false)
    }
}

pub(crate) struct PreparedWireGuardP2p {
    registration: WireGuardP2pRegistration,
    socket: UdpSocket,
    private_key: [u8; 32],
    commands: mpsc::Receiver<Command>,
    handle: WireGuardP2pHandle,
}

impl PreparedWireGuardP2p {
    pub(crate) fn registration(&self) -> WireGuardP2pRegistration {
        self.registration
    }

    pub(crate) fn handle(&self) -> WireGuardP2pHandle {
        self.handle.clone()
    }

    pub(crate) fn start(
        self,
        task_group: &TaskGroup,
        network_addr: NetworkAddr,
        inbound: EnhancedInbound,
    ) {
        let public_key = PublicKey::from(&StaticSecret::from(self.private_key));
        let runtime = Runtime {
            socket: self.socket,
            private_key: self.private_key,
            public_key,
            rate_limiter: RateLimiter::new(&public_key, 100),
            commands: self.commands,
            peers: HashMap::new(),
            receiver_indices: HashMap::new(),
            network_addr,
            inbound,
            receive_buffer: vec![0; UDP_BUFFER_SIZE],
            output_buffer: vec![0; UDP_BUFFER_SIZE],
        };
        task_group.spawn(runtime.run());
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub(crate) async fn prepare(
    stun_servers: &[String],
) -> anyhow::Result<Option<PreparedWireGuardP2p>> {
    let default_servers;
    let stun_servers = if stun_servers.is_empty() {
        default_servers = crate::tunnel_core::p2p::transport::nat_test::default_udp_stun();
        &default_servers
    } else {
        stun_servers
    };
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    let Some(public_addr) = discover_public_addr(&socket, stun_servers).await else {
        log::warn!("WireGuard P2P disabled because UDP STUN discovery failed");
        return Ok(None);
    };
    let mut private_key = [0u8; 32];
    rand::rng().fill(&mut private_key);
    let public_key = PublicKey::from(&StaticSecret::from(private_key)).to_bytes();
    let (commands, command_rx) = mpsc::channel(COMMAND_CAPACITY);
    Ok(Some(PreparedWireGuardP2p {
        registration: WireGuardP2pRegistration {
            public_key,
            port: public_addr.port(),
        },
        socket,
        private_key,
        commands: command_rx,
        handle: WireGuardP2pHandle { commands },
    }))
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub(crate) async fn prepare(
    _stun_servers: &[String],
) -> anyhow::Result<Option<PreparedWireGuardP2p>> {
    // 移动端 VPN socket 必须由原生 VpnService/NetworkExtension 显式保护；
    // 在原生并行任务接入该能力前保持服务器中继，避免产生递归路由。
    Ok(None)
}

async fn discover_public_addr(socket: &UdpSocket, servers: &[String]) -> Option<SocketAddr> {
    let request = rust_p2p_core::stun::send_stun_request();
    for server in servers.iter().take(3) {
        let Ok(mut addresses) = tokio::net::lookup_host(server).await else {
            continue;
        };
        let Some(address) = addresses.next() else {
            continue;
        };
        if socket.send_to(&request, address).await.is_err() {
            continue;
        }
        let mut response = [0u8; 1024];
        let Ok(Ok((length, source))) =
            tokio::time::timeout(STUN_TIMEOUT, socket.recv_from(&mut response)).await
        else {
            continue;
        };
        if source.ip() == address.ip()
            && rust_p2p_core::stun::is_stun_response(&response[..length])
            && let Some(public_addr) = rust_p2p_core::stun::recv_stun_response(&response[..length])
            && public_addr.port() != 0
        {
            return Some(public_addr);
        }
    }
    None
}

struct ActivePeer {
    public_key: [u8; 32],
    endpoint: SocketAddr,
    receiver_index: u32,
    lease_id: u64,
    expires_at_unix_ms: u64,
    last_authenticated: Option<Instant>,
    tunnel: Tunn,
}

struct Runtime {
    socket: UdpSocket,
    private_key: [u8; 32],
    public_key: PublicKey,
    rate_limiter: RateLimiter,
    commands: mpsc::Receiver<Command>,
    peers: HashMap<Ipv4Addr, ActivePeer>,
    receiver_indices: HashMap<u32, Ipv4Addr>,
    network_addr: NetworkAddr,
    inbound: EnhancedInbound,
    receive_buffer: Vec<u8>,
    output_buffer: Vec<u8>,
}

enum Destination {
    PublicKey([u8; 32]),
    ReceiverIndex(u32),
}

impl Runtime {
    async fn run(mut self) {
        let mut timer = tokio::time::interval(TIMER_INTERVAL);
        loop {
            tokio::select! {
                Some(command) = self.commands.recv() => self.handle_command(command).await,
                received = self.socket.recv_from(&mut self.receive_buffer) => {
                    match received {
                        Ok((length, source)) => {
                            let packet = self.receive_buffer[..length].to_vec();
                            self.handle_datagram(&packet, source).await;
                        }
                        Err(error) => {
                            log::warn!("WireGuard P2P receive failed: {error}");
                            break;
                        }
                    }
                }
                _ = timer.tick() => self.update_timers().await,
                else => break,
            }
        }
    }

    async fn handle_command(&mut self, command: Command) {
        match command {
            Command::Control(control) => self.apply_control(control).await,
            Command::Send {
                destination,
                packet,
                result,
            } => {
                let sent = self.send_inner(destination, &packet).await;
                let _ = result.send(sent);
            }
        }
    }

    async fn apply_control(&mut self, control: WireGuardP2pControl) {
        match control.payload {
            Some(Payload::Offer(offer)) => self.apply_offer(offer).await,
            Some(Payload::Revoke(revoke)) => {
                if let Some(ip) = self
                    .peers
                    .iter()
                    .find_map(|(ip, peer)| (peer.lease_id == revoke.lease_id).then_some(*ip))
                {
                    self.remove_peer(ip);
                }
            }
            None => {}
        }
    }

    async fn apply_offer(&mut self, offer: WireGuardP2pOffer) {
        let Ok(public_key) = <[u8; 32]>::try_from(offer.peer_public_key) else {
            return;
        };
        let Ok(endpoint) = offer.peer_endpoint.parse::<SocketAddr>() else {
            return;
        };
        if !endpoint.is_ipv4() {
            return;
        }
        let peer_ip = Ipv4Addr::from(offer.peer_ip);
        let now_ms = unix_ms();
        if offer.lease_id == 0
            || offer.expires_at_unix_ms <= now_ms
            || offer.expires_at_unix_ms.saturating_sub(now_ms) > MAX_LEASE_AHEAD.as_millis() as u64
            || crate::wireguard_bridge::validate_inner_ipv4(
                &synthetic_ipv4(peer_ip, self.network_addr.ip),
                peer_ip,
                Some(self.network_addr.ip),
                self.network_addr,
            )
            .is_none()
        {
            return;
        }
        if self.peers.len() >= MAX_ACTIVE_PEERS && !self.peers.contains_key(&peer_ip) {
            return;
        }
        if let Some(peer) = self.peers.get_mut(&peer_ip)
            && peer.public_key == public_key
        {
            peer.endpoint = endpoint;
            peer.lease_id = offer.lease_id;
            peer.expires_at_unix_ms = offer.expires_at_unix_ms;
            return;
        }
        self.remove_peer(peer_ip);
        let receiver_index = allocate_receiver_index(&self.receiver_indices);
        let mut tunnel = Tunn::new(
            StaticSecret::from(self.private_key),
            PublicKey::from(public_key),
            None,
            None,
            receiver_index,
            None,
        );
        let handshake = match tunnel.format_handshake_initiation(&mut self.output_buffer, false) {
            TunnResult::WriteToNetwork(packet) => Some(packet.to_vec()),
            _ => None,
        };
        self.receiver_indices.insert(receiver_index, peer_ip);
        self.peers.insert(
            peer_ip,
            ActivePeer {
                public_key,
                endpoint,
                receiver_index,
                lease_id: offer.lease_id,
                expires_at_unix_ms: offer.expires_at_unix_ms,
                last_authenticated: None,
                tunnel,
            },
        );
        if let Some(handshake) = handshake {
            let _ = self.socket.send_to(&handshake, endpoint).await;
        }
    }

    async fn handle_datagram(&mut self, packet: &[u8], source: SocketAddr) {
        let destination = match self.rate_limiter.verify_packet(
            Some(source.ip()),
            packet,
            &mut self.output_buffer,
        ) {
            Ok(WireGuardPacket::HandshakeInit(init)) => {
                let private = StaticSecret::from(self.private_key);
                let Ok(handshake) = parse_handshake_anon(&private, &self.public_key, &init) else {
                    return;
                };
                Destination::PublicKey(handshake.peer_static_public)
            }
            Ok(WireGuardPacket::HandshakeResponse(response)) => {
                Destination::ReceiverIndex(response.receiver_idx >> 8)
            }
            Ok(WireGuardPacket::PacketCookieReply(reply)) => {
                Destination::ReceiverIndex(reply.receiver_idx >> 8)
            }
            Ok(WireGuardPacket::PacketData(data)) => {
                Destination::ReceiverIndex(data.receiver_idx >> 8)
            }
            Err(TunnResult::WriteToNetwork(cookie)) => {
                let _ = self.socket.send_to(cookie, source).await;
                return;
            }
            Err(_) => return,
        };
        let peer_ip = match destination {
            Destination::PublicKey(key) => self
                .peers
                .iter()
                .find_map(|(ip, peer)| (peer.public_key == key).then_some(*ip)),
            Destination::ReceiverIndex(index) => self.receiver_indices.get(&index).copied(),
        };
        let Some(peer_ip) = peer_ip else {
            return;
        };

        let mut outbound = Vec::new();
        let mut inbound = None;
        {
            let Some(peer) = self.peers.get_mut(&peer_ip) else {
                return;
            };
            let processed =
                match peer
                    .tunnel
                    .decapsulate(Some(source.ip()), packet, &mut self.output_buffer)
                {
                    TunnResult::Done => true,
                    TunnResult::WriteToNetwork(response) => {
                        outbound.push(response.to_vec());
                        true
                    }
                    TunnResult::WriteToTunnelV4(inner, source_ip) => {
                        if source_ip == peer_ip
                            && crate::wireguard_bridge::validate_inner_ipv4(
                                inner,
                                peer_ip,
                                Some(self.network_addr.ip),
                                self.network_addr,
                            )
                            .is_some()
                        {
                            inbound = Some(inner.to_vec());
                        }
                        true
                    }
                    _ => false,
                };
            if !processed {
                return;
            }
            peer.endpoint = source;
            peer.last_authenticated = Some(Instant::now());
            while let TunnResult::WriteToNetwork(response) =
                peer.tunnel.decapsulate(None, &[], &mut self.output_buffer)
            {
                outbound.push(response.to_vec());
            }
        }
        for response in outbound {
            let _ = self.socket.send_to(&response, source).await;
        }
        if let Some(inner) = inbound {
            self.deliver_inner(peer_ip, &inner).await;
        }
    }

    async fn deliver_inner(&self, peer_ip: Ipv4Addr, inner: &[u8]) {
        let mut packet = NetPacket::new(TransmissionBytes::zeroed(HEAD_LENGTH + inner.len()))
            .expect("complete direct packet buffer");
        packet.set_msg_type(MsgType::WireGuardRelay);
        packet.set_ttl(1);
        packet.set_src_id(peer_ip.into());
        packet.set_dest_id(self.network_addr.ip.into());
        if packet.set_payload(inner).is_ok() {
            let _ = self
                .inbound
                .inbound(&self.network_addr, MsgType::Turn, peer_ip, packet)
                .await;
        }
    }

    async fn send_inner(&mut self, destination: Ipv4Addr, packet: &[u8]) -> bool {
        if crate::wireguard_bridge::validate_inner_ipv4(
            packet,
            self.network_addr.ip,
            Some(destination),
            self.network_addr,
        )
        .is_none()
        {
            return false;
        }
        let Some(peer) = self.peers.get_mut(&destination) else {
            return false;
        };
        if peer.expires_at_unix_ms <= unix_ms()
            || peer
                .last_authenticated
                .is_none_or(|last| last.elapsed() > AUTHENTICATED_ROUTE_TTL)
        {
            return false;
        }
        let network_packet = match peer.tunnel.encapsulate(packet, &mut self.output_buffer) {
            TunnResult::WriteToNetwork(network_packet) => network_packet.to_vec(),
            _ => return false,
        };
        self.socket
            .send_to(&network_packet, peer.endpoint)
            .await
            .is_ok()
    }

    async fn update_timers(&mut self) {
        let now_ms = unix_ms();
        let expired: Vec<_> = self
            .peers
            .iter()
            .filter_map(|(ip, peer)| (peer.expires_at_unix_ms <= now_ms).then_some(*ip))
            .collect();
        for ip in expired {
            self.remove_peer(ip);
        }
        let mut outbound = Vec::new();
        for peer in self.peers.values_mut() {
            if let TunnResult::WriteToNetwork(packet) =
                peer.tunnel.update_timers(&mut self.output_buffer)
            {
                outbound.push((packet.to_vec(), peer.endpoint));
            }
        }
        for (packet, endpoint) in outbound {
            let _ = self.socket.send_to(&packet, endpoint).await;
        }
    }

    fn remove_peer(&mut self, ip: Ipv4Addr) {
        if let Some(peer) = self.peers.remove(&ip) {
            self.receiver_indices.remove(&peer.receiver_index);
        }
    }
}

fn allocate_receiver_index(used: &HashMap<u32, Ipv4Addr>) -> u32 {
    loop {
        let index = rand::rng().random_range(0..=MAX_RECEIVER_INDEX);
        if !used.contains_key(&index) {
            return index;
        }
    }
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn synthetic_ipv4(source: Ipv4Addr, destination: Ipv4Addr) -> [u8; 20] {
    let mut packet = [0u8; 20];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&20u16.to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&source.octets());
    packet[16..20].copy_from_slice(&destination.octets());
    packet
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receiver_indices_are_24_bit_and_unique() {
        let used = HashMap::from([(7, Ipv4Addr::new(10, 26, 0, 2))]);
        let index = allocate_receiver_index(&used);
        assert!(index <= MAX_RECEIVER_INDEX);
        assert_ne!(index, 7);
    }

    #[test]
    fn synthetic_header_obeys_bridge_source_and_destination_rules() {
        let network_addr = NetworkAddr {
            gateway: Ipv4Addr::new(10, 26, 0, 1),
            broadcast: Ipv4Addr::new(10, 26, 0, 255),
            ip: Ipv4Addr::new(10, 26, 0, 3),
            prefix_len: 24,
        };
        assert!(
            crate::wireguard_bridge::validate_inner_ipv4(
                &synthetic_ipv4(Ipv4Addr::new(10, 26, 0, 2), network_addr.ip),
                Ipv4Addr::new(10, 26, 0, 2),
                Some(network_addr.ip),
                network_addr,
            )
            .is_some()
        );
    }
}

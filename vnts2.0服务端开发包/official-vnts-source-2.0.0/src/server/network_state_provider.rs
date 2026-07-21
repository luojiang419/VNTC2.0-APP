use crate::protocol::control_message::{
    CLIENT_CAP_WIREGUARD_BROADCAST_RELAY, CLIENT_CAP_WIREGUARD_SUBNET_RELAY, RegRequestMsg,
    RegistrationMode,
};
use crate::protocol::ip_packet_protocol::{MsgType, NetPacket};
use crate::server::control_server::db;
use crate::server::control_server::db::{
    DeviceRecord, WireGuardPeerDeleteResult, WireGuardPeerRecord,
};
use crate::server::wireguard_bridge::{
    RelayOrigin, RelayValidationError, build_wireguard_broadcast_relay,
    validate_broadcast_inner_ipv4,
};
use anyhow::bail;
use bytes::Bytes;
use dashmap::DashMap;
use ipnet::Ipv4Net;
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::net::{Ipv4Addr, SocketAddr};
use std::ops::Deref;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;
use tokio::sync::mpsc::{Sender, error::TrySendError};
use tokio::time::{Duration, Instant};

#[derive(Debug)]
struct DirectionTraffic {
    total_bytes: u64,
}

impl DirectionTraffic {
    fn new() -> Self {
        Self { total_bytes: 0 }
    }

    fn add(&mut self, bytes: u64) {
        self.total_bytes += bytes;
    }

    fn set_bytes(&mut self, bytes: u64) {
        self.total_bytes = bytes;
    }
}

#[derive(Debug)]
pub struct TrafficStats {
    tx: Mutex<DirectionTraffic>,
    rx: Mutex<DirectionTraffic>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct DashboardTrafficSnapshot {
    pub(crate) tx_bytes_total: u64,
    pub(crate) rx_bytes_total: u64,
    pub(crate) wireguard_drops_total: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct DashboardEndpointSnapshot {
    pub(crate) vnt_online: u64,
    pub(crate) wireguard_online: u64,
}

impl TrafficStats {
    pub fn new() -> Self {
        Self {
            tx: Mutex::new(DirectionTraffic::new()),
            rx: Mutex::new(DirectionTraffic::new()),
        }
    }

    pub fn add_tx(&self, bytes: u64) {
        self.tx.lock().add(bytes);
    }

    pub fn add_rx(&self, bytes: u64) {
        self.rx.lock().add(bytes);
    }

    pub fn get_tx(&self) -> u64 {
        self.tx.lock().total_bytes
    }

    pub fn get_rx(&self) -> u64 {
        self.rx.lock().total_bytes
    }

    pub fn set_tx(&self, bytes: u64) {
        self.tx.lock().set_bytes(bytes);
    }

    pub fn set_rx(&self, bytes: u64) {
        self.rx.lock().set_bytes(bytes);
    }
}

impl Clone for TrafficStats {
    fn clone(&self) -> Self {
        let new = Self::new();
        new.set_tx(self.get_tx());
        new.set_rx(self.get_rx());
        new
    }
}

#[derive(Debug, Clone)]
pub struct DeviceEntry {
    pub device_id: String,
    pub ip: Option<Ipv4Addr>,
    pub random_id: u64,
    pub device_name: String,
    pub device_version: String,
    pub is_connected: bool,
    pub last_connect_time: SystemTime,
    pub disconnect_time: Option<SystemTime>,
    pub data_version: u64,
    pub key_sign: Option<String>,
    pub latency_ms: Option<u32>,
    pub traffic_stats: Arc<TrafficStats>,
}

pub fn system_time_to_i64(st: SystemTime) -> i64 {
    st.duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::new(0, 0))
        .as_secs() as i64
}

pub fn i64_to_system_time(ts: i64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(ts as u64)
}

impl DeviceEntry {
    fn from_record(record: DeviceRecord) -> Self {
        let ip = record.ip.as_ref().and_then(|s| s.parse().ok());
        let traffic_stats = Arc::new(TrafficStats::new());
        traffic_stats.set_tx(record.tx_bytes as u64);
        traffic_stats.set_rx(record.rx_bytes as u64);

        DeviceEntry {
            device_id: record.device_id,
            ip,
            random_id: 0,
            device_name: record.device_name,
            device_version: record.device_version,
            is_connected: false,
            last_connect_time: i64_to_system_time(record.last_connect_time),
            disconnect_time: Some(SystemTime::now()),
            data_version: 0,
            key_sign: None,
            latency_ms: None,
            traffic_stats,
        }
    }

    pub fn to_record(&self, network_code: &str) -> DeviceRecord {
        DeviceRecord {
            device_id: self.device_id.clone(),
            network_code: network_code.to_string(),
            ip: self.ip.map(|ip| ip.to_string()),
            device_name: self.device_name.clone(),
            device_version: self.device_version.clone(),
            last_connect_time: system_time_to_i64(self.last_connect_time),
            tx_bytes: self.traffic_stats.get_tx() as i64,
            rx_bytes: self.traffic_stats.get_rx() as i64,
        }
    }
}

pub struct NetworkState {
    time: Mutex<Instant>,
    network_code: String,
    gateway: Ipv4Addr,
    net: Ipv4Net,
    lease_duration: Duration,
    sender_map: DashMap<Ipv4Addr, NetworkSender>,
    online_endpoints: DashMap<Ipv4Addr, OnlineEndpoint>,
    wireguard_backpressure_drops: DashMap<Ipv4Addr, AtomicU64>,
    lease_state: Mutex<NetworkStateInner>,
    wireguard_ip_update_lock: tokio::sync::Mutex<()>,
    traffic_stats_map: DashMap<Ipv4Addr, Arc<TrafficStats>>,
    dashboard_traffic: TrafficStats,
    dashboard_wireguard_drops: AtomicU64,
}

struct NetworkStateInner {
    data_version: u64,
    last_wireguard_change_version: u64,
    device_map: HashMap<String, DeviceEntry>,
    device_ip_map: HashMap<Ipv4Addr, String>,
    wireguard_peer_ip_map: HashMap<Ipv4Addr, String>,
    remote_wireguard_sources: HashMap<String, HashSet<Ipv4Addr>>,
}

#[derive(Clone, Debug)]
enum OnlineEndpoint {
    Vnt {
        random_id: u64,
        allow_wireguard: bool,
        client_capabilities: u64,
        confirmed: bool,
        wireguard_p2p: Option<WireGuardP2pEndpoint>,
    },
    WireGuard {
        peer_id: String,
        connected_at: i64,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WireGuardP2pEndpoint {
    pub(crate) public_key: [u8; 32],
    pub(crate) endpoint: SocketAddr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LocalDeliveryResult {
    Delivered,
    NotFound,
    Rejected,
    Full,
    Closed,
}

#[derive(Clone, Debug)]
pub(crate) struct WireGuardBridgePacket {
    pub(crate) network_code: String,
    pub(crate) data: Bytes,
}

#[derive(Clone)]
pub(crate) enum NetworkSender {
    Vnt(Sender<Bytes>),
    WireGuard {
        network_code: String,
        sender: Sender<WireGuardBridgePacket>,
    },
}

pub(crate) enum NetworkSendError {
    Full,
    Closed,
}

impl NetworkSender {
    pub(crate) fn try_send(&self, data: Bytes) -> Result<(), NetworkSendError> {
        match self {
            Self::Vnt(sender) => sender.try_send(data).map_err(|error| match error {
                TrySendError::Full(_) => NetworkSendError::Full,
                TrySendError::Closed(_) => NetworkSendError::Closed,
            }),
            Self::WireGuard {
                network_code,
                sender,
            } => sender
                .try_send(WireGuardBridgePacket {
                    network_code: network_code.clone(),
                    data,
                })
                .map_err(|error| match error {
                    TrySendError::Full(_) => NetworkSendError::Full,
                    TrySendError::Closed(_) => NetworkSendError::Closed,
                }),
        }
    }
}

impl NetworkState {
    pub fn network(&self) -> &Ipv4Net {
        &self.net
    }
    pub fn gateway(&self) -> Ipv4Addr {
        self.gateway
    }
    pub fn net_prefix_len(&self) -> u8 {
        self.net.prefix_len()
    }

    pub(crate) fn sender_map(&self) -> &DashMap<Ipv4Addr, NetworkSender> {
        &self.sender_map
    }

    pub(crate) fn is_wireguard_endpoint(&self, ip: Ipv4Addr) -> bool {
        self.online_endpoints
            .get(&ip)
            .is_some_and(|endpoint| matches!(endpoint.value(), OnlineEndpoint::WireGuard { .. }))
    }

    pub(crate) fn update_remote_wireguard_ips(&self, source: &str, ips: HashSet<Ipv4Addr>) -> bool {
        let mut guard = self.lease_state.lock();
        if guard.remote_wireguard_sources.get(source) == Some(&ips)
            || (ips.is_empty() && !guard.remote_wireguard_sources.contains_key(source))
        {
            return false;
        }
        if ips.is_empty() {
            guard.remote_wireguard_sources.remove(source);
        } else {
            guard
                .remote_wireguard_sources
                .insert(source.to_string(), ips);
        }
        guard.data_version = guard.data_version.saturating_add(1);
        guard.last_wireguard_change_version = guard.data_version;
        drop(guard);
        self.update_time();
        true
    }

    pub(crate) fn remove_remote_wireguard_source(&self, source: &str) -> bool {
        let mut guard = self.lease_state.lock();
        if guard.remote_wireguard_sources.remove(source).is_none() {
            return false;
        }
        guard.data_version = guard.data_version.saturating_add(1);
        guard.last_wireguard_change_version = guard.data_version;
        drop(guard);
        self.update_time();
        true
    }

    pub(crate) fn wireguard_p2p_endpoint(&self, ip: Ipv4Addr) -> Option<WireGuardP2pEndpoint> {
        self.online_endpoints.get(&ip).and_then(|endpoint| {
            if let OnlineEndpoint::Vnt {
                allow_wireguard: true,
                confirmed: true,
                wireguard_p2p: Some(p2p),
                ..
            } = endpoint.value()
            {
                Some(p2p.clone())
            } else {
                None
            }
        })
    }

    pub(crate) fn connect_wireguard_peer(
        &self,
        peer_id: &str,
        ip: Ipv4Addr,
        sender: Sender<WireGuardBridgePacket>,
    ) -> bool {
        let mut guard = self.lease_state.lock();
        if guard
            .wireguard_peer_ip_map
            .get(&ip)
            .is_none_or(|owner| owner != peer_id)
            || self.sender_map.contains_key(&ip)
            || self.online_endpoints.contains_key(&ip)
        {
            return false;
        }

        self.sender_map.insert(
            ip,
            NetworkSender::WireGuard {
                network_code: self.network_code.clone(),
                sender,
            },
        );
        self.online_endpoints.insert(
            ip,
            OnlineEndpoint::WireGuard {
                peer_id: peer_id.to_string(),
                connected_at: system_time_to_i64(SystemTime::now()),
            },
        );
        self.wireguard_backpressure_drops
            .insert(ip, AtomicU64::new(0));
        guard.data_version += 1;
        guard.last_wireguard_change_version = guard.data_version;
        self.update_time();
        true
    }

    pub(crate) fn disconnect_wireguard_peer(&self, peer_id: &str, ip: Ipv4Addr) -> bool {
        let mut guard = self.lease_state.lock();
        let matches_peer = self.online_endpoints.get(&ip).is_some_and(|endpoint| {
            matches!(
                endpoint.value(),
                OnlineEndpoint::WireGuard {
                    peer_id: active_peer_id,
                    ..
                } if active_peer_id == peer_id
            )
        });
        if !matches_peer {
            return false;
        }

        self.sender_map.remove(&ip);
        self.online_endpoints.remove(&ip);
        let backpressure_drops = self
            .wireguard_backpressure_drops
            .remove(&ip)
            .map(|(_, drops)| drops.load(Ordering::Relaxed))
            .unwrap_or_default();
        guard.data_version += 1;
        guard.last_wireguard_change_version = guard.data_version;
        self.update_time();
        if backpressure_drops > 0 {
            log::debug!(
                "WireGuard bridge backpressure drops: network_code={}, peer_id={}, ip={}, drops={}",
                self.network_code,
                peer_id,
                ip,
                backpressure_drops,
            );
        }
        true
    }

    pub(crate) fn try_deliver(
        &self,
        destination: Ipv4Addr,
        data: Bytes,
        origin: RelayOrigin,
    ) -> LocalDeliveryResult {
        let Some(endpoint) = self.online_endpoints.get(&destination) else {
            return LocalDeliveryResult::NotFound;
        };
        let Ok(packet) = NetPacket::new(data.clone()) else {
            return LocalDeliveryResult::Rejected;
        };
        let Ok(message_type) = packet.msg_type() else {
            return LocalDeliveryResult::Rejected;
        };

        let allowed = match (message_type, origin, endpoint.value()) {
            (MsgType::WireGuardRelay, RelayOrigin::Vnt, OnlineEndpoint::WireGuard { .. }) => true,
            (MsgType::WireGuardRelay, RelayOrigin::WireGuard, OnlineEndpoint::WireGuard { .. }) => {
                true
            }
            (
                MsgType::WireGuardRelay,
                RelayOrigin::WireGuard,
                OnlineEndpoint::Vnt {
                    allow_wireguard: true,
                    confirmed: true,
                    ..
                },
            ) => true,
            (MsgType::WireGuardRelay, _, _) => false,
            (
                MsgType::WireGuardSubnetRelay,
                RelayOrigin::WireGuard,
                OnlineEndpoint::Vnt {
                    allow_wireguard: true,
                    client_capabilities,
                    confirmed: true,
                    ..
                },
            ) => {
                *client_capabilities & CLIENT_CAP_WIREGUARD_SUBNET_RELAY
                    == CLIENT_CAP_WIREGUARD_SUBNET_RELAY
            }
            (MsgType::WireGuardSubnetRelay, RelayOrigin::Vnt, OnlineEndpoint::WireGuard { .. }) => {
                true
            }
            (MsgType::WireGuardSubnetRelay, _, _) => false,
            (
                MsgType::WireGuardBroadcastRelay,
                RelayOrigin::Vnt,
                OnlineEndpoint::WireGuard { .. },
            ) => true,
            (
                MsgType::WireGuardBroadcastRelay,
                RelayOrigin::WireGuard,
                OnlineEndpoint::WireGuard { .. },
            ) => true,
            (
                MsgType::WireGuardBroadcastRelay,
                RelayOrigin::WireGuard,
                OnlineEndpoint::Vnt {
                    allow_wireguard: true,
                    client_capabilities,
                    confirmed: true,
                    ..
                },
            ) => {
                *client_capabilities & CLIENT_CAP_WIREGUARD_BROADCAST_RELAY
                    == CLIENT_CAP_WIREGUARD_BROADCAST_RELAY
            }
            (MsgType::WireGuardBroadcastRelay, _, _) => false,
            (_, _, OnlineEndpoint::Vnt { .. }) => true,
            (_, _, OnlineEndpoint::WireGuard { .. }) => false,
        };
        drop(endpoint);
        if !allowed {
            return LocalDeliveryResult::Rejected;
        }

        let Some(sender) = self.sender_map.get(&destination) else {
            return LocalDeliveryResult::NotFound;
        };
        match sender.try_send(data) {
            Ok(()) => LocalDeliveryResult::Delivered,
            Err(NetworkSendError::Full) => {
                if let Some(drops) = self.wireguard_backpressure_drops.get(&destination) {
                    drops.fetch_add(1, Ordering::Relaxed);
                }
                self.dashboard_wireguard_drops
                    .fetch_add(1, Ordering::Relaxed);
                LocalDeliveryResult::Full
            }
            Err(NetworkSendError::Closed) => {
                if let Some(drops) = self.wireguard_backpressure_drops.get(&destination) {
                    drops.fetch_add(1, Ordering::Relaxed);
                }
                self.dashboard_wireguard_drops
                    .fetch_add(1, Ordering::Relaxed);
                LocalDeliveryResult::Closed
            }
        }
    }

    pub(crate) fn relay_wireguard_broadcast(
        &self,
        source: Ipv4Addr,
        inner: &[u8],
        origin: RelayOrigin,
    ) -> Result<usize, RelayValidationError> {
        let route = validate_broadcast_inner_ipv4(inner, source, self.net, self.gateway)?;
        let targets: Vec<Ipv4Addr> = self
            .online_endpoints
            .iter()
            .filter_map(|endpoint| {
                let target = *endpoint.key();
                if target == source {
                    return None;
                }
                match (origin, endpoint.value()) {
                    (RelayOrigin::Vnt, OnlineEndpoint::WireGuard { .. }) => Some(target),
                    (RelayOrigin::WireGuard, OnlineEndpoint::WireGuard { .. }) => Some(target),
                    (
                        RelayOrigin::WireGuard,
                        OnlineEndpoint::Vnt {
                            allow_wireguard: true,
                            client_capabilities,
                            confirmed: true,
                            ..
                        },
                    ) if *client_capabilities & CLIENT_CAP_WIREGUARD_BROADCAST_RELAY
                        == CLIENT_CAP_WIREGUARD_BROADCAST_RELAY =>
                    {
                        Some(target)
                    }
                    _ => None,
                }
            })
            .collect();

        let mut delivered = 0;
        for target in targets {
            let data = build_wireguard_broadcast_relay(inner, route, target);
            if self.try_deliver(target, data.clone(), origin) == LocalDeliveryResult::Delivered {
                self.record_rx_traffic(target, data.len());
                delivered += 1;
            }
        }
        Ok(delivered)
    }

    pub fn record_tx_traffic(&self, ip: Ipv4Addr, bytes: usize) {
        self.dashboard_traffic.add_tx(bytes as u64);
        if let Some(stats) = self.traffic_stats_map.get(&ip) {
            stats.add_tx(bytes as u64);
        }
    }

    pub fn record_rx_traffic(&self, ip: Ipv4Addr, bytes: usize) {
        self.dashboard_traffic.add_rx(bytes as u64);
        if let Some(stats) = self.traffic_stats_map.get(&ip) {
            stats.add_rx(bytes as u64);
        }
    }

    pub(crate) fn dashboard_traffic_snapshot(&self) -> DashboardTrafficSnapshot {
        DashboardTrafficSnapshot {
            tx_bytes_total: self.dashboard_traffic.get_tx(),
            rx_bytes_total: self.dashboard_traffic.get_rx(),
            wireguard_drops_total: self.dashboard_wireguard_drops.load(Ordering::Relaxed),
        }
    }

    pub(crate) fn dashboard_endpoint_snapshot(&self) -> DashboardEndpointSnapshot {
        self.online_endpoints.iter().fold(
            DashboardEndpointSnapshot::default(),
            |mut snapshot, endpoint| {
                match endpoint.value() {
                    OnlineEndpoint::Vnt { .. } => snapshot.vnt_online += 1,
                    OnlineEndpoint::WireGuard { .. } => snapshot.wireguard_online += 1,
                }
                snapshot
            },
        )
    }

    /// 设备离线，返回需要持久化的记录。random_id 用于判断是否为当前会话。
    pub fn offline_ip(
        &self,
        device_id: &String,
        ip: Ipv4Addr,
        random_id: u64,
    ) -> Option<DeviceRecord> {
        let mut guard = self.lease_state.lock();
        let (success, record) = guard.offline_ip(&self.network_code, device_id, ip, random_id);
        if success {
            log::info!(
                "offline_ip network_code={},device_id={device_id},ip={ip}",
                self.network_code,
            );
            self.sender_map.remove(&ip);
            self.online_endpoints.remove(&ip);
            self.traffic_stats_map.remove(&ip);

            record
        } else {
            log::info!(
                "reconnect network_code={},device_id={device_id},ip={ip}",
                self.network_code,
            );
            None
        }
    }

    pub fn count(&self) -> (u32, u32) {
        let wireguard_count = self
            .online_endpoints
            .iter()
            .filter(|endpoint| matches!(endpoint.value(), OnlineEndpoint::WireGuard { .. }))
            .count() as u32;
        let all_count = self.lease_state.lock().device_map.len() as u32 + wireguard_count;
        let online_count = self.sender_map.len() as u32;
        (all_count, online_count)
    }

    pub fn is_device_online(&self, device_id: &str) -> bool {
        let guard = self.lease_state.lock();
        guard
            .device_map
            .get(device_id)
            .map(|e| e.is_connected)
            .unwrap_or(false)
    }

    pub fn remove_device_from_memory(&self, device_id: &str) -> Option<Ipv4Addr> {
        let mut guard = self.lease_state.lock();
        if let Some(entry) = guard.device_map.remove(device_id) {
            if let Some(ip) = entry.ip {
                guard.device_ip_map.remove(&ip);
                self.sender_map.remove(&ip);
                self.online_endpoints.remove(&ip);
                self.traffic_stats_map.remove(&ip);
            }
            guard.data_version += 1;
            return entry.ip;
        }
        None
    }

    pub fn lease_duration(&self) -> Duration {
        self.lease_duration
    }

    /// 释放预注册但未确认的 IP，通过 random_id 避免误删其他会话
    pub fn release_pre_registered_ip(&self, device_id: &String, ip: Ipv4Addr, random_id: u64) {
        let should_remove = {
            let mut guard = self.lease_state.lock();
            if let Some(device_entry) = guard.device_map.get(device_id) {
                if device_entry.random_id == random_id && device_entry.ip == Some(ip) {
                    guard.device_map.remove(device_id);
                    guard.device_ip_map.remove(&ip);
                    guard.data_version += 1;
                    true
                } else {
                    false
                }
            } else {
                false
            }
        };

        if should_remove {
            self.sender_map.remove(&ip);
            self.online_endpoints.remove(&ip);
            self.traffic_stats_map.remove(&ip);
            log::info!(
                "Released pre-registered IP device_id={}, ip={}",
                device_id,
                ip
            );
        }
    }

    pub fn get_device_entry(&self, device_id: &str) -> Option<DeviceEntry> {
        let guard = self.lease_state.lock();
        guard.device_map.get(device_id).cloned()
    }

    pub fn get_device_entry_by_ip(&self, ip: Ipv4Addr) -> Option<DeviceEntry> {
        let guard = self.lease_state.lock();
        guard
            .device_ip_map
            .get(&ip)
            .and_then(|device_id| guard.device_map.get(device_id).cloned())
    }

    /// 同步保存到 DB 后再确认，防止 Drop 时状态不一致
    pub async fn confirm_registration(
        &self,
        network_code: &str,
        device_id: &str,
        ip: Ipv4Addr,
        random_id: u64,
    ) -> anyhow::Result<()> {
        if let Some(entry) = self.get_device_entry(device_id) {
            let record = entry.to_record(network_code);
            db::save_or_update_device(&record).await?;
        }
        if let Some(mut endpoint) = self.online_endpoints.get_mut(&ip)
            && let OnlineEndpoint::Vnt {
                random_id: active_random_id,
                confirmed,
                ..
            } = endpoint.value_mut()
            && *active_random_id == random_id
        {
            *confirmed = true;
        }
        Ok(())
    }

    /// 返回 (分配的IP, 旧IP, DeviceEntry克隆)
    pub fn allocate_ip_and_get_entry(
        &self,
        reg_req: RegRequestMsg,
        random_id: u64,
        sender: Sender<Bytes>,
        wireguard_p2p: Option<WireGuardP2pEndpoint>,
    ) -> anyhow::Result<(Ipv4Addr, Option<Ipv4Addr>, Option<DeviceEntry>)> {
        let allow_wireguard = reg_req.allow_wire_guard;
        let client_capabilities = reg_req.client_capabilities;
        let confirmed = reg_req.registration_mode == RegistrationMode::Normal;
        let mut guard = self.lease_state.lock();
        let (ip, old_ip) =
            guard.allocate_ip(&self.net, self.gateway, reg_req.clone(), random_id)?;

        if let Some(old_ip) = old_ip {
            self.sender_map.remove(&old_ip);
            self.online_endpoints.remove(&old_ip);
            self.traffic_stats_map.remove(&old_ip);
        }

        let entry = guard.device_map.get(&reg_req.device_id).cloned();
        self.sender_map.insert(ip, NetworkSender::Vnt(sender));
        self.online_endpoints.insert(
            ip,
            OnlineEndpoint::Vnt {
                random_id,
                allow_wireguard,
                client_capabilities,
                confirmed,
                wireguard_p2p,
            },
        );

        if let Some(entry) = &entry {
            self.traffic_stats_map
                .insert(ip, entry.traffic_stats.clone());
        }

        Ok((ip, old_ip, entry))
    }

    pub fn collect_expired_devices(&self) -> Vec<String> {
        let guard = self.lease_state.lock();
        guard.collect_expired_devices(self.lease_duration)
    }

    pub fn remove_devices(&self, device_ids: &[String]) {
        let mut guard = self.lease_state.lock();
        guard.remove_devices(device_ids);
    }

    pub fn data_version(&self) -> u64 {
        let guard = self.lease_state.lock();
        guard.data_version
    }

    pub fn get_all_device_simple_info(&self) -> Vec<(String, Option<Ipv4Addr>, bool, u64)> {
        let guard = self.lease_state.lock();
        guard
            .device_map
            .values()
            .map(|entry| {
                (
                    entry.device_id.clone(),
                    entry.ip,
                    entry.is_connected,
                    entry.data_version,
                )
            })
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        let guard = self.lease_state.lock();
        guard.device_map.is_empty()
            && guard.device_ip_map.is_empty()
            && guard.wireguard_peer_ip_map.is_empty()
    }

    pub(crate) async fn list_wireguard_peer_ips(&self) -> Vec<(String, Ipv4Addr)> {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let mut allocations: Vec<_> = self
            .lease_state
            .lock()
            .wireguard_peer_ip_map
            .iter()
            .map(|(ip, peer_id)| (peer_id.clone(), *ip))
            .collect();
        allocations.sort_unstable_by(|left, right| left.0.cmp(&right.0));
        allocations
    }

    pub(crate) async fn create_wireguard_peer(
        &self,
        record: &WireGuardPeerRecord,
    ) -> anyhow::Result<Option<Ipv4Addr>> {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        db::insert_wireguard_peer(record).await?;
        Ok(self.lease_state.lock().wireguard_peer_ip(&record.peer_id))
    }

    pub(crate) async fn create_wireguard_peer_with_automatic_ip(
        &self,
        record: &WireGuardPeerRecord,
    ) -> anyhow::Result<Ipv4Addr> {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let ip = {
            let mut guard = self.lease_state.lock();
            let ip = guard.find_available_ip(&self.net, self.gateway)?;
            guard.prepare_wireguard_peer_ip_reservation(&record.peer_id, ip)?;
            ip
        };
        if let Err(error) = db::insert_wireguard_peer_with_ip(record, ip).await {
            self.lease_state
                .lock()
                .rollback_wireguard_peer_ip_reservation(&record.peer_id, ip, None);
            return Err(error);
        }
        self.lease_state
            .lock()
            .commit_wireguard_peer_ip_reservation(&record.peer_id, ip, None);
        self.update_time();
        Ok(ip)
    }

    pub(crate) async fn create_wireguard_peer_with_ip(
        &self,
        record: &WireGuardPeerRecord,
        ip: Ipv4Addr,
    ) -> anyhow::Result<Ipv4Addr> {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let previous_ip = self
            .lease_state
            .lock()
            .prepare_wireguard_peer_ip_reservation(&record.peer_id, ip)?;
        if let Err(error) = db::insert_wireguard_peer_with_ip(record, ip).await {
            self.lease_state
                .lock()
                .rollback_wireguard_peer_ip_reservation(&record.peer_id, ip, previous_ip);
            return Err(error);
        }
        self.lease_state
            .lock()
            .commit_wireguard_peer_ip_reservation(&record.peer_id, ip, previous_ip);
        self.update_time();
        Ok(ip)
    }

    pub(crate) async fn list_wireguard_peers(
        &self,
    ) -> anyhow::Result<Vec<(WireGuardPeerRecord, Option<Ipv4Addr>)>> {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let peers = db::load_wireguard_peers(&self.network_code).await?;
        let guard = self.lease_state.lock();
        Ok(peers
            .into_iter()
            .map(|peer| {
                let ip = guard.wireguard_peer_ip(&peer.peer_id);
                (peer, ip)
            })
            .collect())
    }

    pub(crate) async fn set_wireguard_peer_enabled<F>(
        &self,
        peer_id: &str,
        enabled: bool,
        updated_at: i64,
        revoke: F,
    ) -> anyhow::Result<Option<(WireGuardPeerRecord, Option<Ipv4Addr>)>>
    where
        F: Future<Output = anyhow::Result<()>>,
    {
        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        if !db::set_wireguard_peer_enabled(&self.network_code, peer_id, enabled, updated_at).await?
        {
            return Ok(None);
        }
        let peer = db::load_wireguard_peer(&self.network_code, peer_id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("WireGuard peer 更新后不存在"))?;
        let ip = self.lease_state.lock().wireguard_peer_ip(peer_id);
        if !enabled {
            revoke.await?;
        }
        Ok(Some((peer, ip)))
    }

    pub(crate) async fn delete_wireguard_peer<R>(
        &self,
        peer_id: &str,
        revoke: R,
    ) -> anyhow::Result<WireGuardPeerDeleteResult>
    where
        R: Future<Output = anyhow::Result<()>>,
    {
        self.delete_wireguard_peer_with(
            peer_id,
            db::delete_wireguard_peer(&self.network_code, peer_id),
            revoke,
        )
        .await
    }

    async fn delete_wireguard_peer_with<F, R>(
        &self,
        peer_id: &str,
        persist: F,
        revoke: R,
    ) -> anyhow::Result<WireGuardPeerDeleteResult>
    where
        F: Future<Output = anyhow::Result<WireGuardPeerDeleteResult>>,
        R: Future<Output = anyhow::Result<()>>,
    {
        if peer_id.trim().is_empty() {
            bail!("WireGuard peer ID 不能为空")
        }

        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let mut result = persist.await?;
        let memory_removed = self.lease_state.lock().release_wireguard_peer_ip(peer_id);
        result.ip_released |= memory_removed;
        if memory_removed {
            self.update_time();
        }
        revoke.await?;
        Ok(result)
    }

    pub(crate) async fn reserve_wireguard_peer_ip<R>(
        &self,
        peer_id: &str,
        ip: Ipv4Addr,
        revoke: R,
    ) -> anyhow::Result<()>
    where
        R: Future<Output = anyhow::Result<()>>,
    {
        let changed = self
            .reserve_wireguard_peer_ip_with(
                peer_id,
                ip,
                db::reserve_wireguard_peer_ip(&self.network_code, peer_id, ip),
            )
            .await?;
        if changed {
            revoke.await?;
        }
        Ok(())
    }

    async fn reserve_wireguard_peer_ip_with<F>(
        &self,
        peer_id: &str,
        ip: Ipv4Addr,
        persist: F,
    ) -> anyhow::Result<bool>
    where
        F: Future<Output = anyhow::Result<()>>,
    {
        if peer_id.trim().is_empty() {
            bail!("WireGuard peer ID 不能为空")
        }
        if !self.net.contains(&ip) {
            bail!("IP网段错误，应使用{}网段中的IP", self.net)
        }
        if ip == self.gateway {
            bail!("此IP为网关IP，不允许使用")
        }

        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let previous_ip = {
            let mut guard = self.lease_state.lock();
            guard.prepare_wireguard_peer_ip_reservation(peer_id, ip)?
        };

        if let Err(error) = persist.await {
            self.lease_state
                .lock()
                .rollback_wireguard_peer_ip_reservation(peer_id, ip, previous_ip);
            return Err(error);
        }

        self.lease_state
            .lock()
            .commit_wireguard_peer_ip_reservation(peer_id, ip, previous_ip);
        self.update_time();
        Ok(previous_ip.is_some_and(|previous_ip| previous_ip != ip))
    }

    pub(crate) async fn release_wireguard_peer_ip<R>(
        &self,
        peer_id: &str,
        revoke: R,
    ) -> anyhow::Result<bool>
    where
        R: Future<Output = anyhow::Result<()>>,
    {
        let removed = self
            .release_wireguard_peer_ip_with(
                peer_id,
                db::release_wireguard_peer_ip(&self.network_code, peer_id),
            )
            .await?;
        if removed {
            revoke.await?;
        }
        Ok(removed)
    }

    async fn release_wireguard_peer_ip_with<F>(
        &self,
        peer_id: &str,
        persist: F,
    ) -> anyhow::Result<bool>
    where
        F: Future<Output = anyhow::Result<bool>>,
    {
        if peer_id.trim().is_empty() {
            bail!("WireGuard peer ID 不能为空")
        }

        let _update_guard = self.wireguard_ip_update_lock.lock().await;
        let database_removed = persist.await?;
        let memory_removed = self.lease_state.lock().release_wireguard_peer_ip(peer_id);
        if memory_removed {
            self.update_time();
        }
        Ok(database_removed || memory_removed)
    }

    pub fn last_active_time(&self) -> Instant {
        *self.time.lock()
    }

    pub fn network_code(&self) -> String {
        self.network_code.clone()
    }

    pub fn get_device_infos(&self) -> Vec<crate::server::control_server::service::DeviceInfoVO> {
        use time::OffsetDateTime;
        use time::macros::format_description;

        let guard = self.lease_state.lock();
        let mut list = Vec::new();
        let format = format_description!("[year]-[month]-[day] [hour]:[minute]:[second]");

        for (_device_id, entry) in &guard.device_map {
            let last_connect_time: OffsetDateTime = entry.last_connect_time.into();
            let disconnect_time: Option<OffsetDateTime> = entry.disconnect_time.map(|d| d.into());

            list.push(crate::server::control_server::service::DeviceInfoVO {
                device_id: entry.device_id.clone(),
                device_name: entry.device_name.clone(),
                device_version: entry.device_version.clone(),
                ip: entry.ip,
                status: if entry.is_connected {
                    "Online".to_string()
                } else {
                    "Offline".to_string()
                },
                last_connect_time: last_connect_time.format(&format).unwrap_or_default(),
                disconnect_time: disconnect_time.map(|d| d.format(&format).unwrap_or_default()),
                latency_ms: entry.latency_ms,
                server_addr: None,
                tx_bytes: entry.traffic_stats.get_tx(),
                rx_bytes: entry.traffic_stats.get_rx(),
            });
        }
        list
    }

    pub fn changed_client_simple_list(
        &self,
        exclude_ip: Ipv4Addr,
        data_version: u64,
        include_wireguard: bool,
    ) -> Option<crate::protocol::control_message::ClientSimpleInfoList> {
        use crate::protocol::control_message::{ClientSimpleInfo, NodeType};

        let guard = self.lease_state.lock();
        if data_version == guard.data_version {
            return None;
        }
        if data_version > guard.data_version
            || (include_wireguard && data_version < guard.last_wireguard_change_version)
        {
            let mut list: Vec<_> = guard
                .device_map
                .values()
                .filter(|v| v.ip.is_some() && v.ip != Some(exclude_ip))
                .map(|v| ClientSimpleInfo {
                    ip: v.ip.unwrap(),
                    online: v.is_connected,
                    node_type: NodeType::Vnt,
                })
                .collect();
            if include_wireguard {
                list.extend(self.online_endpoints.iter().filter_map(|endpoint| {
                    matches!(endpoint.value(), OnlineEndpoint::WireGuard { .. }).then_some(
                        ClientSimpleInfo {
                            ip: *endpoint.key(),
                            online: true,
                            node_type: NodeType::Wireguard,
                        },
                    )
                }));
                let local_ips: HashSet<_> = list.iter().map(|entry| entry.ip).collect();
                let remote_ips: HashSet<_> = guard
                    .remote_wireguard_sources
                    .values()
                    .flatten()
                    .copied()
                    .collect();
                list.extend(
                    remote_ips
                        .into_iter()
                        .filter(|ip| *ip != exclude_ip && !local_ips.contains(ip))
                        .map(|ip| ClientSimpleInfo {
                            ip,
                            online: true,
                            node_type: NodeType::Wireguard,
                        }),
                );
            }
            return Some(crate::protocol::control_message::ClientSimpleInfoList {
                data_version: guard.data_version,
                list,
                is_all: true,
                time: 0,
            });
        }
        let list = guard
            .device_map
            .values()
            .filter(|v| v.data_version > data_version && v.ip.is_some() && v.ip != Some(exclude_ip))
            .map(|v| ClientSimpleInfo {
                ip: v.ip.unwrap(),
                online: v.is_connected,
                node_type: NodeType::Vnt,
            })
            .collect();
        Some(crate::protocol::control_message::ClientSimpleInfoList {
            data_version: guard.data_version,
            list,
            is_all: false,
            time: 0,
        })
    }

    pub fn client_info_list(
        &self,
        exclude_ip: Ipv4Addr,
        include_wireguard: bool,
    ) -> Vec<crate::protocol::rpc_message::ClientInfo> {
        use crate::protocol::rpc_message::ClientInfo;
        use time::OffsetDateTime;

        let guard = self.lease_state.lock();
        let mut list = Vec::new();

        for (_device_id, entry) in &guard.device_map {
            let Some(ip) = entry.ip else {
                continue;
            };
            if ip == exclude_ip {
                continue;
            }
            let last_connect_time: OffsetDateTime = entry.last_connect_time.into();
            list.push(ClientInfo {
                name: entry.device_name.clone(),
                version: entry.device_version.clone(),
                ip: ip.into(),
                key_sign: entry.key_sign.clone(),
                online: entry.is_connected,
                last_connected_time: last_connect_time.unix_timestamp(),
                id: entry.device_id.clone(),
                node_type: crate::protocol::control_message::NodeType::Vnt as i32,
            });
        }
        if include_wireguard {
            for endpoint in self.online_endpoints.iter() {
                let OnlineEndpoint::WireGuard {
                    peer_id,
                    connected_at,
                } = endpoint.value()
                else {
                    continue;
                };
                list.push(ClientInfo {
                    name: peer_id.clone(),
                    version: "WireGuard".to_string(),
                    ip: (*endpoint.key()).into(),
                    key_sign: None,
                    online: true,
                    last_connected_time: *connected_at,
                    id: peer_id.clone(),
                    node_type: crate::protocol::control_message::NodeType::Wireguard as i32,
                });
            }
        }
        list
    }
}

impl NetworkStateInner {
    fn wireguard_peer_ip(&self, peer_id: &str) -> Option<Ipv4Addr> {
        self.wireguard_peer_ip_map
            .iter()
            .find_map(|(ip, owner)| (owner == peer_id).then_some(*ip))
    }

    fn prepare_wireguard_peer_ip_reservation(
        &mut self,
        peer_id: &str,
        ip: Ipv4Addr,
    ) -> anyhow::Result<Option<Ipv4Addr>> {
        if let Some(device_id) = self.device_ip_map.get(&ip) {
            bail!("IP重复，VNT设备 {device_id} 已使用此IP")
        }
        if let Some(existing_peer_id) = self.wireguard_peer_ip_map.get(&ip)
            && existing_peer_id != peer_id
        {
            bail!("IP重复，WireGuard peer {existing_peer_id} 已使用此IP")
        }

        let previous_ip =
            self.wireguard_peer_ip_map
                .iter()
                .find_map(|(existing_ip, existing_peer_id)| {
                    (existing_peer_id == peer_id).then_some(*existing_ip)
                });
        self.wireguard_peer_ip_map.insert(ip, peer_id.to_string());
        Ok(previous_ip)
    }

    fn commit_wireguard_peer_ip_reservation(
        &mut self,
        peer_id: &str,
        ip: Ipv4Addr,
        previous_ip: Option<Ipv4Addr>,
    ) {
        if let Some(previous_ip) = previous_ip.filter(|previous_ip| *previous_ip != ip)
            && self
                .wireguard_peer_ip_map
                .get(&previous_ip)
                .is_some_and(|existing_peer_id| existing_peer_id == peer_id)
        {
            self.wireguard_peer_ip_map.remove(&previous_ip);
        }
    }

    fn rollback_wireguard_peer_ip_reservation(
        &mut self,
        peer_id: &str,
        ip: Ipv4Addr,
        previous_ip: Option<Ipv4Addr>,
    ) {
        if previous_ip != Some(ip)
            && self
                .wireguard_peer_ip_map
                .get(&ip)
                .is_some_and(|existing_peer_id| existing_peer_id == peer_id)
        {
            self.wireguard_peer_ip_map.remove(&ip);
        }
    }

    fn release_wireguard_peer_ip(&mut self, peer_id: &str) -> bool {
        let before = self.wireguard_peer_ip_map.len();
        self.wireguard_peer_ip_map
            .retain(|_, existing_peer_id| existing_peer_id != peer_id);
        self.wireguard_peer_ip_map.len() != before
    }

    fn offline_ip(
        &mut self,
        network_code: &str,
        device_id: &String,
        ip: Ipv4Addr,
        random_id: u64,
    ) -> (bool, Option<DeviceRecord>) {
        let Some(device_entry) = self.device_map.get_mut(device_id) else {
            log::error!("unknown device_id {}", device_id);
            return (false, None);
        };
        if device_entry.random_id != random_id {
            return (false, None);
        }
        if device_entry.ip != Some(ip) {
            return (false, None);
        }
        self.data_version += 1;
        device_entry.data_version = self.data_version;
        device_entry.is_connected = false;
        device_entry.disconnect_time = Some(SystemTime::now());

        let record = device_entry.to_record(network_code);
        (true, Some(record))
    }

    fn collect_expired_devices(&self, lease_duration: Duration) -> Vec<String> {
        let now = SystemTime::now();
        self.device_map
            .iter()
            .filter_map(|(k, v)| {
                if v.is_connected {
                    return None;
                }
                if let Some(disconnect_time) = v.disconnect_time {
                    if disconnect_time + lease_duration > now {
                        return None;
                    }
                    return Some(k.clone());
                }
                None
            })
            .collect()
    }

    fn remove_devices(&mut self, device_ids: &[String]) {
        if device_ids.is_empty() {
            return;
        }
        self.data_version += 1;
        for device_id in device_ids {
            if let Some(entry) = self.device_map.remove(device_id) {
                if let Some(ip) = entry.ip {
                    self.device_ip_map.remove(&ip);
                }
            }
        }
    }

    fn add_device(&mut self, device_entry: DeviceEntry) {
        if let Some(ip) = device_entry.ip {
            self.device_ip_map
                .insert(ip, device_entry.device_id.clone());
        }
        self.device_map
            .insert(device_entry.device_id.clone(), device_entry);
    }

    #[allow(dead_code)]
    fn remove_device(&mut self, device_id: &String, ip: Option<Ipv4Addr>) {
        self.device_map.remove(device_id);
        if let Some(ip) = ip {
            self.device_ip_map.remove(&ip);
        }
    }

    fn allocate_ip(
        &mut self,
        net: &Ipv4Net,
        gateway: Ipv4Addr,
        reg_req: RegRequestMsg,
        random_id: u64,
    ) -> anyhow::Result<(Ipv4Addr, Option<Ipv4Addr>)> {
        let expect_ip = reg_req.ip;

        let existing_device_info = self
            .device_map
            .get(&reg_req.device_id)
            .map(|e| (e.ip, expect_ip.is_none() || e.ip == expect_ip));

        if let Some((current_ip, ip_matches)) = existing_device_info {
            if ip_matches {
                let new_ip = if current_ip.is_none() {
                    Some(self.find_available_ip(net, gateway)?)
                } else {
                    None
                };

                let device_entry = self.device_map.get_mut(&reg_req.device_id).unwrap();
                device_entry.is_connected = true;
                device_entry.disconnect_time = None;
                device_entry.random_id = random_id;
                device_entry.last_connect_time = SystemTime::now();
                self.data_version += 1;
                device_entry.data_version = self.data_version;
                device_entry.key_sign = reg_req.key_sign.clone();

                if let Some(ip) = new_ip {
                    device_entry.ip = Some(ip);
                    let device_id = device_entry.device_id.clone();
                    self.device_ip_map.insert(ip, device_id);
                    return Ok((ip, None));
                }
                return Ok((current_ip.unwrap(), None));
            }
        }

        let old = existing_device_info.and_then(|(ip, _)| ip);

        if let Some(ip) = expect_ip {
            loop {
                if ip == gateway {
                    if reg_req.ip_variable {
                        break;
                    }
                    bail!("此IP为网关IP，不允许使用")
                }
                if !net.contains(&ip) {
                    if reg_req.ip_variable {
                        break;
                    }
                    bail!("IP网段错误，应使用{}网段中的IP", net)
                }
                if let Some(peer_id) = self.wireguard_peer_ip_map.get(&ip) {
                    if reg_req.ip_variable {
                        break;
                    }
                    bail!("IP重复，WireGuard peer {peer_id} 已使用此IP")
                }
                if let Some(id) = self.device_ip_map.get(&ip) {
                    if reg_req.ip_variable {
                        break;
                    }
                    if let Some(v) = self.device_map.get(id) {
                        bail!("IP重复，设备{}[{}]已使用此IP", v.device_name, v.device_id)
                    }
                    bail!("IP重复，服务端数据错误")
                }
                if let Some(old_ip) = old {
                    self.device_ip_map.remove(&old_ip);
                }
                self.data_version += 1;
                self.add_device(DeviceEntry {
                    device_id: reg_req.device_id,
                    ip: Some(ip),
                    random_id,
                    device_name: reg_req.name,
                    device_version: reg_req.version,
                    is_connected: true,
                    last_connect_time: SystemTime::now(),
                    disconnect_time: None,
                    data_version: self.data_version,
                    key_sign: reg_req.key_sign,
                    latency_ms: None,
                    traffic_stats: Arc::new(TrafficStats::new()),
                });

                return Ok((ip, old));
            }
        }

        let ip = self.find_available_ip(net, gateway)?;
        self.data_version += 1;
        self.add_device(DeviceEntry {
            device_id: reg_req.device_id,
            ip: Some(ip),
            random_id,
            device_name: reg_req.name,
            device_version: reg_req.version,
            is_connected: true,
            last_connect_time: SystemTime::now(),
            disconnect_time: None,
            data_version: self.data_version,
            key_sign: reg_req.key_sign,
            latency_ms: None,
            traffic_stats: Arc::new(TrafficStats::new()),
        });
        Ok((ip, old))
    }

    fn find_available_ip(&self, net: &Ipv4Net, gateway: Ipv4Addr) -> anyhow::Result<Ipv4Addr> {
        let start = u32::from(net.network()) + 1;
        let end = u32::from(net.broadcast());
        for i in start..end {
            let ip = Ipv4Addr::from(i);
            if ip == gateway {
                continue;
            }
            if self.device_ip_map.contains_key(&ip) {
                continue;
            }
            if self.wireguard_peer_ip_map.contains_key(&ip) {
                continue;
            }
            return Ok(ip);
        }
        bail!("IP exhaustion");
    }
}

impl NetworkState {
    async fn build_initial_inner_state(
        network_code: &str,
        net: Ipv4Net,
        gateway: Ipv4Addr,
    ) -> NetworkStateInner {
        let mut device_map = HashMap::new();
        let mut device_ip_map = HashMap::new();
        let mut max_version = 0u64;

        match db::load_all_devices(network_code).await {
            Ok(records) => {
                for record in records {
                    let entry = DeviceEntry::from_record(record);
                    if let Some(ip) = entry.ip {
                        if net.contains(&ip) && gateway != ip {
                            device_ip_map.insert(ip, entry.device_id.clone());
                        }
                    }
                    max_version = max_version.max(entry.data_version);
                    device_map.insert(entry.device_id.clone(), entry);
                }

                if !device_map.is_empty() {
                    log::info!(
                        "Loaded {} devices for network {}",
                        device_map.len(),
                        network_code
                    );
                }
            }
            Err(e) => log::error!(
                "Error loading all devices for network {}: {}",
                network_code,
                e
            ),
        }

        let mut wireguard_peer_ip_map = HashMap::new();
        match db::load_wireguard_peer_ip_allocations(network_code).await {
            Ok(allocations) => {
                for allocation in allocations {
                    if net.contains(&allocation.ip) && gateway != allocation.ip {
                        wireguard_peer_ip_map.insert(allocation.ip, allocation.peer_id);
                    } else {
                        log::warn!(
                            "Ignoring WireGuard peer IP outside network: network_code={}, ip={}",
                            network_code,
                            allocation.ip
                        );
                    }
                }
            }
            Err(e) => log::error!(
                "Error loading WireGuard peer IPs for network {}: {}",
                network_code,
                e
            ),
        }

        NetworkStateInner {
            data_version: max_version,
            last_wireguard_change_version: 0,
            device_map,
            device_ip_map,
            wireguard_peer_ip_map,
            remote_wireguard_sources: HashMap::new(),
        }
    }

    pub async fn new_from_db(
        network_code: String,
        net: Ipv4Net,
        lease_duration: Duration,
    ) -> NetworkState {
        let gateway = Ipv4Addr::from(u32::from(net.network()) + 1);
        let initial_inner_state =
            Self::build_initial_inner_state(&network_code, net, gateway).await;
        Self {
            time: Mutex::new(Instant::now()),
            network_code,
            gateway,
            net,
            lease_duration,
            sender_map: Default::default(),
            online_endpoints: Default::default(),
            wireguard_backpressure_drops: Default::default(),
            lease_state: Mutex::new(initial_inner_state),
            wireguard_ip_update_lock: tokio::sync::Mutex::new(()),
            traffic_stats_map: Default::default(),
            dashboard_traffic: TrafficStats::new(),
            dashboard_wireguard_drops: AtomicU64::new(0),
        }
    }

    pub fn update_time(&self) {
        *self.time.lock() = Instant::now();
    }

    pub fn update_client_latency(&self, ip: Ipv4Addr, latency_ms: u32) {
        let mut guard = self.lease_state.lock();
        if let Some(device_id) = guard.device_ip_map.get(&ip).cloned() {
            if let Some(entry) = guard.device_map.get_mut(&device_id) {
                entry.latency_ms = Some(latency_ms);
                log::debug!(
                    "Updated client latency: network_code={}, ip={}, latency={} ms",
                    self.network_code,
                    ip,
                    latency_ms
                );
            }
        }
    }
}

/// 网络状态的共享视图，供 PeerServerManager 等外部模块访问
#[derive(Clone)]
pub struct NetworkStateProvider {
    network_states: Arc<DashMap<String, Arc<NetworkState>>>,
}

impl NetworkStateProvider {
    pub fn new(network_states: Arc<DashMap<String, Arc<NetworkState>>>) -> Self {
        Self { network_states }
    }

    pub fn get_network_codes(&self) -> Vec<String> {
        self.network_states
            .iter()
            .map(|entry| entry.key().clone())
            .collect()
    }

    pub fn get_network_state(&self, network_code: &str) -> Option<Arc<NetworkState>> {
        self.network_states.get(network_code).map(|s| s.clone())
    }

    pub fn update_client_latency(&self, network_code: &str, ip: Ipv4Addr, latency_ms: u32) {
        if let Some(state) = self.get_network_state(network_code) {
            state.update_client_latency(ip, latency_ms);
        }
    }

    pub(crate) fn dashboard_traffic_snapshot(&self) -> DashboardTrafficSnapshot {
        self.network_states.iter().fold(
            DashboardTrafficSnapshot::default(),
            |mut total, network| {
                let snapshot = network.value().dashboard_traffic_snapshot();
                total.tx_bytes_total = total.tx_bytes_total.saturating_add(snapshot.tx_bytes_total);
                total.rx_bytes_total = total.rx_bytes_total.saturating_add(snapshot.rx_bytes_total);
                total.wireguard_drops_total = total
                    .wireguard_drops_total
                    .saturating_add(snapshot.wireguard_drops_total);
                total
            },
        )
    }

    pub(crate) fn dashboard_endpoint_snapshot(&self) -> DashboardEndpointSnapshot {
        self.network_states.iter().fold(
            DashboardEndpointSnapshot::default(),
            |mut total, network| {
                let snapshot = network.value().dashboard_endpoint_snapshot();
                total.vnt_online = total.vnt_online.saturating_add(snapshot.vnt_online);
                total.wireguard_online = total
                    .wireguard_online
                    .saturating_add(snapshot.wireguard_online);
                total
            },
        )
    }
}

impl Deref for NetworkStateProvider {
    type Target = DashMap<String, Arc<NetworkState>>;

    fn deref(&self) -> &Self::Target {
        &self.network_states
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::control_message::proto::wire_guard_p2p_control::Payload;
    use crate::protocol::control_message::proto::{
        WireGuardP2pAgentResponse, WireGuardP2pControl, WireGuardP2pStatus,
    };
    use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
    use crate::server::wireguard_bridge::{
        Ipv4Route, build_wireguard_relay, build_wireguard_subnet_relay,
        validate_broadcast_inner_ipv4,
    };
    use bytes::BytesMut;
    use prost::Message;

    fn test_network_state(wireguard_peer_ip_map: HashMap<Ipv4Addr, String>) -> NetworkState {
        NetworkState {
            time: Mutex::new(Instant::now()),
            network_code: "network-a".to_string(),
            gateway: Ipv4Addr::new(10, 26, 0, 1),
            net: Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24),
            lease_duration: Duration::from_secs(60),
            sender_map: DashMap::new(),
            online_endpoints: DashMap::new(),
            wireguard_backpressure_drops: DashMap::new(),
            lease_state: Mutex::new(NetworkStateInner {
                data_version: 0,
                last_wireguard_change_version: 0,
                device_map: HashMap::new(),
                device_ip_map: HashMap::new(),
                wireguard_peer_ip_map,
                remote_wireguard_sources: HashMap::new(),
            }),
            wireguard_ip_update_lock: tokio::sync::Mutex::new(()),
            traffic_stats_map: DashMap::new(),
            dashboard_traffic: TrafficStats::new(),
            dashboard_wireguard_drops: AtomicU64::new(0),
        }
    }

    fn relay(source: Ipv4Addr, destination: Ipv4Addr) -> Bytes {
        let mut ipv4 = vec![0; 20];
        ipv4[0] = 0x45;
        ipv4[2..4].copy_from_slice(&20_u16.to_be_bytes());
        ipv4[12..16].copy_from_slice(&source.octets());
        ipv4[16..20].copy_from_slice(&destination.octets());
        build_wireguard_relay(
            &ipv4,
            Ipv4Route {
                source,
                destination,
            },
        )
    }

    fn broadcast_ipv4(source: Ipv4Addr, destination: Ipv4Addr) -> Vec<u8> {
        let mut ipv4 = vec![0; 20];
        ipv4[0] = 0x45;
        ipv4[2..4].copy_from_slice(&20_u16.to_be_bytes());
        ipv4[8] = 64;
        ipv4[9] = 17;
        ipv4[12..16].copy_from_slice(&source.octets());
        ipv4[16..20].copy_from_slice(&destination.octets());
        ipv4
    }

    #[test]
    fn p2p_resolution_requires_confirmed_capability_and_delivers_bound_offer() {
        let wireguard_ip = Ipv4Addr::new(10, 26, 0, 2);
        let vnt_ip = Ipv4Addr::new(10, 26, 0, 3);
        let state = test_network_state(HashMap::new());
        let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
        state.sender_map.insert(vnt_ip, NetworkSender::Vnt(sender));
        state.online_endpoints.insert(
            vnt_ip,
            OnlineEndpoint::Vnt {
                random_id: 7,
                allow_wireguard: true,
                client_capabilities: 0,
                confirmed: true,
                wireguard_p2p: Some(WireGuardP2pEndpoint {
                    public_key: [0x33; 32],
                    endpoint: "198.51.100.3:51820".parse().unwrap(),
                }),
            },
        );

        let resolution = crate::server::wireguard_p2p::resolve_agent_request(
            &state,
            wireguard_ip,
            [0x22; 32],
            "198.51.100.2:51820".parse().unwrap(),
            crate::server::wireguard_p2p::AgentControlRequest {
                source_port: 40000,
                target_ip: vnt_ip,
                request_id: 9,
            },
        );
        let response = WireGuardP2pAgentResponse::decode(resolution.response.as_slice()).unwrap();
        assert_eq!(
            resolution.granted,
            Some(crate::server::wireguard_p2p::GrantedLease {
                target_ip: vnt_ip,
                lease_id: response.lease_id,
            })
        );
        assert_eq!(response.status, WireGuardP2pStatus::WireguardP2pOk as i32);
        assert_eq!(response.target_public_key, vec![0x33; 32]);
        assert_eq!(response.target_endpoint, "198.51.100.3:51820");

        let delivered = receiver.try_recv().unwrap();
        let packet = NetPacket::new(delivered).unwrap();
        assert_eq!(packet.msg_type().unwrap(), MsgType::WireGuardP2pControl);
        let control = WireGuardP2pControl::decode(packet.payload()).unwrap();
        let Some(Payload::Offer(offer)) = control.payload else {
            panic!("expected P2P offer");
        };
        assert_eq!(offer.peer_ip, u32::from(wireguard_ip));
        assert_eq!(offer.peer_public_key, vec![0x22; 32]);
        assert_eq!(offer.peer_endpoint, "198.51.100.2:51820");
        assert_eq!(offer.lease_id, response.lease_id);

        crate::server::wireguard_p2p::revoke_lease(&state, vnt_ip, response.lease_id);
        let revoked = receiver.try_recv().unwrap();
        let packet = NetPacket::new(revoked).unwrap();
        let control = WireGuardP2pControl::decode(packet.payload()).unwrap();
        let Some(Payload::Revoke(revoke)) = control.payload else {
            panic!("expected P2P revoke");
        };
        assert_eq!(revoke.lease_id, response.lease_id);
    }

    #[test]
    fn online_endpoint_gate_preserves_relay_security_boundaries() {
        let wireguard_ip = Ipv4Addr::new(10, 26, 0, 2);
        let vnt_ip = Ipv4Addr::new(10, 26, 0, 3);
        let state = test_network_state(HashMap::from([(wireguard_ip, "peer-a".to_string())]));
        let (wireguard_sender, mut wireguard_receiver) = tokio::sync::mpsc::channel(1);
        assert!(state.connect_wireguard_peer("peer-a", wireguard_ip, wireguard_sender));

        let to_wireguard = relay(vnt_ip, wireguard_ip);
        assert_eq!(
            state.try_deliver(wireguard_ip, to_wireguard.clone(), RelayOrigin::Vnt),
            LocalDeliveryResult::Delivered
        );
        assert_eq!(
            state.try_deliver(wireguard_ip, to_wireguard.clone(), RelayOrigin::Vnt),
            LocalDeliveryResult::Full
        );
        assert_eq!(
            state
                .wireguard_backpressure_drops
                .get(&wireguard_ip)
                .unwrap()
                .load(Ordering::Relaxed),
            1
        );
        assert_eq!(state.dashboard_traffic_snapshot().wireguard_drops_total, 1);
        let bridged = wireguard_receiver.try_recv().unwrap();
        assert_eq!(bridged.network_code, "network-a");
        assert_eq!(bridged.data, to_wireguard);

        let mut encrypted_turn = BytesMut::zeroed(HEAD_LENGTH + 20);
        NetPacket::new(&mut encrypted_turn)
            .unwrap()
            .set_msg_type(MsgType::Turn);
        assert_eq!(
            state.try_deliver(wireguard_ip, encrypted_turn.freeze(), RelayOrigin::Vnt,),
            LocalDeliveryResult::Rejected
        );

        let (vnt_sender, mut vnt_receiver) = tokio::sync::mpsc::channel(1);
        state
            .sender_map
            .insert(vnt_ip, NetworkSender::Vnt(vnt_sender));
        state.online_endpoints.insert(
            vnt_ip,
            OnlineEndpoint::Vnt {
                random_id: 7,
                allow_wireguard: true,
                client_capabilities: 0,
                confirmed: true,
                wireguard_p2p: None,
            },
        );
        let to_vnt = relay(wireguard_ip, vnt_ip);
        assert_eq!(
            state.try_deliver(vnt_ip, to_vnt.clone(), RelayOrigin::Vnt),
            LocalDeliveryResult::Rejected
        );
        assert_eq!(
            state.try_deliver(vnt_ip, to_vnt.clone(), RelayOrigin::WireGuard),
            LocalDeliveryResult::Delivered
        );
        assert_eq!(vnt_receiver.try_recv().unwrap(), to_vnt);

        assert!(state.disconnect_wireguard_peer("peer-a", wireguard_ip));
        assert!(!state.sender_map.contains_key(&wireguard_ip));
        assert!(!state.online_endpoints.contains_key(&wireguard_ip));
        let guard = state.lease_state.lock();
        assert_eq!(guard.data_version, 2);
        assert_eq!(guard.last_wireguard_change_version, 2);
    }

    #[test]
    fn wireguard_broadcast_only_reaches_eligible_local_endpoints() {
        let source = Ipv4Addr::new(10, 26, 0, 2);
        let wireguard_target = Ipv4Addr::new(10, 26, 0, 3);
        let capable_vnt = Ipv4Addr::new(10, 26, 0, 4);
        let legacy_vnt = Ipv4Addr::new(10, 26, 0, 5);
        let state = test_network_state(HashMap::from([
            (source, "peer-source".to_string()),
            (wireguard_target, "peer-target".to_string()),
        ]));

        let (source_sender, _source_receiver) = tokio::sync::mpsc::channel(1);
        let (wireguard_sender, mut wireguard_receiver) = tokio::sync::mpsc::channel(1);
        assert!(state.connect_wireguard_peer("peer-source", source, source_sender));
        assert!(state.connect_wireguard_peer("peer-target", wireguard_target, wireguard_sender));

        let (capable_sender, mut capable_receiver) = tokio::sync::mpsc::channel(1);
        state
            .sender_map
            .insert(capable_vnt, NetworkSender::Vnt(capable_sender));
        state.online_endpoints.insert(
            capable_vnt,
            OnlineEndpoint::Vnt {
                random_id: 7,
                allow_wireguard: true,
                client_capabilities: CLIENT_CAP_WIREGUARD_BROADCAST_RELAY
                    | CLIENT_CAP_WIREGUARD_SUBNET_RELAY,
                confirmed: true,
                wireguard_p2p: None,
            },
        );

        let (legacy_sender, mut legacy_receiver) = tokio::sync::mpsc::channel(1);
        state
            .sender_map
            .insert(legacy_vnt, NetworkSender::Vnt(legacy_sender));
        state.online_endpoints.insert(
            legacy_vnt,
            OnlineEndpoint::Vnt {
                random_id: 8,
                allow_wireguard: true,
                client_capabilities: 0,
                confirmed: true,
                wireguard_p2p: None,
            },
        );

        let inner = broadcast_ipv4(source, state.net.broadcast());
        assert_eq!(
            validate_broadcast_inner_ipv4(&inner, source, state.net, state.gateway),
            Ok(Ipv4Route {
                source,
                destination: state.net.broadcast(),
            })
        );
        assert_eq!(
            state
                .relay_wireguard_broadcast(source, &inner, RelayOrigin::WireGuard)
                .unwrap(),
            2
        );

        for (target, data) in [
            (
                wireguard_target,
                wireguard_receiver.try_recv().unwrap().data,
            ),
            (capable_vnt, capable_receiver.try_recv().unwrap()),
        ] {
            let packet = NetPacket::new(data).unwrap();
            assert_eq!(packet.msg_type().unwrap(), MsgType::WireGuardBroadcastRelay);
            assert_eq!(Ipv4Addr::from(packet.src_id()), source);
            assert_eq!(Ipv4Addr::from(packet.dest_id()), target);
            assert_eq!(packet.payload(), inner);
        }
        assert!(legacy_receiver.try_recv().is_err());

        let lan_destination = Ipv4Addr::new(192, 168, 10, 25);
        let subnet_inner = broadcast_ipv4(source, lan_destination);
        let subnet_route = Ipv4Route {
            source,
            destination: lan_destination,
        };
        let capable_relay = build_wireguard_subnet_relay(&subnet_inner, subnet_route, capable_vnt);
        assert_eq!(
            state.try_deliver(capable_vnt, capable_relay, RelayOrigin::WireGuard),
            LocalDeliveryResult::Delivered
        );
        let packet = NetPacket::new(capable_receiver.try_recv().unwrap()).unwrap();
        assert_eq!(packet.msg_type().unwrap(), MsgType::WireGuardSubnetRelay);
        assert_eq!(packet.payload(), subnet_inner);

        let legacy_relay = build_wireguard_subnet_relay(&subnet_inner, subnet_route, legacy_vnt);
        assert_eq!(
            state.try_deliver(legacy_vnt, legacy_relay, RelayOrigin::WireGuard),
            LocalDeliveryResult::Rejected
        );
        assert!(legacy_receiver.try_recv().is_err());
    }

    #[test]
    fn wireguard_nodes_are_only_listed_for_capable_vnt_sessions() {
        let wireguard_ip = Ipv4Addr::new(10, 26, 0, 2);
        let state = test_network_state(HashMap::from([(wireguard_ip, "peer-a".to_string())]));
        let (sender, _receiver) = tokio::sync::mpsc::channel(1);
        assert!(state.connect_wireguard_peer("peer-a", wireguard_ip, sender));

        let legacy = state
            .changed_client_simple_list(Ipv4Addr::new(10, 26, 0, 3), 0, false)
            .unwrap();
        assert!(legacy.list.is_empty());

        let capable = state
            .changed_client_simple_list(Ipv4Addr::new(10, 26, 0, 3), 0, true)
            .unwrap();
        assert!(capable.is_all);
        assert_eq!(capable.list.len(), 1);
        assert_eq!(capable.list[0].ip, wireguard_ip);
        assert_eq!(
            capable.list[0].node_type,
            crate::protocol::control_message::NodeType::Wireguard
        );

        assert!(
            state
                .client_info_list(Ipv4Addr::new(10, 26, 0, 3), false)
                .is_empty()
        );
        let rpc = state.client_info_list(Ipv4Addr::new(10, 26, 0, 3), true);
        assert_eq!(rpc.len(), 1);
        assert_eq!(rpc[0].ip, u32::from(wireguard_ip));
    }

    #[test]
    fn remote_wireguard_topology_updates_client_list_versions() {
        let state = test_network_state(HashMap::new());
        let remote_ip = Ipv4Addr::new(10, 26, 0, 20);
        assert!(state.update_remote_wireguard_ips("server-b", HashSet::from([remote_ip]),));
        assert!(!state.update_remote_wireguard_ips("server-b", HashSet::from([remote_ip]),));

        let capable = state
            .changed_client_simple_list(Ipv4Addr::new(10, 26, 0, 3), 0, true)
            .unwrap();
        assert!(capable.is_all);
        assert_eq!(capable.list.len(), 1);
        assert_eq!(capable.list[0].ip, remote_ip);
        assert_eq!(
            capable.list[0].node_type,
            crate::protocol::control_message::NodeType::Wireguard
        );
        let version = capable.data_version;

        assert!(state.remove_remote_wireguard_source("server-b"));
        let removed = state
            .changed_client_simple_list(Ipv4Addr::new(10, 26, 0, 3), version, true)
            .unwrap();
        assert!(removed.is_all);
        assert!(removed.list.is_empty());
        assert!(!state.remove_remote_wireguard_source("server-b"));
    }

    #[test]
    fn automatic_allocation_skips_wireguard_peer_reservations() {
        let reserved_ip = Ipv4Addr::new(10, 26, 0, 2);
        let mut wireguard_peer_ip_map = HashMap::new();
        wireguard_peer_ip_map.insert(reserved_ip, "peer-a".to_string());
        let state = NetworkStateInner {
            data_version: 0,
            last_wireguard_change_version: 0,
            device_map: HashMap::new(),
            device_ip_map: HashMap::new(),
            wireguard_peer_ip_map,
            remote_wireguard_sources: HashMap::new(),
        };
        let net = Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24);

        assert_eq!(
            state
                .find_available_ip(&net, Ipv4Addr::new(10, 26, 0, 1))
                .unwrap(),
            Ipv4Addr::new(10, 26, 0, 3)
        );
    }

    #[tokio::test]
    async fn peer_move_keeps_old_and_new_ips_reserved_until_database_commit() {
        let old_ip = Ipv4Addr::new(10, 26, 0, 2);
        let new_ip = Ipv4Addr::new(10, 26, 0, 3);
        let mut peer_ips = HashMap::new();
        peer_ips.insert(old_ip, "peer-a".to_string());
        let state = Arc::new(test_network_state(peer_ips));
        let (persist_started_tx, persist_started_rx) = tokio::sync::oneshot::channel();
        let (persist_continue_tx, persist_continue_rx) = tokio::sync::oneshot::channel();

        let update_state = state.clone();
        let update = tokio::spawn(async move {
            update_state
                .reserve_wireguard_peer_ip_with("peer-a", new_ip, async move {
                    let _ = persist_started_tx.send(());
                    let _ = persist_continue_rx.await;
                    Ok(())
                })
                .await
        });

        persist_started_rx.await.unwrap();
        {
            let guard = state.lease_state.lock();
            assert_eq!(guard.wireguard_peer_ip_map.get(&old_ip).unwrap(), "peer-a");
            assert_eq!(guard.wireguard_peer_ip_map.get(&new_ip).unwrap(), "peer-a");
        }

        persist_continue_tx.send(()).unwrap();
        update.await.unwrap().unwrap();
        {
            let guard = state.lease_state.lock();
            assert!(!guard.wireguard_peer_ip_map.contains_key(&old_ip));
            assert_eq!(guard.wireguard_peer_ip_map.get(&new_ip).unwrap(), "peer-a");
        }

        assert!(
            state
                .release_wireguard_peer_ip_with("peer-a", async { Ok(true) })
                .await
                .unwrap()
        );
        assert!(state.lease_state.lock().wireguard_peer_ip_map.is_empty());
    }

    #[tokio::test]
    async fn database_failure_restores_peer_reservation_and_blocks_release() {
        let old_ip = Ipv4Addr::new(10, 26, 0, 2);
        let new_ip = Ipv4Addr::new(10, 26, 0, 3);
        let mut peer_ips = HashMap::new();
        peer_ips.insert(old_ip, "peer-a".to_string());
        let state = test_network_state(peer_ips);

        assert!(
            state
                .reserve_wireguard_peer_ip_with("peer-a", new_ip, async {
                    anyhow::bail!("database rejected update")
                })
                .await
                .is_err()
        );
        {
            let guard = state.lease_state.lock();
            assert_eq!(guard.wireguard_peer_ip_map.get(&old_ip).unwrap(), "peer-a");
            assert!(!guard.wireguard_peer_ip_map.contains_key(&new_ip));
        }

        assert!(
            state
                .release_wireguard_peer_ip_with("peer-a", async {
                    anyhow::bail!("database rejected release")
                })
                .await
                .is_err()
        );
        assert_eq!(
            state
                .lease_state
                .lock()
                .wireguard_peer_ip_map
                .get(&old_ip)
                .unwrap(),
            "peer-a"
        );
    }

    #[tokio::test]
    async fn peer_delete_keeps_runtime_ip_on_failure_and_merges_runtime_release() {
        let peer_ip = Ipv4Addr::new(10, 26, 0, 2);
        let mut peer_ips = HashMap::new();
        peer_ips.insert(peer_ip, "peer-a".to_string());
        let state = test_network_state(peer_ips);

        assert!(
            state
                .delete_wireguard_peer_with(
                    "peer-a",
                    async { anyhow::bail!("database rejected peer deletion") },
                    async { Ok(()) }
                )
                .await
                .is_err()
        );
        assert_eq!(
            state.lease_state.lock().wireguard_peer_ip("peer-a"),
            Some(peer_ip)
        );

        let result = state
            .delete_wireguard_peer_with(
                "peer-a",
                async {
                    Ok(WireGuardPeerDeleteResult {
                        peer_removed: true,
                        ip_released: false,
                    })
                },
                async { Ok(()) },
            )
            .await
            .unwrap();
        assert_eq!(
            result,
            WireGuardPeerDeleteResult {
                peer_removed: true,
                ip_released: true,
            }
        );
        assert!(state.lease_state.lock().wireguard_peer_ip_map.is_empty());
    }

    #[tokio::test]
    async fn peer_delete_and_ip_list_share_the_same_update_lock() {
        let peer_ip = Ipv4Addr::new(10, 26, 0, 2);
        let mut peer_ips = HashMap::new();
        peer_ips.insert(peer_ip, "peer-a".to_string());
        let state = Arc::new(test_network_state(peer_ips));
        let (persist_started_tx, persist_started_rx) = tokio::sync::oneshot::channel();
        let (persist_continue_tx, persist_continue_rx) = tokio::sync::oneshot::channel();

        let delete_state = state.clone();
        let deletion = tokio::spawn(async move {
            delete_state
                .delete_wireguard_peer_with(
                    "peer-a",
                    async move {
                        let _ = persist_started_tx.send(());
                        let _ = persist_continue_rx.await;
                        Ok(WireGuardPeerDeleteResult {
                            peer_removed: true,
                            ip_released: true,
                        })
                    },
                    async { Ok(()) },
                )
                .await
        });
        persist_started_rx.await.unwrap();

        let list_state = state.clone();
        let listing = tokio::spawn(async move { list_state.list_wireguard_peer_ips().await });
        tokio::task::yield_now().await;
        assert!(
            !listing.is_finished(),
            "IP list must wait for peer deletion"
        );

        persist_continue_tx.send(()).unwrap();
        deletion.await.unwrap().unwrap();
        assert!(listing.await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn runtime_reservation_rejects_invalid_and_occupied_ips() {
        let peer_ip = Ipv4Addr::new(10, 26, 0, 2);
        let device_ip = Ipv4Addr::new(10, 26, 0, 3);
        let mut peer_ips = HashMap::new();
        peer_ips.insert(peer_ip, "peer-a".to_string());
        let state = test_network_state(peer_ips);
        state
            .lease_state
            .lock()
            .device_ip_map
            .insert(device_ip, "device-a".to_string());

        assert!(
            state
                .reserve_wireguard_peer_ip_with("peer-b", peer_ip, async { Ok(()) })
                .await
                .unwrap_err()
                .to_string()
                .contains("peer-a")
        );
        assert!(
            state
                .reserve_wireguard_peer_ip_with("peer-b", device_ip, async { Ok(()) })
                .await
                .unwrap_err()
                .to_string()
                .contains("device-a")
        );
        assert!(
            state
                .reserve_wireguard_peer_ip_with("peer-b", Ipv4Addr::new(10, 27, 0, 2), async {
                    Ok(())
                },)
                .await
                .is_err()
        );
        assert!(
            state
                .reserve_wireguard_peer_ip_with(" ", device_ip, async { Ok(()) })
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn wireguard_peer_ip_list_is_sorted_by_peer_id() {
        let mut peer_ips = HashMap::new();
        peer_ips.insert(Ipv4Addr::new(10, 26, 0, 3), "peer-b".to_string());
        peer_ips.insert(Ipv4Addr::new(10, 26, 0, 2), "peer-a".to_string());
        let state = test_network_state(peer_ips);

        assert_eq!(
            state.list_wireguard_peer_ips().await,
            vec![
                ("peer-a".to_string(), Ipv4Addr::new(10, 26, 0, 2)),
                ("peer-b".to_string(), Ipv4Addr::new(10, 26, 0, 3)),
            ]
        );
    }
}

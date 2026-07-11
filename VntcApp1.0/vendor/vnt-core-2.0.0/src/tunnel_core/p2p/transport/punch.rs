use crate::context::nat::PunchBackoff;
use crate::context::{ServerInfoCollection, SharedNetworkAddr};
use crate::crypto::PacketCrypto;
use crate::protocol::client_message::PunchInfo;
use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use crate::protocol::transmission::TransmissionBytes;
use crate::tunnel_core::p2p::route_table::RouteTable;
use crate::tunnel_core::server::outbound::ServerOutbound;
use anyhow::bail;
use log::error;
use parking_lot::Mutex;
use rand::seq::SliceRandom;
use rust_p2p_core::punch::{PunchModel, Puncher};
use std::collections::{HashMap, HashSet};
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const BACKGROUND_PUNCH_INTERVAL: Duration = Duration::from_secs(5);
const BACKGROUND_PUNCH_LIMIT: usize = 5;
const PRIORITY_PUNCH_QUEUE_CAPACITY: usize = 64;
const PRIORITY_PUNCH_COOLDOWN: Duration = Duration::from_secs(1);

pub struct PunchTaskContext {
    pub network: SharedNetworkAddr,
    pub server_info: ServerInfoCollection,
    pub punch_backoff: PunchBackoff,
    pub punch_info_getter: PunchInfoGetter,
    pub priority_queue: PunchRequestQueue,
}

pub type PunchInfoGetter = Arc<dyn Fn() -> Option<PunchInfo> + Send + Sync>;

#[derive(Clone)]
pub struct PunchRequestQueue {
    sender: mpsc::Sender<Ipv4Addr>,
    pending: Arc<Mutex<HashSet<Ipv4Addr>>>,
    last_requested: Arc<Mutex<HashMap<Ipv4Addr, Instant>>>,
}

impl PunchRequestQueue {
    pub fn new() -> (Self, mpsc::Receiver<Ipv4Addr>) {
        let (sender, receiver) = mpsc::channel(PRIORITY_PUNCH_QUEUE_CAPACITY);
        (
            Self {
                sender,
                pending: Arc::new(Mutex::new(HashSet::new())),
                last_requested: Arc::new(Mutex::new(HashMap::new())),
            },
            receiver,
        )
    }

    pub fn request(&self, dest_ip: Ipv4Addr) -> bool {
        let now = Instant::now();
        {
            let mut last_requested = self.last_requested.lock();
            last_requested.retain(|_, requested_at| {
                now.duration_since(*requested_at) < PRIORITY_PUNCH_COOLDOWN
            });
            if last_requested.contains_key(&dest_ip) {
                return false;
            }
            last_requested.insert(dest_ip, now);
        }

        let mut pending = self.pending.lock();
        if !pending.insert(dest_ip) {
            return false;
        }
        if self.sender.try_send(dest_ip).is_ok() {
            return true;
        }
        pending.remove(&dest_ip);
        self.last_requested.lock().remove(&dest_ip);
        false
    }

    pub fn complete(&self, dest_ip: Ipv4Addr) {
        self.pending.lock().remove(&dest_ip);
    }
}

pub async fn punch_task(
    tunnel_to_server: ServerOutbound,
    route_table: RouteTable,
    ctx: PunchTaskContext,
    mut priority_requests: mpsc::Receiver<Ipv4Addr>,
) -> anyhow::Result<()> {
    let mut background_tick = tokio::time::interval(BACKGROUND_PUNCH_INTERVAL);
    background_tick.tick().await;
    loop {
        let (destinations, is_priority) = tokio::select! {
            biased;
            Some(dest_ip) = priority_requests.recv() => {
                ctx.priority_queue.complete(dest_ip);
                (vec![dest_ip], true)
            }
            _ = background_tick.tick() => {
                (background_punch_targets(ctx.server_info.client_online_ips()), false)
            }
        };
        let Some(src_ip) = ctx.network.ip() else {
            continue;
        };
        let Some(punch_info) = (ctx.punch_info_getter)() else {
            continue;
        };
        for dest_ip in destinations {
            if dest_ip == src_ip || (!is_priority && dest_ip <= src_ip) {
                continue;
            }
            if !ctx.server_info.exists_online_client_ip(&dest_ip) {
                continue;
            }
            if ctx.server_info.is_any_server_connected(None) && route_table.need_punch(&dest_ip) {
                if !ctx.punch_backoff.should_punch(dest_ip) {
                    continue;
                }
                log::info!("punching {dest_ip}");

                let data = punch_info.encode();
                let mut net_packet = NetPacket::new(TransmissionBytes::zeroed_size(
                    HEAD_LENGTH + data.len(),
                    tunnel_to_server.encrypt_reserve(),
                ))?;
                net_packet.set_msg_type(MsgType::PunchStart1);
                net_packet.set_ttl(2);
                net_packet.set_src_id(src_ip.into());
                net_packet.set_dest_id(dest_ip.into());
                net_packet.set_payload(data.as_ref())?;
                if let Err(e) = tunnel_to_server.send(dest_ip, net_packet).await {
                    error!("punch send error {:?}", e);
                }
            }
        }
    }
}

fn background_punch_targets(mut online_ips: Vec<Ipv4Addr>) -> Vec<Ipv4Addr> {
    online_ips.shuffle(&mut rand::rng());
    online_ips.truncate(BACKGROUND_PUNCH_LIMIT);
    online_ips
}
#[derive(Clone)]
pub struct NatPuncher {
    network: SharedNetworkAddr,
    punch_backoff: PunchBackoff,
    puncher: Option<Puncher>,
    packet_crypto: PacketCrypto,
}

impl NatPuncher {
    pub fn new(
        network: SharedNetworkAddr,
        punch_backoff: PunchBackoff,
        puncher: Option<Puncher>,
        packet_crypto: PacketCrypto,
    ) -> Self {
        Self {
            network,
            punch_backoff,
            puncher,
            packet_crypto,
        }
    }
    pub fn punch(&self, dest_ip: Ipv4Addr, punch_info: PunchInfo) -> anyhow::Result<bool> {
        if self.puncher.is_none() {
            return Ok(false);
        }
        if !self.punch_backoff.should_punch(dest_ip) {
            return Ok(false);
        }
        self.punch_uncheck_delay(dest_ip, punch_info, Some(Duration::from_millis(50)))?;
        Ok(true)
    }
    pub fn punch_uncheck(&self, dest_ip: Ipv4Addr, punch_info: PunchInfo) -> anyhow::Result<()> {
        self.punch_uncheck_delay(dest_ip, punch_info, None)
    }
    pub fn punch_uncheck_delay(
        &self,
        dest_ip: Ipv4Addr,
        punch_info: PunchInfo,
        time: Option<Duration>,
    ) -> anyhow::Result<()> {
        let Some(puncher) = self.puncher.clone() else {
            return Ok(());
        };
        let Some(src_ip) = self.network.ip() else {
            bail!("not ip");
        };
        let packet_crypto = self.packet_crypto.clone();
        tokio::spawn(async move {
            if let Some(time) = time {
                tokio::time::sleep(time).await;
            }
            if let Err(e) = punch_now(puncher, src_ip, dest_ip, punch_info, packet_crypto).await {
                log::warn!("punch send error {:?}", e);
            }
        });
        Ok(())
    }
}
async fn punch_now(
    puncher: Puncher,
    src_ip: Ipv4Addr,
    dest_ip: Ipv4Addr,
    nat_info: PunchInfo,
    packet_crypto: PacketCrypto,
) -> anyhow::Result<()> {
    let mut packet = NetPacket::new(TransmissionBytes::zeroed_size(
        HEAD_LENGTH + 8,
        packet_crypto.encrypt_reserve(),
    ))?;
    packet.set_msg_type(MsgType::PunchReq);
    packet.set_ttl(1);
    packet.set_src_id(src_ip.into());
    packet.set_dest_id(dest_ip.into());
    packet.set_payload(&crate::utils::time::now_ts_ms().to_be_bytes())?;
    packet_crypto.encrypt_in_place(&mut packet)?;
    let buf = packet.buffer();
    let punch_info = rust_p2p_core::punch::PunchInfo::new(PunchModel::all(), nat_info.nat_info);
    puncher.punch_now(Some(buf), buf, punch_info).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::PunchRequestQueue;
    use std::net::Ipv4Addr;

    #[test]
    fn priority_queue_deduplicates_and_cools_down_target_requests() {
        let (queue, mut receiver) = PunchRequestQueue::new();
        let target = Ipv4Addr::new(10, 0, 0, 2);

        assert!(queue.request(target));
        assert!(!queue.request(target));
        assert_eq!(receiver.try_recv().unwrap(), target);

        queue.complete(target);
        assert!(!queue.request(target));
    }
}

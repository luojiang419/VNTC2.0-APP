use crate::crypto::PacketCrypto;
use crate::protocol::ip_packet_protocol::NetPacket;
use crate::protocol::transmission::TransmissionBytes;
use crate::tunnel_core::p2p::route_table::{Route, RouteTable};
use crate::tunnel_core::p2p::transport::punch::PunchRequestQueue;
use bytes::Bytes;
use parking_lot::Mutex;
use rust_p2p_core::route::RouteKey;
use rust_p2p_core::tunnel::SocketManager;
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::time::{Duration, Instant};

const FAILED_ROUTE_COOLDOWN: Duration = Duration::from_secs(3);

#[derive(Clone)]
pub(crate) struct P2pOutbound {
    manager: SocketManager,
    route_table: RouteTable,
    packet_crypto: PacketCrypto,
    priority_punch_queue: PunchRequestQueue,
    route_circuit_breaker: Arc<Mutex<RouteCircuitBreaker>>,
}
impl P2pOutbound {
    pub fn new(
        manager: SocketManager,
        route_table: RouteTable,
        packet_crypto: PacketCrypto,
        priority_punch_queue: PunchRequestQueue,
    ) -> Self {
        Self {
            manager,
            route_table,
            packet_crypto,
            priority_punch_queue,
            route_circuit_breaker: Arc::new(Mutex::new(RouteCircuitBreaker::default())),
        }
    }
    pub fn encrypt_reserve(&self) -> usize {
        self.packet_crypto.encrypt_reserve()
    }
    // pub async fn send_raw(&self, buf: NetPacket<Bytes>) -> anyhow::Result<()> {
    //     let dest_id = Ipv4Addr::from(buf.dest_id());
    //     let route = self.route_table.get_route_by_id(&dest_id)?;
    //     self.manager
    //         .send_to(buf.into_buffer(), &route.route_key())
    //         .await?;
    //     Ok(())
    // }
    // pub async fn send(&self, mut buf: NetPacket<TransmissionBytes>) -> anyhow::Result<()> {
    //     let dest_id = Ipv4Addr::from(buf.dest_id());
    //     let route = self.route_table.get_route_by_id(&dest_id)?;
    //     self.packet_crypto.encrypt_in_place(&mut buf)?;
    //     self.manager
    //         .send_to(buf.into_buffer().into_bytes().freeze(), &route.route_key())
    //         .await?;
    //     Ok(())
    // }
    pub async fn send_raw_to(
        &self,
        buf: NetPacket<Bytes>,
        route_key: &RouteKey,
    ) -> anyhow::Result<()> {
        self.manager.send_to(buf.into_buffer(), route_key).await?;
        Ok(())
    }
    pub async fn send_to(
        &self,
        mut buf: NetPacket<TransmissionBytes>,
        route_key: &RouteKey,
    ) -> anyhow::Result<()> {
        self.packet_crypto.encrypt_in_place(&mut buf)?;
        self.manager
            .send_to(buf.into_buffer().into_bytes().freeze(), route_key)
            .await?;
        Ok(())
    }
    pub fn get_route_by_id(&self, id: &Ipv4Addr) -> Option<Route> {
        self.route_table.get_route_by_id(id).ok()
    }

    pub fn get_outbound_route_by_id(&self, id: &Ipv4Addr) -> Option<Route> {
        if self.route_circuit_breaker.lock().is_open(id) {
            return None;
        }
        self.get_route_by_id(id)
    }
    pub fn get_p2p_route_by_id(&self, id: &Ipv4Addr) -> Option<Route> {
        self.route_table
            .get_route_by_id(id)
            .ok()
            .filter(|v| v.is_direct())
    }
    pub fn exists_route_by_id(&self, id: &Ipv4Addr) -> bool {
        self.route_table.exists(id)
    }

    pub fn request_punch(&self, id: Ipv4Addr) {
        if self.route_circuit_breaker.lock().is_open(&id) || self.route_table.need_punch(&id) {
            _ = self.priority_punch_queue.request(id);
        }
    }

    pub fn mark_route_failed(&self, id: Ipv4Addr) {
        self.route_circuit_breaker.lock().open(id);
        self.request_punch(id);
    }

    pub fn mark_route_healthy(&self, id: Ipv4Addr) {
        self.route_circuit_breaker.lock().close(&id);
    }

    // pub async fn send_to_id(
    //     &self,
    //     buf: NetPacket<TransmissionBytes>,
    //     id: &Ipv4Addr,
    // ) -> anyhow::Result<bool> {
    //     let Ok(route) = self.route_table.get_route_by_id(id) else {
    //         return Ok(false);
    //     };
    //     self.send_to(buf, &route.route_key()).await?;
    //     Ok(true)
    // }
    // pub fn try_send_to_id(
    //     &self,
    //     buf: NetPacket<TransmissionBytes>,
    //     id: &Ipv4Addr,
    // ) -> anyhow::Result<bool> {
    //     let Ok(route) = self.route_table.get_route_by_id(id) else {
    //         return Ok(false);
    //     };
    //     self.try_send_to(buf, &route.route_key())?;
    //     Ok(true)
    // }
    // pub fn try_send_to(
    //     &self,
    //     buf: NetPacket<TransmissionBytes>,
    //     route_key: &RouteKey,
    // ) -> anyhow::Result<()> {
    //     self.manager
    //         .try_send_to(buf.into_buffer().into_bytes(), route_key)?;
    //     Ok(())
    // }
    pub fn p2p_broadcast(
        &self,
        ips: &[Ipv4Addr],
        max: usize,
        buf: &NetPacket<Bytes>,
    ) -> Vec<Ipv4Addr> {
        let mut list = Vec::with_capacity(ips.len().min(max));

        for id in ips {
            let Some(route) = self.get_p2p_route_by_id(id) else {
                continue;
            };
            if self
                .manager
                .try_send_to(buf.source_buf().clone(), &route.route_key())
                .is_ok()
            {
                list.push(*id);
                if list.len() >= max {
                    break;
                }
            }
        }
        list
    }
}

#[derive(Default)]
struct RouteCircuitBreaker {
    blocked_until: HashMap<Ipv4Addr, Instant>,
}

impl RouteCircuitBreaker {
    fn is_open(&mut self, id: &Ipv4Addr) -> bool {
        let now = Instant::now();
        self.blocked_until.retain(|_, until| *until > now);
        self.blocked_until.contains_key(id)
    }

    fn open(&mut self, id: Ipv4Addr) {
        self.blocked_until
            .insert(id, Instant::now() + FAILED_ROUTE_COOLDOWN);
    }

    fn close(&mut self, id: &Ipv4Addr) {
        self.blocked_until.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::RouteCircuitBreaker;
    use std::net::Ipv4Addr;

    #[test]
    fn route_circuit_breaker_opens_and_recovers_after_a_healthy_route() {
        let target = Ipv4Addr::new(10, 0, 0, 2);
        let mut breaker = RouteCircuitBreaker::default();

        assert!(!breaker.is_open(&target));
        breaker.open(target);
        assert!(breaker.is_open(&target));
        breaker.close(&target);
        assert!(!breaker.is_open(&target));
    }
}

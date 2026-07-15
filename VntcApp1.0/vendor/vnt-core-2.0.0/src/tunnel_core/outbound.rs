use crate::compression::PacketCompression;
use crate::context::{NetworkAddr, ServerInfoCollection, SharedNetworkAddr, TrafficStats};
use crate::crypto::PacketCrypto;
use crate::fec::FecEncoder;
use crate::nat::SubnetExternalRoute;
use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use crate::protocol::transmission::TransmissionBytes;
use crate::tunnel_core::p2p::outbound::P2pOutbound;
use crate::tunnel_core::server::outbound::ServerOutbound;
use anyhow::bail;
use bytes::Bytes;
use pnet_packet::ipv4::Ipv4Packet;
use std::net::Ipv4Addr;

#[derive(Clone)]
pub(crate) struct BasicOutbound {
    server_outbound: ServerOutbound,
    p2p_outbound: Option<P2pOutbound>,
    packet_crypto: PacketCrypto,
}

impl BasicOutbound {
    pub fn new(
        server_outbound: ServerOutbound,
        p2p_outbound: Option<P2pOutbound>,
        packet_crypto: PacketCrypto,
    ) -> Self {
        Self {
            server_outbound,
            p2p_outbound,
            packet_crypto,
        }
    }

    /// 获取加密保留空间大小
    pub fn encrypt_reserve(&self) -> usize {
        self.packet_crypto.encrypt_reserve()
    }

    /// 加密数据包
    pub fn encrypt_in_place(
        &self,
        packet: &mut NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        Ok(self.packet_crypto.encrypt_in_place(packet)?)
    }

    /// 发送原始数据包到指定目标（通过P2P或服务器）
    pub async fn send_raw(
        &self,
        dest: Ipv4Addr,
        packet: NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        let packet = packet.into_bytes();
        if let Some(p2p) = self.p2p_outbound.as_ref()
            && let Some(route) = p2p.get_outbound_route_by_id(&dest)
        {
            let fallback_packet = packet.source_buf().clone();
            match p2p.send_raw_to(packet, &route.route_key()).await {
                Ok(()) => {
                    p2p.mark_route_healthy(dest);
                    return Ok(());
                }
                Err(error) => {
                    p2p.mark_route_failed(dest);
                    log::warn!(
                        "P2P route send failed for {dest}, falling back to relay: {error:?}"
                    );
                    return self
                        .server_outbound
                        .send_raw(dest, NetPacket::new(fallback_packet)?)
                        .await;
                }
            }
        }
        if let Some(p2p) = self.p2p_outbound.as_ref() {
            p2p.request_punch(dest);
        }
        self.server_outbound.send_raw(dest, packet).await?;
        Ok(())
    }

    /// 发送到默认服务器
    pub async fn send_default_raw(
        &self,
        packet: NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        let bytes = packet.into_buffer().into_bytes().freeze();
        self.server_outbound
            .send_default_raw(NetPacket::new(bytes)?)
            .await
    }

    /// 仅通过服务器发送原始数据包，不触发 P2P 打洞或回退。
    pub async fn send_server_raw(
        &self,
        dest: Ipv4Addr,
        packet: NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        self.server_outbound
            .send_raw(dest, packet.into_bytes())
            .await
    }

    /// 广播发送
    pub async fn send_raw_broadcast(
        &self,
        exclude_ips: Option<Vec<Ipv4Addr>>,
        packet: NetPacket<Bytes>,
    ) -> anyhow::Result<()> {
        self.server_outbound
            .send_raw_broadcast(exclude_ips, packet)
            .await
    }

    /// 检查是否存在到目标的路由
    pub fn exists_route(&self, dest: &Ipv4Addr) -> bool {
        if let Some(p2p) = self.p2p_outbound.as_ref()
            && p2p.exists_route_by_id(dest)
        {
            return true;
        }
        self.server_outbound.exists_route(dest)
    }

    /// P2P广播（内部转换类型）
    pub fn p2p_broadcast_transmission(
        &self,
        list: &[Ipv4Addr],
        max_count: usize,
        packet: &NetPacket<Bytes>,
    ) -> Option<Vec<Ipv4Addr>> {
        if let Some(p2p) = self.p2p_outbound.as_ref() {
            let vec = p2p.p2p_broadcast(list, max_count, packet);
            if vec.is_empty() { None } else { Some(vec) }
        } else {
            None
        }
    }

    /// 发送加密后的数据包
    pub async fn send_encrypted_packet(
        &self,
        dest: Ipv4Addr,
        mut packet: NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        // 加密
        self.packet_crypto.encrypt_in_place(&mut packet)?;

        // 发送
        if let Some(p2p) = self.p2p_outbound.as_ref()
            && let Some(route) = p2p.get_outbound_route_by_id(&dest)
        {
            let bytes = packet.into_buffer().into_bytes().freeze();
            let fallback_packet = bytes.clone();
            match p2p
                .send_raw_to(NetPacket::new(bytes)?, &route.route_key())
                .await
            {
                Ok(()) => {
                    p2p.mark_route_healthy(dest);
                    return Ok(());
                }
                Err(error) => {
                    p2p.mark_route_failed(dest);
                    log::warn!(
                        "P2P route send failed for {dest}, falling back to relay: {error:?}"
                    );
                    return self
                        .server_outbound
                        .send_raw(dest, NetPacket::new(fallback_packet)?)
                        .await;
                }
            }
        }
        if let Some(p2p) = self.p2p_outbound.as_ref() {
            p2p.request_punch(dest);
        }
        let bytes = packet.into_buffer().into_bytes().freeze();
        self.server_outbound
            .send_raw(dest, NetPacket::new(bytes)?)
            .await?;
        Ok(())
    }
}

#[derive(Clone)]
pub(crate) struct HybridOutbound {
    network: SharedNetworkAddr,
    server_info: ServerInfoCollection,
    traffic_stats: TrafficStats,
    basic_outbound: BasicOutbound,
    packet_compression: PacketCompression,
    external_route: SubnetExternalRoute,
    fec_encoder: Option<FecEncoder>,
    wireguard_p2p: Option<crate::wireguard_p2p::WireGuardP2pHandle>,
}
impl HybridOutbound {
    pub fn new(
        network: SharedNetworkAddr,
        server_info: ServerInfoCollection,
        traffic_stats: TrafficStats,
        basic_outbound: BasicOutbound,
        packet_compression: PacketCompression,
        external_route: SubnetExternalRoute,
        fec_encoder: Option<FecEncoder>,
        wireguard_p2p: Option<crate::wireguard_p2p::WireGuardP2pHandle>,
    ) -> Self {
        Self {
            network,
            server_info,
            traffic_stats,
            basic_outbound,
            packet_compression,
            external_route,
            fec_encoder,
            wireguard_p2p,
        }
    }
    pub async fn outbound_raw(
        &self,
        dest: Ipv4Addr,
        mut packet: NetPacket<TransmissionBytes>,
    ) -> anyhow::Result<()> {
        if packet.src_id() == 0 {
            if let Some(ip) = self.network.ip() {
                packet.set_src_id(ip.into());
            } else {
                bail!("Not src ip")
            }
        }

        let len = packet.buffer().len() as u64;

        if let Some(fec_encoder) = &self.fec_encoder {
            packet = fec_encoder.encode(packet)?;
        }

        self.basic_outbound.send_raw(dest, packet).await?;
        self.traffic_stats.record_tx(dest, len);
        Ok(())
    }
    pub async fn ipv4_outbound_common(&self, data: TransmissionBytes) -> anyhow::Result<()> {
        let Some(net) = self.network.get() else {
            bail!("Not src ip")
        };
        self.ipv4_outbound(net, data).await
    }
    pub fn is_wireguard_destination(&self, dest: &Ipv4Addr) -> bool {
        self.server_info.is_wireguard_client(dest)
    }
    pub async fn ipv4_outbound(
        &self,
        net: NetworkAddr,
        mut data: TransmissionBytes,
    ) -> anyhow::Result<()> {
        let Some(ipv4) = Ipv4Packet::new(data.as_ref()) else {
            return Ok(());
        };
        let mut dest = ipv4.get_destination();
        let len = data.len() as u64;

        if net.network().contains(&dest) && self.server_info.is_wireguard_client(&dest) {
            if crate::wireguard_bridge::validate_inner_ipv4(data.as_ref(), net.ip, Some(dest), net)
                .is_none()
            {
                return Ok(());
            }
            if let Some(wireguard_p2p) = &self.wireguard_p2p
                && wireguard_p2p.send_ipv4(dest, data.as_ref()).await
            {
                self.traffic_stats.record_tx(dest, len);
                return Ok(());
            }
            data.retreat_head(HEAD_LENGTH)?;
            let mut packet = NetPacket::new(data)?;
            packet.set_msg_type(MsgType::WireGuardRelay);
            packet.set_src_id(net.ip.into());
            packet.set_dest_id(dest.into());
            packet.set_ttl(5);
            self.basic_outbound.send_server_raw(dest, packet).await?;
            self.traffic_stats.record_tx(dest, len);
            return Ok(());
        }

        data.retreat_head(HEAD_LENGTH)?;
        let mut packet = NetPacket::new(data)?;
        packet.set_msg_type(MsgType::Turn);
        packet.set_src_id(net.ip.into());
        packet.set_ttl(5);
        // 路由
        if !net.network().contains(&dest) {
            if let Some(v) = self.external_route.route(&dest) {
                dest = v;
            } else {
                return Ok(());
            }
        }
        packet.set_dest_id(dest.into());

        packet = self
            .packet_compression
            .compress(packet, self.basic_outbound.encrypt_reserve())?;

        if let Some(fec_encoder) = &self.fec_encoder {
            packet = fec_encoder.encode(packet)?;
        }

        // 发送
        self.basic_outbound
            .send_encrypted_packet(dest, packet)
            .await?;
        self.traffic_stats.record_tx(dest, len);
        Ok(())
    }
    pub async fn ipv4_gateway_outbound(
        &self,
        net: NetworkAddr,
        mut data: TransmissionBytes,
    ) -> anyhow::Result<()> {
        data.retreat_head(HEAD_LENGTH)?;
        let mut packet = NetPacket::new(data)?;
        packet.set_msg_type(MsgType::Turn);
        packet.set_src_id(net.ip.into());
        packet.set_dest_id(net.gateway.into());
        packet.set_ttl(5);
        packet.set_gateway_flag(true);
        self.basic_outbound.send_default_raw(packet).await?;
        Ok(())
    }
    pub async fn ipv4_broadcast_outbound(
        &self,
        net: NetworkAddr,
        mut data: TransmissionBytes,
    ) -> anyhow::Result<()> {
        data.retreat_head(HEAD_LENGTH)?;
        let mut packet = NetPacket::new(data)?;
        packet.set_msg_type(MsgType::Broadcast);
        packet.set_src_id(net.ip.into());
        packet.set_dest_id(Ipv4Addr::BROADCAST.into());
        packet.set_ttl(5);
        let mut packet = self
            .packet_compression
            .compress(packet, self.basic_outbound.encrypt_reserve())?;
        self.basic_outbound.encrypt_in_place(&mut packet)?;
        let packet_bytes = packet.into_bytes();
        let list = self.server_info.client_online_ips();
        let exclude_ips = self
            .basic_outbound
            .p2p_broadcast_transmission(&list, 16, &packet_bytes);
        if let Some(exclude_ips) = &exclude_ips
            && exclude_ips.len() == list.len()
        {
            return Ok(());
        }

        self.basic_outbound
            .send_raw_broadcast(exclude_ips, packet_bytes)
            .await
    }
    #[allow(dead_code)]
    pub fn has_route(&self, dest: &Ipv4Addr) -> bool {
        self.basic_outbound.exists_route(dest)
    }
}

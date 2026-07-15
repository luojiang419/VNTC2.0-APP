use crate::protocol::control_message::proto::wire_guard_p2p_control::Payload;
use crate::protocol::control_message::proto::{
    WireGuardP2pAgentRequest, WireGuardP2pAgentResponse, WireGuardP2pControl, WireGuardP2pOffer,
    WireGuardP2pRevoke, WireGuardP2pStatus,
};
use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use crate::server::network_state_provider::{LocalDeliveryResult, NetworkState};
use crate::server::wireguard_bridge::RelayOrigin;
use bytes::BytesMut;
use pnet_packet::Packet;
use pnet_packet::ip::IpNextHeaderProtocols;
use pnet_packet::ipv4::{Ipv4Packet, MutableIpv4Packet};
use pnet_packet::udp::{MutableUdpPacket, UdpPacket};
use prost::Message;
use std::net::Ipv4Addr;
use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const AGENT_CONTROL_PORT: u16 = 51_821;
const IPV4_HEADER_LEN: usize = 20;
const UDP_HEADER_LEN: usize = 8;
const MAX_CONTROL_PAYLOAD: usize = 1024;
pub(crate) const LEASE_DURATION_MS: u64 = 60_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AgentControlRequest {
    pub(crate) source_port: u16,
    pub(crate) target_ip: Ipv4Addr,
    pub(crate) request_id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GrantedLease {
    pub(crate) target_ip: Ipv4Addr,
    pub(crate) lease_id: u64,
}

pub(crate) struct ResolvedAgentRequest {
    pub(crate) response: Vec<u8>,
    pub(crate) granted: Option<GrantedLease>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AgentControlParse {
    NotControl,
    Invalid,
    Request(AgentControlRequest),
}

pub(crate) fn parse_agent_control(
    packet: &[u8],
    expected_source: Ipv4Addr,
    gateway: Ipv4Addr,
) -> AgentControlParse {
    let Some(ipv4) = Ipv4Packet::new(packet) else {
        return AgentControlParse::NotControl;
    };
    if ipv4.get_version() != 4
        || ipv4.get_source() != expected_source
        || ipv4.get_destination() != gateway
        || ipv4.get_next_level_protocol() != IpNextHeaderProtocols::Udp
    {
        return AgentControlParse::NotControl;
    }

    let header_len = usize::from(ipv4.get_header_length()) * 4;
    let total_len = usize::from(ipv4.get_total_length());
    if header_len < IPV4_HEADER_LEN
        || total_len != packet.len()
        || packet.len() < header_len + UDP_HEADER_LEN
        || u16::from_be_bytes([packet[6], packet[7]]) & 0x3fff != 0
    {
        return AgentControlParse::Invalid;
    }

    let Some(udp) = UdpPacket::new(&packet[header_len..]) else {
        return AgentControlParse::Invalid;
    };
    if udp.get_destination() != AGENT_CONTROL_PORT {
        return AgentControlParse::NotControl;
    }
    if usize::from(udp.get_length()) != packet.len() - header_len
        || udp.payload().is_empty()
        || udp.payload().len() > MAX_CONTROL_PAYLOAD
    {
        return AgentControlParse::Invalid;
    }

    let Ok(request) = WireGuardP2pAgentRequest::decode(udp.payload()) else {
        return AgentControlParse::Invalid;
    };
    let target_ip = Ipv4Addr::from(request.target_ip);
    if request.request_id == 0 || target_ip.is_unspecified() || target_ip.is_multicast() {
        return AgentControlParse::Invalid;
    }

    AgentControlParse::Request(AgentControlRequest {
        source_port: udp.get_source(),
        target_ip,
        request_id: request.request_id,
    })
}

pub(crate) fn build_agent_response(
    gateway: Ipv4Addr,
    destination: Ipv4Addr,
    destination_port: u16,
    payload: &[u8],
) -> Option<Vec<u8>> {
    if destination_port == 0 || payload.is_empty() || payload.len() > MAX_CONTROL_PAYLOAD {
        return None;
    }
    let total_len = IPV4_HEADER_LEN + UDP_HEADER_LEN + payload.len();
    let total_len_u16 = u16::try_from(total_len).ok()?;
    let udp_len = u16::try_from(UDP_HEADER_LEN + payload.len()).ok()?;
    let mut buffer = vec![0; total_len];

    {
        let mut ipv4 = MutableIpv4Packet::new(&mut buffer)?;
        ipv4.set_version(4);
        ipv4.set_header_length(5);
        ipv4.set_total_length(total_len_u16);
        ipv4.set_ttl(64);
        ipv4.set_next_level_protocol(IpNextHeaderProtocols::Udp);
        ipv4.set_source(gateway);
        ipv4.set_destination(destination);
    }
    {
        let mut udp = MutableUdpPacket::new(&mut buffer[IPV4_HEADER_LEN..])?;
        udp.set_source(AGENT_CONTROL_PORT);
        udp.set_destination(destination_port);
        udp.set_length(udp_len);
        udp.set_payload(payload);
        let checksum = pnet_packet::udp::ipv4_checksum(&udp.to_immutable(), &gateway, &destination);
        udp.set_checksum(checksum);
    }
    let mut ipv4 = MutableIpv4Packet::new(&mut buffer)?;
    ipv4.set_checksum(pnet_packet::ipv4::checksum(&ipv4.to_immutable()));
    Some(buffer)
}

pub(crate) fn resolve_agent_request(
    network_state: &NetworkState,
    peer_ip: Ipv4Addr,
    peer_public_key: [u8; 32],
    peer_endpoint: SocketAddr,
    request: AgentControlRequest,
) -> ResolvedAgentRequest {
    let mut response = WireGuardP2pAgentResponse {
        request_id: request.request_id,
        status: WireGuardP2pStatus::WireguardP2pNotFound as i32,
        target_ip: request.target_ip.into(),
        target_public_key: Vec::new(),
        target_endpoint: String::new(),
        lease_id: 0,
        expires_at_unix_ms: 0,
    };

    if request.target_ip == peer_ip
        || request.target_ip == network_state.gateway()
        || !network_state.network().contains(&request.target_ip)
    {
        response.status = WireGuardP2pStatus::WireguardP2pRejected as i32;
        return resolution(response, None);
    }

    let Some(target) = network_state.wireguard_p2p_endpoint(request.target_ip) else {
        response.status = WireGuardP2pStatus::WireguardP2pNotCapable as i32;
        return resolution(response, None);
    };

    let lease_id = loop {
        let candidate = rand::random::<u64>();
        if candidate != 0 {
            break candidate;
        }
    };
    let expires_at_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .saturating_add(u128::from(LEASE_DURATION_MS))
        .min(u128::from(u64::MAX)) as u64;
    let offer = WireGuardP2pControl {
        payload: Some(Payload::Offer(WireGuardP2pOffer {
            lease_id,
            expires_at_unix_ms,
            peer_ip: peer_ip.into(),
            peer_public_key: peer_public_key.to_vec(),
            peer_endpoint: peer_endpoint.to_string(),
        })),
    }
    .encode_to_vec();
    let mut bytes = BytesMut::zeroed(HEAD_LENGTH + offer.len());
    let delivered = if let Ok(mut packet) = NetPacket::new(&mut bytes) {
        packet.set_msg_type(MsgType::WireGuardP2pControl);
        packet.set_gateway_flag(true);
        packet.set_ttl(1);
        packet.set_src_id(network_state.gateway().into());
        packet.set_dest_id(request.target_ip.into());
        if packet.set_payload(&offer).is_ok() {
            network_state.try_deliver(request.target_ip, bytes.freeze(), RelayOrigin::WireGuard)
                == LocalDeliveryResult::Delivered
        } else {
            false
        }
    } else {
        false
    };
    if !delivered {
        response.status = WireGuardP2pStatus::WireguardP2pBusy as i32;
        return resolution(response, None);
    }

    response.status = WireGuardP2pStatus::WireguardP2pOk as i32;
    response.target_public_key = target.public_key.to_vec();
    response.target_endpoint = target.endpoint.to_string();
    response.lease_id = lease_id;
    response.expires_at_unix_ms = expires_at_unix_ms;
    resolution(
        response,
        Some(GrantedLease {
            target_ip: request.target_ip,
            lease_id,
        }),
    )
}

fn resolution(
    response: WireGuardP2pAgentResponse,
    granted: Option<GrantedLease>,
) -> ResolvedAgentRequest {
    ResolvedAgentRequest {
        response: response.encode_to_vec(),
        granted,
    }
}

pub(crate) fn revoke_lease(network_state: &NetworkState, target_ip: Ipv4Addr, lease_id: u64) {
    let control = WireGuardP2pControl {
        payload: Some(Payload::Revoke(WireGuardP2pRevoke { lease_id })),
    }
    .encode_to_vec();
    let mut bytes = BytesMut::zeroed(HEAD_LENGTH + control.len());
    if let Ok(mut packet) = NetPacket::new(&mut bytes) {
        packet.set_msg_type(MsgType::WireGuardP2pControl);
        packet.set_gateway_flag(true);
        packet.set_ttl(1);
        packet.set_src_id(network_state.gateway().into());
        packet.set_dest_id(target_ip.into());
        if packet.set_payload(&control).is_ok() {
            let _ = network_state.try_deliver(target_ip, bytes.freeze(), RelayOrigin::WireGuard);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::control_message::proto::WireGuardP2pAgentRequest;

    const PEER: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 2);
    const GATEWAY: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 1);
    const TARGET: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 3);

    fn request_packet() -> Vec<u8> {
        let payload = WireGuardP2pAgentRequest {
            target_ip: TARGET.into(),
            request_id: 7,
        }
        .encode_to_vec();
        build_agent_response(PEER, GATEWAY, AGENT_CONTROL_PORT, &payload).unwrap()
    }

    #[test]
    fn accepts_only_authenticated_peer_to_gateway_udp_control() {
        let packet = request_packet();
        assert_eq!(
            parse_agent_control(&packet, PEER, GATEWAY),
            AgentControlParse::Request(AgentControlRequest {
                source_port: AGENT_CONTROL_PORT,
                target_ip: TARGET,
                request_id: 7,
            })
        );
        assert_eq!(
            parse_agent_control(&packet, Ipv4Addr::new(10, 26, 0, 9), GATEWAY),
            AgentControlParse::NotControl
        );
    }

    #[test]
    fn rejects_fragments_malformed_lengths_and_zero_request_ids() {
        let mut fragmented = request_packet();
        fragmented[6..8].copy_from_slice(&0x2000_u16.to_be_bytes());
        assert_eq!(
            parse_agent_control(&fragmented, PEER, GATEWAY),
            AgentControlParse::Invalid
        );

        let mut wrong_length = request_packet();
        wrong_length[2..4].copy_from_slice(&20_u16.to_be_bytes());
        assert_eq!(
            parse_agent_control(&wrong_length, PEER, GATEWAY),
            AgentControlParse::Invalid
        );

        let payload = WireGuardP2pAgentRequest {
            target_ip: TARGET.into(),
            request_id: 0,
        }
        .encode_to_vec();
        let zero_id = build_agent_response(PEER, GATEWAY, AGENT_CONTROL_PORT, &payload).unwrap();
        assert_eq!(
            parse_agent_control(&zero_id, PEER, GATEWAY),
            AgentControlParse::Invalid
        );
    }
}

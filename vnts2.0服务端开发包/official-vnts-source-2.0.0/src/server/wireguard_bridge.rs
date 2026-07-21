use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use bytes::{Bytes, BytesMut};
use ipnet::Ipv4Net;
use pnet_packet::Packet;
use pnet_packet::icmp::{self, IcmpPacket, IcmpTypes, MutableIcmpPacket};
use pnet_packet::ip::IpNextHeaderProtocols;
use pnet_packet::ipv4::{self, Ipv4Packet, MutableIpv4Packet};
use std::net::Ipv4Addr;

pub(crate) const MAX_INNER_IPV4_PACKET_SIZE: usize = 1420;
const RELAY_TTL: u8 = 5;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RelayOrigin {
    Vnt,
    WireGuard,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Ipv4Route {
    pub(crate) source: Ipv4Addr,
    pub(crate) destination: Ipv4Addr,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RelayValidationError {
    InvalidMessageType,
    InvalidFlags,
    Expired,
    TooShort,
    TooLarge,
    InvalidVersion,
    InvalidHeaderLength,
    InvalidTotalLength,
    SourceMismatch,
    DestinationMismatch,
    InvalidDestination,
    DestinationOutsideNetwork,
    InvalidControlPacket,
}

fn parse_unbound_inner_ipv4(packet: &[u8]) -> Result<(Ipv4Route, usize), RelayValidationError> {
    if packet.len() < 20 {
        return Err(RelayValidationError::TooShort);
    }
    if packet.len() > MAX_INNER_IPV4_PACKET_SIZE {
        return Err(RelayValidationError::TooLarge);
    }

    let ipv4 = Ipv4Packet::new(packet).ok_or(RelayValidationError::TooShort)?;
    if ipv4.get_version() != 4 {
        return Err(RelayValidationError::InvalidVersion);
    }

    let header_length = usize::from(ipv4.get_header_length()) * 4;
    if header_length < 20 || header_length > packet.len() {
        return Err(RelayValidationError::InvalidHeaderLength);
    }
    if usize::from(ipv4.get_total_length()) != packet.len() {
        return Err(RelayValidationError::InvalidTotalLength);
    }

    Ok((
        Ipv4Route {
            source: ipv4.get_source(),
            destination: ipv4.get_destination(),
        },
        header_length,
    ))
}

fn parse_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
) -> Result<(Ipv4Route, usize), RelayValidationError> {
    let parsed = parse_unbound_inner_ipv4(packet)?;
    if parsed.0.source != expected_source {
        return Err(RelayValidationError::SourceMismatch);
    }
    Ok(parsed)
}

pub(crate) fn validate_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
    network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
    let (route, _) = parse_inner_ipv4(packet, expected_source)?;
    let destination = route.destination;
    if destination == Ipv4Addr::BROADCAST
        || destination.is_multicast()
        || destination == network.network()
        || destination == network.broadcast()
        || destination == gateway
    {
        return Err(RelayValidationError::InvalidDestination);
    }
    if !network.contains(&destination) {
        return Err(RelayValidationError::DestinationOutsideNetwork);
    }

    Ok(route)
}

pub(crate) fn validate_broadcast_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
    network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
    let (route, _) = parse_inner_ipv4(packet, expected_source)?;
    if route.source == gateway || !network.contains(&route.source) {
        return Err(RelayValidationError::SourceMismatch);
    }
    if route.destination != Ipv4Addr::BROADCAST
        && route.destination != network.broadcast()
        && !route.destination.is_multicast()
    {
        return Err(RelayValidationError::InvalidDestination);
    }
    Ok(route)
}

pub(crate) fn validate_subnet_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
    virtual_network: Ipv4Net,
    gateway: Ipv4Addr,
    lan_network: Ipv4Net,
) -> Result<Ipv4Route, RelayValidationError> {
    let (route, _) = parse_inner_ipv4(packet, expected_source)?;
    if !virtual_network.contains(&route.source)
        || route.source == virtual_network.network()
        || route.source == virtual_network.broadcast()
        || route.source == gateway
    {
        return Err(RelayValidationError::SourceMismatch);
    }
    if route.destination.is_unspecified()
        || route.destination == Ipv4Addr::BROADCAST
        || route.destination.is_multicast()
        || virtual_network.contains(&route.destination)
    {
        return Err(RelayValidationError::InvalidDestination);
    }
    if !lan_network.contains(&route.destination) {
        return Err(RelayValidationError::DestinationOutsideNetwork);
    }
    Ok(route)
}

pub(crate) fn build_gateway_echo_reply(
    packet: &[u8],
    expected_source: Ipv4Addr,
    gateway: Ipv4Addr,
) -> Result<Option<Vec<u8>>, RelayValidationError> {
    let (route, header_length) = parse_inner_ipv4(packet, expected_source)?;
    if route.destination != gateway {
        return Ok(None);
    }

    let ipv4 = Ipv4Packet::new(packet).ok_or(RelayValidationError::TooShort)?;
    if ipv4.get_next_level_protocol() != IpNextHeaderProtocols::Icmp {
        return Ok(None);
    }
    if ipv4.get_fragment_offset() != 0 || ipv4.get_flags() & 1 != 0 {
        return Err(RelayValidationError::InvalidControlPacket);
    }
    let icmp = IcmpPacket::new(&packet[header_length..])
        .ok_or(RelayValidationError::InvalidControlPacket)?;
    if icmp.get_icmp_type() != IcmpTypes::EchoRequest || icmp.packet().len() < 8 {
        return Ok(None);
    }

    let mut reply = packet.to_vec();
    {
        let mut reply_icmp = MutableIcmpPacket::new(&mut reply[header_length..])
            .ok_or(RelayValidationError::InvalidControlPacket)?;
        reply_icmp.set_icmp_type(IcmpTypes::EchoReply);
        reply_icmp.set_checksum(0);
    }
    let icmp_checksum = icmp::checksum(
        &IcmpPacket::new(&reply[header_length..])
            .ok_or(RelayValidationError::InvalidControlPacket)?,
    );
    MutableIcmpPacket::new(&mut reply[header_length..])
        .ok_or(RelayValidationError::InvalidControlPacket)?
        .set_checksum(icmp_checksum);

    {
        let mut reply_ipv4 =
            MutableIpv4Packet::new(&mut reply).ok_or(RelayValidationError::InvalidControlPacket)?;
        reply_ipv4.set_source(gateway);
        reply_ipv4.set_destination(expected_source);
        reply_ipv4.set_checksum(0);
    }
    let ipv4_checksum =
        ipv4::checksum(&Ipv4Packet::new(&reply).ok_or(RelayValidationError::InvalidControlPacket)?);
    MutableIpv4Packet::new(&mut reply)
        .ok_or(RelayValidationError::InvalidControlPacket)?
        .set_checksum(ipv4_checksum);
    Ok(Some(reply))
}

pub(crate) fn validate_vnt_relay<B: AsRef<[u8]>>(
    packet: &NetPacket<B>,
    expected_source: Ipv4Addr,
    network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
    if packet.msg_type().ok() != Some(MsgType::WireGuardRelay) {
        return Err(RelayValidationError::InvalidMessageType);
    }
    if packet.is_compressed() || packet.is_gateway() {
        return Err(RelayValidationError::InvalidFlags);
    }
    if packet.ttl() == 0 {
        return Err(RelayValidationError::Expired);
    }
    if Ipv4Addr::from(packet.src_id()) != expected_source {
        return Err(RelayValidationError::SourceMismatch);
    }

    let route = validate_inner_ipv4(packet.payload(), expected_source, network, gateway)?;
    if Ipv4Addr::from(packet.dest_id()) != route.destination {
        return Err(RelayValidationError::DestinationMismatch);
    }
    Ok(route)
}

pub(crate) fn validate_vnt_broadcast_relay<B: AsRef<[u8]>>(
    packet: &NetPacket<B>,
    expected_source: Ipv4Addr,
    network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
    if packet.msg_type().ok() != Some(MsgType::WireGuardBroadcastRelay) {
        return Err(RelayValidationError::InvalidMessageType);
    }
    if packet.is_compressed() || packet.is_gateway() {
        return Err(RelayValidationError::InvalidFlags);
    }
    if packet.ttl() == 0 {
        return Err(RelayValidationError::Expired);
    }
    if Ipv4Addr::from(packet.src_id()) != expected_source {
        return Err(RelayValidationError::SourceMismatch);
    }
    if Ipv4Addr::from(packet.dest_id()) != Ipv4Addr::BROADCAST {
        return Err(RelayValidationError::DestinationMismatch);
    }

    validate_broadcast_inner_ipv4(packet.payload(), expected_source, network, gateway)
}

pub(crate) fn validate_vnt_subnet_relay<B: AsRef<[u8]>>(
    packet: &NetPacket<B>,
    expected_vnt_gateway: Ipv4Addr,
    virtual_network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
    if packet.msg_type().ok() != Some(MsgType::WireGuardSubnetRelay) {
        return Err(RelayValidationError::InvalidMessageType);
    }
    if packet.is_compressed() || packet.is_gateway() {
        return Err(RelayValidationError::InvalidFlags);
    }
    if packet.ttl() == 0 {
        return Err(RelayValidationError::Expired);
    }
    if Ipv4Addr::from(packet.src_id()) != expected_vnt_gateway {
        return Err(RelayValidationError::SourceMismatch);
    }

    let target = Ipv4Addr::from(packet.dest_id());
    if !virtual_network.contains(&target)
        || target == virtual_network.network()
        || target == virtual_network.broadcast()
        || target == gateway
        || target == expected_vnt_gateway
    {
        return Err(RelayValidationError::InvalidDestination);
    }
    let (route, _) = parse_unbound_inner_ipv4(packet.payload())?;
    if route.destination != target {
        return Err(RelayValidationError::DestinationMismatch);
    }
    if route.source.is_unspecified()
        || route.source == Ipv4Addr::BROADCAST
        || route.source.is_multicast()
        || virtual_network.contains(&route.source)
    {
        return Err(RelayValidationError::SourceMismatch);
    }
    Ok(route)
}

pub(crate) fn build_wireguard_relay(ipv4: &[u8], route: Ipv4Route) -> Bytes {
    build_wireguard_envelope(
        MsgType::WireGuardRelay,
        ipv4,
        route.source,
        route.destination,
    )
}

pub(crate) fn build_wireguard_broadcast_relay(
    ipv4: &[u8],
    route: Ipv4Route,
    target: Ipv4Addr,
) -> Bytes {
    build_wireguard_envelope(MsgType::WireGuardBroadcastRelay, ipv4, route.source, target)
}

pub(crate) fn build_wireguard_subnet_relay(
    ipv4: &[u8],
    route: Ipv4Route,
    vnt_gateway: Ipv4Addr,
) -> Bytes {
    build_wireguard_envelope(
        MsgType::WireGuardSubnetRelay,
        ipv4,
        route.source,
        vnt_gateway,
    )
}

fn build_wireguard_envelope(
    message_type: MsgType,
    ipv4: &[u8],
    source: Ipv4Addr,
    destination: Ipv4Addr,
) -> Bytes {
    let mut buffer = BytesMut::zeroed(HEAD_LENGTH + ipv4.len());
    let mut packet = NetPacket::new(&mut buffer).expect("relay buffer includes a complete header");
    packet.set_msg_type(message_type);
    packet.set_ttl(RELAY_TTL);
    packet.set_src_id(source.into());
    packet.set_dest_id(destination.into());
    packet
        .set_payload(ipv4)
        .expect("relay buffer reserves the complete IPv4 payload");
    buffer.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NETWORK: Ipv4Net = Ipv4Net::new_assert(Ipv4Addr::new(10, 26, 0, 0), 24);
    const GATEWAY: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 1);
    const SOURCE: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 2);
    const DESTINATION: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 3);

    fn ipv4_packet(source: Ipv4Addr, destination: Ipv4Addr, length: usize) -> Vec<u8> {
        let mut packet = vec![0; length];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(length as u16).to_be_bytes());
        packet[8] = 64;
        packet[9] = 17;
        packet[12..16].copy_from_slice(&source.octets());
        packet[16..20].copy_from_slice(&destination.octets());
        packet
    }

    #[test]
    fn accepts_structurally_valid_unicast_and_existing_fragments() {
        let packet = ipv4_packet(SOURCE, DESTINATION, MAX_INNER_IPV4_PACKET_SIZE);
        assert_eq!(
            validate_inner_ipv4(&packet, SOURCE, NETWORK, GATEWAY),
            Ok(Ipv4Route {
                source: SOURCE,
                destination: DESTINATION,
            })
        );

        let mut fragment = ipv4_packet(SOURCE, DESTINATION, 100);
        fragment[6..8].copy_from_slice(&0x2000_u16.to_be_bytes());
        assert!(validate_inner_ipv4(&fragment, SOURCE, NETWORK, GATEWAY).is_ok());
    }

    #[test]
    fn rejects_malformed_spoofed_and_oversized_ipv4() {
        assert_eq!(
            validate_inner_ipv4(&[0; 19], SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::TooShort)
        );

        let oversized = ipv4_packet(SOURCE, DESTINATION, MAX_INNER_IPV4_PACKET_SIZE + 1);
        assert_eq!(
            validate_inner_ipv4(&oversized, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::TooLarge)
        );

        let spoofed = ipv4_packet(Ipv4Addr::new(10, 26, 0, 4), DESTINATION, 20);
        assert_eq!(
            validate_inner_ipv4(&spoofed, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::SourceMismatch)
        );

        let mut invalid_total_length = ipv4_packet(SOURCE, DESTINATION, 24);
        invalid_total_length[2..4].copy_from_slice(&20_u16.to_be_bytes());
        assert_eq!(
            validate_inner_ipv4(&invalid_total_length, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::InvalidTotalLength)
        );
    }

    #[test]
    fn rejects_gateway_broadcast_multicast_and_external_destinations() {
        for destination in [
            GATEWAY,
            NETWORK.network(),
            NETWORK.broadcast(),
            Ipv4Addr::BROADCAST,
            Ipv4Addr::new(224, 0, 0, 1),
        ] {
            let packet = ipv4_packet(SOURCE, destination, 20);
            assert_eq!(
                validate_inner_ipv4(&packet, SOURCE, NETWORK, GATEWAY),
                Err(RelayValidationError::InvalidDestination)
            );
        }

        let external = ipv4_packet(SOURCE, Ipv4Addr::new(10, 27, 0, 2), 20);
        assert_eq!(
            validate_inner_ipv4(&external, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::DestinationOutsideNetwork)
        );
    }

    #[test]
    fn gateway_echo_request_gets_a_checksummed_reply() {
        let mut request = ipv4_packet(SOURCE, GATEWAY, 28);
        request[9] = IpNextHeaderProtocols::Icmp.0;
        request[20] = IcmpTypes::EchoRequest.0;
        request[24..28].copy_from_slice(&[1, 2, 3, 4]);

        let reply = build_gateway_echo_reply(&request, SOURCE, GATEWAY)
            .unwrap()
            .expect("echo request must be answered");
        let ipv4 = Ipv4Packet::new(&reply).unwrap();
        assert_eq!(ipv4.get_source(), GATEWAY);
        assert_eq!(ipv4.get_destination(), SOURCE);
        assert_eq!(ipv4::checksum(&ipv4), ipv4.get_checksum());
        let icmp = IcmpPacket::new(ipv4.payload()).unwrap();
        assert_eq!(icmp.get_icmp_type(), IcmpTypes::EchoReply);
        assert_eq!(icmp::checksum(&icmp), icmp.get_checksum());

        request[9] = IpNextHeaderProtocols::Udp.0;
        assert_eq!(
            build_gateway_echo_reply(&request, SOURCE, GATEWAY),
            Ok(None)
        );
    }

    #[test]
    fn broadcast_relay_preserves_inner_destination_and_targets_one_endpoint() {
        for destination in [
            Ipv4Addr::BROADCAST,
            NETWORK.broadcast(),
            Ipv4Addr::new(224, 0, 0, 251),
        ] {
            let inner = ipv4_packet(SOURCE, destination, 20);
            let route = validate_broadcast_inner_ipv4(&inner, SOURCE, NETWORK, GATEWAY).unwrap();
            let relay = build_wireguard_broadcast_relay(&inner, route, DESTINATION);
            let packet = NetPacket::new(relay).unwrap();
            assert_eq!(packet.msg_type().unwrap(), MsgType::WireGuardBroadcastRelay);
            assert_eq!(Ipv4Addr::from(packet.src_id()), SOURCE);
            assert_eq!(Ipv4Addr::from(packet.dest_id()), DESTINATION);
            assert_eq!(
                Ipv4Packet::new(packet.payload()).unwrap().get_destination(),
                destination
            );
        }
    }

    #[test]
    fn vnt_broadcast_relay_requires_bound_source_and_plain_envelope() {
        let ipv4 = ipv4_packet(SOURCE, NETWORK.broadcast(), 20);
        let mut relay = BytesMut::zeroed(HEAD_LENGTH + ipv4.len());
        let mut packet = NetPacket::new(&mut relay).unwrap();
        packet.set_msg_type(MsgType::WireGuardBroadcastRelay);
        packet.set_ttl(RELAY_TTL);
        packet.set_src_id(SOURCE.into());
        packet.set_dest_id(Ipv4Addr::BROADCAST.into());
        packet.set_payload(&ipv4).unwrap();
        assert_eq!(
            validate_vnt_broadcast_relay(&packet, SOURCE, NETWORK, GATEWAY),
            Ok(Ipv4Route {
                source: SOURCE,
                destination: NETWORK.broadcast(),
            })
        );

        packet.set_src_id(DESTINATION.into());
        assert_eq!(
            validate_vnt_broadcast_relay(&packet, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::SourceMismatch)
        );
        packet.set_src_id(SOURCE.into());
        packet.set_compressed_flag(true);
        assert_eq!(
            validate_vnt_broadcast_relay(&packet, SOURCE, NETWORK, GATEWAY),
            Err(RelayValidationError::InvalidFlags)
        );
    }

    #[test]
    fn subnet_relay_preserves_lan_destination_and_targets_vnt_gateway() {
        let lan: Ipv4Net = "192.168.10.0/24".parse().unwrap();
        let destination = Ipv4Addr::new(192, 168, 10, 25);
        let inner = ipv4_packet(SOURCE, destination, 20);
        let route = validate_subnet_inner_ipv4(&inner, SOURCE, NETWORK, GATEWAY, lan).unwrap();
        let relay = build_wireguard_subnet_relay(&inner, route, DESTINATION);
        let packet = NetPacket::new(relay).unwrap();
        assert_eq!(packet.msg_type().unwrap(), MsgType::WireGuardSubnetRelay);
        assert_eq!(Ipv4Addr::from(packet.src_id()), SOURCE);
        assert_eq!(Ipv4Addr::from(packet.dest_id()), DESTINATION);
        assert_eq!(packet.payload(), inner);

        let outside = ipv4_packet(SOURCE, Ipv4Addr::new(192, 168, 11, 25), 20);
        assert_eq!(
            validate_subnet_inner_ipv4(&outside, SOURCE, NETWORK, GATEWAY, lan),
            Err(RelayValidationError::DestinationOutsideNetwork)
        );
        let virtual_destination = ipv4_packet(SOURCE, DESTINATION, 20);
        assert_eq!(
            validate_subnet_inner_ipv4(&virtual_destination, SOURCE, NETWORK, GATEWAY, lan),
            Err(RelayValidationError::InvalidDestination)
        );
    }

    #[test]
    fn vnt_subnet_reply_keeps_lan_source_and_binds_wireguard_destination() {
        let vnt_gateway = Ipv4Addr::new(10, 26, 0, 10);
        let wireguard_target = DESTINATION;
        let lan_source = Ipv4Addr::new(192, 168, 10, 25);
        let inner = ipv4_packet(lan_source, wireguard_target, 20);
        let mut relay = BytesMut::zeroed(HEAD_LENGTH + inner.len());
        let mut packet = NetPacket::new(&mut relay).unwrap();
        packet.set_msg_type(MsgType::WireGuardSubnetRelay);
        packet.set_ttl(RELAY_TTL);
        packet.set_src_id(vnt_gateway.into());
        packet.set_dest_id(wireguard_target.into());
        packet.set_payload(&inner).unwrap();
        assert_eq!(
            validate_vnt_subnet_relay(&packet, vnt_gateway, NETWORK, GATEWAY),
            Ok(Ipv4Route {
                source: lan_source,
                destination: wireguard_target,
            })
        );

        packet.set_dest_id(SOURCE.into());
        assert_eq!(
            validate_vnt_subnet_relay(&packet, vnt_gateway, NETWORK, GATEWAY),
            Err(RelayValidationError::DestinationMismatch)
        );
    }

    #[test]
    fn relay_envelope_requires_frozen_type_flags_ttl_and_matching_addresses() {
        let ipv4 = ipv4_packet(SOURCE, DESTINATION, 20);
        let bytes = build_wireguard_relay(
            &ipv4,
            Ipv4Route {
                source: SOURCE,
                destination: DESTINATION,
            },
        );
        let packet = NetPacket::new(bytes.clone()).unwrap();
        assert_eq!(
            validate_vnt_relay(&packet, SOURCE, NETWORK, GATEWAY),
            Ok(Ipv4Route {
                source: SOURCE,
                destination: DESTINATION,
            })
        );

        let mut wrong_destination = BytesMut::from(bytes.as_ref());
        NetPacket::new(&mut wrong_destination)
            .unwrap()
            .set_dest_id(Ipv4Addr::new(10, 26, 0, 4).into());
        assert_eq!(
            validate_vnt_relay(
                &NetPacket::new(wrong_destination).unwrap(),
                SOURCE,
                NETWORK,
                GATEWAY,
            ),
            Err(RelayValidationError::DestinationMismatch)
        );

        let mut compressed = BytesMut::from(bytes.as_ref());
        NetPacket::new(&mut compressed)
            .unwrap()
            .set_compressed_flag(true);
        assert_eq!(
            validate_vnt_relay(
                &NetPacket::new(compressed).unwrap(),
                SOURCE,
                NETWORK,
                GATEWAY,
            ),
            Err(RelayValidationError::InvalidFlags)
        );
    }
}

use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, MsgType, NetPacket};
use bytes::{Bytes, BytesMut};
use ipnet::Ipv4Net;
use pnet_packet::ipv4::Ipv4Packet;
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
}

pub(crate) fn validate_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
    network: Ipv4Net,
    gateway: Ipv4Addr,
) -> Result<Ipv4Route, RelayValidationError> {
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

    let source = ipv4.get_source();
    if source != expected_source {
        return Err(RelayValidationError::SourceMismatch);
    }

    let destination = ipv4.get_destination();
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

    Ok(Ipv4Route {
        source,
        destination,
    })
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

pub(crate) fn build_wireguard_relay(ipv4: &[u8], route: Ipv4Route) -> Bytes {
    let mut buffer = BytesMut::zeroed(HEAD_LENGTH + ipv4.len());
    let mut packet = NetPacket::new(&mut buffer).expect("relay buffer includes a complete header");
    packet.set_msg_type(MsgType::WireGuardRelay);
    packet.set_ttl(RELAY_TTL);
    packet.set_src_id(route.source.into());
    packet.set_dest_id(route.destination.into());
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

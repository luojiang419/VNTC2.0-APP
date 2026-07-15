use crate::context::NetworkAddr;
use crate::protocol::ip_packet_protocol::{MsgType, NetPacket};
use pnet_packet::ipv4::Ipv4Packet;
use std::net::Ipv4Addr;

pub(crate) const MAX_INNER_IPV4_PACKET_SIZE: usize =
    crate::context::config::WIREGUARD_MAX_MTU as usize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Ipv4Route {
    pub(crate) source: Ipv4Addr,
    pub(crate) destination: Ipv4Addr,
}

pub(crate) fn validate_inner_ipv4(
    packet: &[u8],
    expected_source: Ipv4Addr,
    expected_destination: Option<Ipv4Addr>,
    network_addr: NetworkAddr,
) -> Option<Ipv4Route> {
    if !(20..=MAX_INNER_IPV4_PACKET_SIZE).contains(&packet.len()) {
        return None;
    }

    let ipv4 = Ipv4Packet::new(packet)?;
    if ipv4.get_version() != 4 {
        return None;
    }
    let header_length = usize::from(ipv4.get_header_length()) * 4;
    if header_length < 20 || header_length > packet.len() {
        return None;
    }
    if usize::from(ipv4.get_total_length()) != packet.len() {
        return None;
    }

    let source = ipv4.get_source();
    let destination = ipv4.get_destination();
    if source != expected_source || expected_destination.is_some_and(|ip| destination != ip) {
        return None;
    }

    let network = network_addr.network();
    if !network.contains(&source)
        || !network.contains(&destination)
        || source == network.network()
        || source == network.broadcast()
        || source == network_addr.gateway
        || source.is_multicast()
        || destination == Ipv4Addr::BROADCAST
        || destination.is_multicast()
        || destination == network.network()
        || destination == network.broadcast()
        || destination == network_addr.gateway
    {
        return None;
    }

    Some(Ipv4Route {
        source,
        destination,
    })
}

pub(crate) fn validate_relay<B: AsRef<[u8]>>(
    packet: &NetPacket<B>,
    expected_destination: Ipv4Addr,
    network_addr: NetworkAddr,
) -> Option<Ipv4Route> {
    if packet.msg_type().ok() != Some(MsgType::WireGuardRelay)
        || packet.is_compressed()
        || packet.is_gateway()
        || packet.is_fec()
        || packet.ttl() == 0
    {
        return None;
    }

    let source = Ipv4Addr::from(packet.src_id());
    let route = validate_inner_ipv4(
        packet.payload(),
        source,
        Some(expected_destination),
        network_addr,
    )?;
    if Ipv4Addr::from(packet.dest_id()) != route.destination {
        return None;
    }
    Some(route)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ip_packet_protocol::{HEAD_LENGTH, NetPacket};
    use crate::protocol::transmission::TransmissionBytes;

    const NETWORK_ADDR: NetworkAddr = NetworkAddr {
        gateway: Ipv4Addr::new(10, 26, 0, 1),
        broadcast: Ipv4Addr::new(10, 26, 0, 255),
        ip: Ipv4Addr::new(10, 26, 0, 2),
        prefix_len: 24,
    };
    const SOURCE: Ipv4Addr = Ipv4Addr::new(10, 26, 0, 3);

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

    fn relay(ipv4: &[u8]) -> NetPacket<TransmissionBytes> {
        let mut packet = NetPacket::new(TransmissionBytes::zeroed(HEAD_LENGTH + ipv4.len()))
            .expect("complete relay buffer");
        packet.set_msg_type(MsgType::WireGuardRelay);
        packet.set_ttl(5);
        packet.set_src_id(SOURCE.into());
        packet.set_dest_id(NETWORK_ADDR.ip.into());
        packet.set_payload(ipv4).expect("reserved payload");
        packet
    }

    #[test]
    fn accepts_exact_unicast_and_existing_fragment() {
        let ipv4 = ipv4_packet(SOURCE, NETWORK_ADDR.ip, MAX_INNER_IPV4_PACKET_SIZE);
        assert!(validate_relay(&relay(&ipv4), NETWORK_ADDR.ip, NETWORK_ADDR).is_some());

        let mut fragment = ipv4_packet(SOURCE, NETWORK_ADDR.ip, 100);
        fragment[6..8].copy_from_slice(&0x2000_u16.to_be_bytes());
        assert!(validate_relay(&relay(&fragment), NETWORK_ADDR.ip, NETWORK_ADDR).is_some());
    }

    #[test]
    fn rejects_spoofed_malformed_oversized_and_special_addresses() {
        let spoofed = ipv4_packet(Ipv4Addr::new(10, 26, 0, 4), NETWORK_ADDR.ip, 20);
        assert!(validate_relay(&relay(&spoofed), NETWORK_ADDR.ip, NETWORK_ADDR).is_none());

        let mut malformed = ipv4_packet(SOURCE, NETWORK_ADDR.ip, 24);
        malformed[2..4].copy_from_slice(&20_u16.to_be_bytes());
        assert!(validate_relay(&relay(&malformed), NETWORK_ADDR.ip, NETWORK_ADDR).is_none());

        let oversized = ipv4_packet(SOURCE, NETWORK_ADDR.ip, MAX_INNER_IPV4_PACKET_SIZE + 1);
        assert!(validate_relay(&relay(&oversized), NETWORK_ADDR.ip, NETWORK_ADDR).is_none());

        for destination in [
            NETWORK_ADDR.gateway,
            NETWORK_ADDR.broadcast,
            Ipv4Addr::BROADCAST,
            Ipv4Addr::new(224, 0, 0, 1),
        ] {
            let ipv4 = ipv4_packet(SOURCE, destination, 20);
            assert!(validate_inner_ipv4(&ipv4, SOURCE, None, NETWORK_ADDR).is_none());
        }
    }

    #[test]
    fn rejects_invalid_relay_envelope() {
        let ipv4 = ipv4_packet(SOURCE, NETWORK_ADDR.ip, 20);
        let mut packet = relay(&ipv4);
        packet.set_compressed_flag(true);
        assert!(validate_relay(&packet, NETWORK_ADDR.ip, NETWORK_ADDR).is_none());

        let mut packet = relay(&ipv4);
        packet.set_dest_id(Ipv4Addr::new(10, 26, 0, 4).into());
        assert!(validate_relay(&packet, NETWORK_ADDR.ip, NETWORK_ADDR).is_none());
    }
}

use boringtun::noise::errors::WireGuardError;
use boringtun::noise::handshake::parse_handshake_anon;
use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Packet, Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;

const CLIENT_ENDPOINT: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
const SERVER_ENDPOINT: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20));
const ROAMED_CLIENT_ENDPOINT: IpAddr = IpAddr::V4(Ipv4Addr::new(198, 51, 100, 10));

fn private_key(byte: u8) -> StaticSecret {
    StaticSecret::from([byte; 32])
}

fn tunnel_pair() -> (Tunn, Tunn) {
    let client_private = private_key(1);
    let server_private = private_key(2);
    let client_public = PublicKey::from(&client_private);
    let server_public = PublicKey::from(&server_private);

    (
        Tunn::new(client_private, server_public, None, None, 1, None),
        Tunn::new(server_private, client_public, None, None, 2, None),
    )
}

fn ipv4_packet(src: Ipv4Addr, dst: Ipv4Addr, payload: &[u8]) -> Vec<u8> {
    let total_len = 20 + payload.len();
    let mut packet = vec![0; total_len];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&src.octets());
    packet[16..20].copy_from_slice(&dst.octets());
    packet[20..].copy_from_slice(payload);
    packet
}

fn network_packet(result: TunnResult<'_>) -> Vec<u8> {
    match result {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("expected network packet, got {other:?}"),
    }
}

fn tunnel_packet(result: TunnResult<'_>) -> Vec<u8> {
    match result {
        TunnResult::WriteToTunnelV4(packet, _) => packet.to_vec(),
        other => panic!("expected IPv4 tunnel packet, got {other:?}"),
    }
}

fn establish(first_packet: &[u8]) -> (Tunn, Tunn) {
    let (mut client, mut server) = tunnel_pair();
    let mut client_buffer = vec![0; 2048];
    let mut server_buffer = vec![0; 2048];

    let initiation = network_packet(client.encapsulate(first_packet, &mut client_buffer));
    let response =
        network_packet(server.decapsulate(Some(CLIENT_ENDPOINT), &initiation, &mut server_buffer));
    let keepalive =
        network_packet(client.decapsulate(Some(SERVER_ENDPOINT), &response, &mut client_buffer));
    assert!(matches!(
        server.decapsulate(Some(CLIENT_ENDPOINT), &keepalive, &mut server_buffer),
        TunnResult::Done
    ));

    let queued = network_packet(client.decapsulate(None, &[], &mut client_buffer));
    let decrypted =
        tunnel_packet(server.decapsulate(Some(CLIENT_ENDPOINT), &queued, &mut server_buffer));
    assert_eq!(decrypted, first_packet);

    (client, server)
}

#[test]
fn handshake_supports_anonymous_public_key_dispatch() {
    let client_private = private_key(1);
    let server_private = private_key(2);
    let client_public = PublicKey::from(&client_private);
    let server_public = PublicKey::from(&server_private);
    let mut client = Tunn::new(client_private, server_public, None, None, 1, None);
    let mut buffer = vec![0; 2048];

    let initiation = network_packet(client.format_handshake_initiation(&mut buffer, false));
    let parsed = Tunn::parse_incoming_packet(&initiation).expect("valid handshake initiation");
    let Packet::HandshakeInit(handshake) = parsed else {
        panic!("expected handshake initiation");
    };
    let half = parse_handshake_anon(&server_private, &server_public, &handshake)
        .expect("server must recover the initiating static public key");

    assert_eq!(half.peer_static_public, client_public.to_bytes());

    let wrong_server_private = private_key(3);
    let wrong_server_public = PublicKey::from(&wrong_server_private);
    assert!(
        parse_handshake_anon(&wrong_server_private, &wrong_server_public, &handshake).is_err(),
        "a handshake encrypted for another server key must not dispatch"
    );
}

#[test]
fn handshake_allows_bidirectional_ipv4_transport() {
    let first = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"client-to-server",
    );
    let (mut client, mut server) = establish(&first);
    let reply = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 1),
        Ipv4Addr::new(10, 26, 0, 2),
        b"server-to-client",
    );
    let mut network_buffer = vec![0; 2048];
    let mut tunnel_buffer = vec![0; 2048];

    let encrypted = network_packet(server.encapsulate(&reply, &mut network_buffer));
    let decrypted =
        tunnel_packet(client.decapsulate(Some(SERVER_ENDPOINT), &encrypted, &mut tunnel_buffer));

    assert_eq!(decrypted, reply);
}

#[test]
fn replayed_transport_packet_is_rejected() {
    let first = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"establish",
    );
    let (mut client, mut server) = establish(&first);
    let packet = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"replay-me-once",
    );
    let mut network_buffer = vec![0; 2048];
    let mut tunnel_buffer = vec![0; 2048];
    let encrypted = network_packet(client.encapsulate(&packet, &mut network_buffer));

    assert_eq!(
        tunnel_packet(server.decapsulate(Some(CLIENT_ENDPOINT), &encrypted, &mut tunnel_buffer,)),
        packet
    );
    assert!(matches!(
        server.decapsulate(Some(CLIENT_ENDPOINT), &encrypted, &mut tunnel_buffer),
        TunnResult::Err(WireGuardError::DuplicateCounter)
    ));
}

#[test]
fn transport_survives_endpoint_roaming() {
    let first = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"establish",
    );
    let (mut client, mut server) = establish(&first);
    let packet = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"new-endpoint",
    );
    let mut network_buffer = vec![0; 2048];
    let mut tunnel_buffer = vec![0; 2048];
    let encrypted = network_packet(client.encapsulate(&packet, &mut network_buffer));

    let decrypted = tunnel_packet(server.decapsulate(
        Some(ROAMED_CLIENT_ENDPOINT),
        &encrypted,
        &mut tunnel_buffer,
    ));
    assert_eq!(decrypted, packet);
}

#[test]
fn handshake_rate_limit_requires_cookie_or_source_address() {
    let client_private = private_key(1);
    let server_private = private_key(2);
    let client_public = PublicKey::from(&client_private);
    let server_public = PublicKey::from(&server_private);
    let limiter = Arc::new(RateLimiter::new(&server_public, 0));
    let mut client = Tunn::new(client_private, server_public, None, None, 1, None);
    let mut server = Tunn::new(server_private, client_public, None, None, 2, Some(limiter));
    let mut client_buffer = vec![0; 2048];
    let mut server_buffer = vec![0; 2048];
    let initiation = network_packet(client.format_handshake_initiation(&mut client_buffer, false));

    let cookie_reply =
        network_packet(server.decapsulate(Some(CLIENT_ENDPOINT), &initiation, &mut server_buffer));
    assert_eq!(cookie_reply.len(), 64);
    assert_eq!(
        u32::from_le_bytes(cookie_reply[0..4].try_into().unwrap()),
        3
    );

    assert!(matches!(
        server.decapsulate(None, &initiation, &mut server_buffer),
        TunnResult::Err(WireGuardError::UnderLoad)
    ));
}

#[test]
fn established_session_handles_bounded_packet_pressure() {
    let first = ipv4_packet(
        Ipv4Addr::new(10, 26, 0, 2),
        Ipv4Addr::new(10, 26, 0, 1),
        b"establish",
    );
    let (mut client, mut server) = establish(&first);
    let mut network_buffer = vec![0; 2048];
    let mut tunnel_buffer = vec![0; 2048];

    for sequence in 0_u32..4096 {
        let packet = ipv4_packet(
            Ipv4Addr::new(10, 26, 0, 2),
            Ipv4Addr::new(10, 26, 0, 1),
            &sequence.to_be_bytes(),
        );
        let encrypted = network_packet(client.encapsulate(&packet, &mut network_buffer));
        let decrypted = tunnel_packet(server.decapsulate(
            Some(CLIENT_ENDPOINT),
            &encrypted,
            &mut tunnel_buffer,
        ));
        assert_eq!(decrypted, packet);
    }
}

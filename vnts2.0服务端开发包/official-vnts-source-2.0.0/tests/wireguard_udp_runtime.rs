use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use prost::{Message, Oneof};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme, StreamOwned};
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Clone, PartialEq, Message)]
struct TestRequestMessage {
    #[prost(oneof = "test_request_message::Payload", tags = "1")]
    payload: Option<test_request_message::Payload>,
}

mod test_request_message {
    use super::*;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "1")]
        Reg(TestRegRequest),
    }
}

#[derive(Clone, PartialEq, Message)]
struct TestRegRequest {
    #[prost(string, tag = "1")]
    network_code: String,
    #[prost(string, tag = "2")]
    device_id: String,
    #[prost(fixed32, optional, tag = "3")]
    ip: Option<u32>,
    #[prost(string, tag = "4")]
    name: String,
    #[prost(string, tag = "5")]
    version: String,
    #[prost(string, optional, tag = "6")]
    key_sign: Option<String>,
    #[prost(bool, tag = "7")]
    ip_variable: bool,
    #[prost(fixed32, tag = "8")]
    server_id: u32,
    #[prost(int32, tag = "9")]
    registration_mode: i32,
    #[prost(bool, tag = "10")]
    allow_wire_guard: bool,
    #[prost(bytes = "vec", tag = "11")]
    wireguard_p2p_public_key: Vec<u8>,
    #[prost(uint32, tag = "12")]
    wireguard_p2p_port: u32,
    #[prost(uint64, tag = "13")]
    client_capabilities: u64,
}

#[derive(Clone, PartialEq, Message)]
struct TestClientSimpleInfo {
    #[prost(fixed32, tag = "1")]
    ip: u32,
    #[prost(bool, tag = "2")]
    online: bool,
    #[prost(int32, tag = "3")]
    node_type: i32,
}

#[derive(Clone, PartialEq, Message)]
struct TestClientSimpleInfoList {
    #[prost(uint64, tag = "1")]
    data_version: u64,
    #[prost(message, repeated, tag = "2")]
    list: Vec<TestClientSimpleInfo>,
    #[prost(bool, tag = "3")]
    is_all: bool,
    #[prost(int64, tag = "4")]
    time: i64,
}

#[derive(Clone, PartialEq, Message)]
struct TestWireGuardP2pAgentRequest {
    #[prost(fixed32, tag = "1")]
    target_ip: u32,
    #[prost(uint64, tag = "2")]
    request_id: u64,
}

#[derive(Clone, PartialEq, Message)]
struct TestWireGuardP2pAgentResponse {
    #[prost(uint64, tag = "1")]
    request_id: u64,
    #[prost(enumeration = "TestWireGuardP2pStatus", tag = "2")]
    status: i32,
    #[prost(fixed32, tag = "3")]
    target_ip: u32,
    #[prost(bytes = "vec", tag = "4")]
    target_public_key: Vec<u8>,
    #[prost(string, tag = "5")]
    target_endpoint: String,
    #[prost(uint64, tag = "6")]
    lease_id: u64,
    #[prost(uint64, tag = "7")]
    expires_at_unix_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum TestWireGuardP2pStatus {
    Ok = 0,
    NotFound = 1,
    NotCapable = 2,
    Rejected = 3,
    Busy = 4,
}

#[derive(Clone, PartialEq, Message)]
struct TestWireGuardP2pOffer {
    #[prost(uint64, tag = "1")]
    lease_id: u64,
    #[prost(uint64, tag = "2")]
    expires_at_unix_ms: u64,
    #[prost(fixed32, tag = "3")]
    peer_ip: u32,
    #[prost(bytes = "vec", tag = "4")]
    peer_public_key: Vec<u8>,
    #[prost(string, tag = "5")]
    peer_endpoint: String,
}

#[derive(Clone, PartialEq, Message)]
struct TestWireGuardP2pControl {
    #[prost(oneof = "test_wire_guard_p2p_control::Payload", tags = "1, 2")]
    payload: Option<test_wire_guard_p2p_control::Payload>,
}

mod test_wire_guard_p2p_control {
    use super::*;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "1")]
        Offer(TestWireGuardP2pOffer),
        #[prost(message, tag = "2")]
        Revoke(TestWireGuardP2pRevoke),
    }
}

#[derive(Clone, PartialEq, Message)]
struct TestWireGuardP2pRevoke {
    #[prost(uint64, tag = "1")]
    lease_id: u64,
}

#[derive(Debug)]
struct SkipServerVerification;

impl ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ED25519,
        ]
    }
}

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "vnts2-wireguard-udp-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let Ok(root) = self.0.canonicalize() else {
            return;
        };
        let Ok(temp) = std::env::temp_dir().canonicalize() else {
            return;
        };
        if root != temp && root.starts_with(&temp) {
            let _ = fs::remove_dir_all(root);
        }
    }
}

struct ChildGuard(Option<Child>);

impl ChildGuard {
    fn spawn(mut command: Command) -> Self {
        Self(Some(command.spawn().unwrap()))
    }

    fn child_mut(&mut self) -> &mut Child {
        self.0.as_mut().unwrap()
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.0.take() {
            if child.try_wait().unwrap().is_none() {
                child.kill().unwrap();
            }
            child.wait().unwrap();
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        self.stop();
    }
}

struct HttpResponse {
    status: u16,
    body: String,
}

fn command(binary: &Path) -> Command {
    let command = Command::new(binary);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let mut command = command;
        command.creation_flags(CREATE_NO_WINDOW);
        command
    }
    #[cfg(not(windows))]
    {
        let _ = CREATE_NO_WINDOW;
        command
    }
}

fn server_command(binary: &Path, config: &Path) -> Command {
    let mut command = command(binary);
    command
        .arg("--conf")
        .arg(config)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn failure_command(binary: &Path, config: &Path) -> Command {
    let mut command = command(binary);
    command
        .arg("--conf")
        .arg(config)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

fn wait_for_failure(mut command: Command) -> Output {
    let mut child = command.spawn().unwrap();
    for _ in 0..100 {
        if child.try_wait().unwrap().is_some() {
            return child.wait_with_output().unwrap();
        }
        thread::sleep(Duration::from_millis(25));
    }
    let _ = child.kill();
    let output = child.wait_with_output().unwrap();
    panic!(
        "server did not fail startup; stdout={}, stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn unused_tcp_addr() -> SocketAddr {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
}

fn unused_udp_addr() -> SocketAddr {
    UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
}

fn wait_for_http(child: &mut Child, address: SocketAddr) {
    for _ in 0..100 {
        if TcpStream::connect_timeout(&address, Duration::from_millis(50)).is_ok() {
            return;
        }
        if let Some(status) = child.try_wait().unwrap() {
            panic!("VNTS server exited before HTTP startup: {status}");
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for VNTS HTTP server at {address}");
}

fn public_keys(log: &Path) -> Vec<[u8; 32]> {
    let Ok(content) = fs::read_to_string(log) else {
        return Vec::new();
    };
    content
        .lines()
        .filter_map(|line| {
            line.split_once("WireGuard server identity initialized, public key: ")
                .and_then(|(_, value)| hex::decode(value.trim()).ok())
                .and_then(|value| value.try_into().ok())
        })
        .collect()
}

fn wait_for_public_key(child: &mut Child, log: &Path) -> [u8; 32] {
    for _ in 0..100 {
        if let Some(key) = public_keys(log).last() {
            return *key;
        }
        if let Some(status) = child.try_wait().unwrap() {
            panic!("VNTS server exited before WireGuard startup: {status}");
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for WireGuard identity");
}

fn http_request(
    address: SocketAddr,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> HttpResponse {
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(5)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut request =
        format!("{method} {path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n");
    if let Some(token) = token {
        request.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    if let Some(body) = body {
        request.push_str("Content-Type: application/json\r\n");
        request.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    request.push_str("\r\n");
    if let Some(body) = body {
        request.push_str(body);
    }
    stream.write_all(request.as_bytes()).unwrap();
    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    let response = String::from_utf8(response).unwrap();
    let (head, body) = response.split_once("\r\n\r\n").unwrap();
    HttpResponse {
        status: head
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap(),
        body: body.to_string(),
    }
}

fn assert_api_ok(response: &HttpResponse) {
    assert_eq!(response.status, 200, "unexpected body: {}", response.body);
    assert!(
        response.body.contains(r#""code":200"#),
        "unexpected body: {}",
        response.body
    );
}

fn login(address: SocketAddr) -> String {
    let response = http_request(
        address,
        "POST",
        "/api/login",
        None,
        Some(r#"{"username":"udp-admin","password":"udp-password"}"#),
    );
    assert_api_ok(&response);
    response
        .body
        .split_once("\"token\":\"")
        .and_then(|(_, value)| value.split('"').next())
        .unwrap()
        .to_string()
}

fn create_peer(
    address: SocketAddr,
    token: &str,
    peer_id: &str,
    public_key: [u8; 32],
    enabled: bool,
) {
    let body = format!(
        r#"{{"network_code":"network-a","peer_id":"{peer_id}","public_key":"{}","enabled":{enabled}}}"#,
        BASE64_STANDARD.encode(public_key)
    );
    assert_api_ok(&http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(token),
        Some(&body),
    ));
}

fn reserve_ip(address: SocketAddr, token: &str, peer_id: &str, ip: &str) {
    let body = format!(r#"{{"network_code":"network-a","peer_id":"{peer_id}","ip":"{ip}"}}"#);
    assert_api_ok(&http_request(
        address,
        "PUT",
        "/api/wireguard/peer_ips",
        Some(token),
        Some(&body),
    ));
}

fn update_peer_routes(address: SocketAddr, token: &str, peer_id: &str, routes_json: &str) {
    let body = format!(
        r#"{{"network_code":"network-a","peer_id":"{peer_id}","persistent_keepalive":25,"routes":{routes_json}}}"#
    );
    assert_api_ok(&http_request(
        address,
        "PUT",
        "/api/wireguard/peers/profile",
        Some(token),
        Some(&body),
    ));
}

fn release_ip(address: SocketAddr, token: &str, peer_id: &str) {
    assert_api_ok(&http_request(
        address,
        "DELETE",
        &format!("/api/wireguard/peer_ips?network_code=network-a&peer_id={peer_id}"),
        Some(token),
        None,
    ));
}

fn private_key(byte: u8) -> StaticSecret {
    StaticSecret::from([byte; 32])
}

fn client_tunnel(private: StaticSecret, server_public: [u8; 32], index: u32) -> Tunn {
    Tunn::new(
        private,
        PublicKey::from(server_public),
        None,
        None,
        index,
        None,
    )
}

fn network_packet(result: TunnResult<'_>) -> Vec<u8> {
    match result {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("expected network packet, got {other:?}"),
    }
}

fn handshake(socket: &UdpSocket, server: SocketAddr, tunnel: &mut Tunn) -> Option<(Vec<u8>, u32)> {
    let mut buffer = vec![0; 2048];
    let initiation = network_packet(tunnel.format_handshake_initiation(&mut buffer, true));
    socket.send_to(&initiation, server).unwrap();
    let mut response = vec![0; 2048];
    let length = match socket.recv_from(&mut response) {
        Ok((length, _)) => length,
        Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
            return None;
        }
        Err(error) => panic!("UDP receive failed: {error}"),
    };
    response.truncate(length);
    if response.len() != 92 || u32::from_le_bytes(response[0..4].try_into().unwrap()) != 2 {
        return None;
    }
    let receiver_index = u32::from_le_bytes(response[4..8].try_into().unwrap()) >> 8;
    let keepalive = network_packet(tunnel.decapsulate(Some(server.ip()), &response, &mut buffer));
    socket.send_to(&keepalive, server).unwrap();
    Some((response, receiver_index))
}

fn assert_no_handshake(socket: &UdpSocket, server: SocketAddr, tunnel: &mut Tunn) {
    assert!(
        handshake(socket, server, tunnel).is_none(),
        "peer unexpectedly received a handshake response"
    );
}

fn ipv4_packet(source: [u8; 4]) -> Vec<u8> {
    ipv4_packet_to(source, [10, 26, 0, 1], 20)
}

fn ipv4_packet_to(source: [u8; 4], destination: [u8; 4], length: usize) -> Vec<u8> {
    let mut packet = vec![0; length];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(length as u16).to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&source);
    packet[16..20].copy_from_slice(&destination);
    packet
}

fn icmp_echo_request(source: [u8; 4], destination: [u8; 4]) -> Vec<u8> {
    let mut packet = ipv4_packet_to(source, destination, 28);
    packet[9] = 1;
    packet[20] = 8;
    packet[24..28].copy_from_slice(&[0x12, 0x34, 0, 1]);
    packet
}

fn internet_checksum(packet: &[u8]) -> u16 {
    let mut sum = 0_u32;
    let mut chunks = packet.chunks_exact(2);
    for chunk in &mut chunks {
        sum += u32::from(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    if let Some(last) = chunks.remainder().first() {
        sum += u32::from(*last) << 8;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

fn send_inner_ipv4(socket: &UdpSocket, server: SocketAddr, tunnel: &mut Tunn, ipv4: &[u8]) {
    let mut buffer = vec![0; 2048];
    let encrypted = network_packet(tunnel.encapsulate(ipv4, &mut buffer));
    socket.send_to(&encrypted, server).unwrap();
}

fn receive_inner_ipv4(socket: &UdpSocket, server: SocketAddr, tunnel: &mut Tunn) -> Vec<u8> {
    try_receive_inner_ipv4(socket, server, tunnel).expect("expected bridged IPv4 packet")
}

fn try_receive_inner_ipv4(
    socket: &UdpSocket,
    server: SocketAddr,
    tunnel: &mut Tunn,
) -> Option<Vec<u8>> {
    let mut encrypted = vec![0; 2048];
    let (length, _) = match socket.recv_from(&mut encrypted) {
        Ok(received) => received,
        Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
            return None;
        }
        Err(error) => panic!("UDP receive failed: {error}"),
    };
    let mut buffer = vec![0; 2048];
    match tunnel.decapsulate(Some(server.ip()), &encrypted[..length], &mut buffer) {
        TunnResult::WriteToTunnelV4(packet, _) => Some(packet.to_vec()),
        other => panic!("expected bridged IPv4 packet, got {other:?}"),
    }
}

fn write_frame(stream: &mut impl Write, data: &[u8]) {
    stream
        .write_all(&(data.len() as u32).to_be_bytes())
        .unwrap();
    stream.write_all(data).unwrap();
    stream.flush().unwrap();
}

fn read_frame(stream: &mut impl Read) -> std::io::Result<Vec<u8>> {
    let mut length = [0; 4];
    stream.read_exact(&mut length)?;
    let mut data = vec![0; u32::from_be_bytes(length) as usize];
    stream.read_exact(&mut data)?;
    Ok(data)
}

fn connect_vnt(
    server: SocketAddr,
    device_id: &str,
    ip: [u8; 4],
    allow_wire_guard: bool,
) -> StreamOwned<ClientConnection, TcpStream> {
    connect_vnt_with_p2p(server, device_id, ip, allow_wire_guard, None)
}

fn connect_vnt_with_p2p(
    server: SocketAddr,
    device_id: &str,
    ip: [u8; 4],
    allow_wire_guard: bool,
    p2p: Option<([u8; 32], u16)>,
) -> StreamOwned<ClientConnection, TcpStream> {
    let config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
        .with_no_client_auth();
    let connection = ClientConnection::new(
        Arc::new(config),
        ServerName::try_from("localhost").unwrap().to_owned(),
    )
    .unwrap();
    let socket = TcpStream::connect(server).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    socket
        .set_write_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut stream = StreamOwned::new(connection, socket);
    let (wireguard_p2p_public_key, wireguard_p2p_port) = p2p
        .map(|(key, port)| (key.to_vec(), u32::from(port)))
        .unwrap_or_default();
    let registration = TestRequestMessage {
        payload: Some(test_request_message::Payload::Reg(TestRegRequest {
            network_code: "network-a".to_string(),
            device_id: device_id.to_string(),
            ip: Some(u32::from_be_bytes(ip)),
            name: device_id.to_string(),
            version: "wireguard-bridge-test".to_string(),
            key_sign: None,
            ip_variable: false,
            server_id: 1,
            registration_mode: 0,
            allow_wire_guard,
            wireguard_p2p_public_key,
            wireguard_p2p_port,
            client_capabilities: if allow_wire_guard { 0b11 } else { 0 },
        })),
    }
    .encode_to_vec();
    write_frame(&mut stream, &registration);
    read_frame(&mut stream).unwrap();
    stream
}

fn agent_control_packet(source: [u8; 4], destination: [u8; 4], target: [u8; 4]) -> Vec<u8> {
    let payload = TestWireGuardP2pAgentRequest {
        target_ip: u32::from_be_bytes(target),
        request_id: 0x1234_5678,
    }
    .encode_to_vec();
    let length = 20 + 8 + payload.len();
    let mut packet = vec![0; length];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(length as u16).to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&source);
    packet[16..20].copy_from_slice(&destination);
    packet[20..22].copy_from_slice(&48_000_u16.to_be_bytes());
    packet[22..24].copy_from_slice(&51_821_u16.to_be_bytes());
    packet[24..26].copy_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
    packet[28..].copy_from_slice(&payload);
    packet
}

fn udp_payload(packet: &[u8]) -> &[u8] {
    assert_eq!(packet[0] >> 4, 4);
    assert_eq!(packet[9], 17);
    let header_len = usize::from(packet[0] & 0x0f) * 4;
    &packet[header_len + 8..]
}

fn wireguard_relay(ipv4: &[u8], source: [u8; 4], destination: [u8; 4]) -> Vec<u8> {
    let mut relay = vec![0; 16 + ipv4.len()];
    relay[0] = 0x80 | 18;
    relay[1] = 0x55;
    relay[8..12].copy_from_slice(&source);
    relay[12..16].copy_from_slice(&destination);
    relay[16..].copy_from_slice(ipv4);
    relay
}

fn wireguard_broadcast_relay(ipv4: &[u8], source: [u8; 4], outer_destination: [u8; 4]) -> Vec<u8> {
    let mut relay = vec![0; 16 + ipv4.len()];
    relay[0] = 0x80 | 22;
    relay[1] = 0x55;
    relay[8..12].copy_from_slice(&source);
    relay[12..16].copy_from_slice(&outer_destination);
    relay[16..].copy_from_slice(ipv4);
    relay
}

fn wireguard_subnet_relay(
    ipv4: &[u8],
    vnt_gateway: [u8; 4],
    wireguard_destination: [u8; 4],
) -> Vec<u8> {
    let mut relay = vec![0; 16 + ipv4.len()];
    relay[0] = 0x80 | 21;
    relay[1] = 0x55;
    relay[8..12].copy_from_slice(&vnt_gateway);
    relay[12..16].copy_from_slice(&wireguard_destination);
    relay[16..].copy_from_slice(ipv4);
    relay
}

fn client_list_request(source: [u8; 4], gateway: [u8; 4]) -> Vec<u8> {
    let mut packet = vec![0; 32];
    packet[0] = 0x80 | 7;
    packet[1] = 0x55;
    packet[2] = 0x40;
    packet[8..12].copy_from_slice(&source);
    packet[12..16].copy_from_slice(&gateway);
    packet[24..32].copy_from_slice(&u64::MAX.to_be_bytes());
    packet
}

fn ipv6_packet() -> Vec<u8> {
    let mut packet = vec![0; 40];
    packet[0] = 0x60;
    packet[7] = 64;
    packet[8..24].copy_from_slice(&[0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
    packet[24..40].copy_from_slice(&[0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    packet
}

fn assert_no_udp_response(socket: &UdpSocket) {
    let mut buffer = [0; 2048];
    match socket.recv_from(&mut buffer) {
        Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
        Ok((length, source)) => panic!("unexpected {length}-byte UDP response from {source}"),
        Err(error) => panic!("UDP receive failed: {error}"),
    }
}

fn base_config(
    http: SocketAddr,
    wireguard: SocketAddr,
    master_key: Option<&Path>,
    persistence: bool,
) -> String {
    let mut config = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
         network = \"10.89.0.0/24\"\n\
         white_list = []\n\
         lease_duration = 60\n\
         web_bind = \"{http}\"\n\
         username = \"udp-admin\"\n\
         password = \"udp-password\"\n\
         persistence = {persistence}\n\
         wireguard_bind = \"{wireguard}\"\n\
         wireguard_max_active_peers = 2\n"
    );
    if let Some(master_key) = master_key {
        config.push_str(&format!(
            "wireguard_master_key_file = '{}'\n",
            master_key.display()
        ));
    }
    config.push_str("[custom_nets]\nnetwork-a = \"10.26.0.0/24\"\n");
    config
}

fn cross_server_config(
    http: SocketAddr,
    wireguard: SocketAddr,
    master_key: &Path,
    server_quic_bind: Option<SocketAddr>,
    peer_server: Option<SocketAddr>,
) -> String {
    let mut peer_settings = "server_token = \"wireguard-cross-server-test\"\n".to_string();
    if let Some(server_quic_bind) = server_quic_bind {
        peer_settings.push_str(&format!("server_quic_bind = \"{server_quic_bind}\"\n"));
    }
    if let Some(peer_server) = peer_server {
        peer_settings.push_str(&format!("peer_servers = [\"{peer_server}\"]\n"));
    }
    base_config(http, wireguard, Some(master_key), true).replacen(
        "[custom_nets]",
        &format!("{peer_settings}[custom_nets]"),
        1,
    )
}

#[test]
fn udp_listener_startup_contract_is_fail_closed_and_backward_compatible() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));

    let legacy = TestDirectory::new("legacy");
    let legacy_config = legacy.0.join("config.toml");
    let legacy_http = unused_tcp_addr();
    fs::write(
        &legacy_config,
        format!(
            "tcp_bind = \"127.0.0.1:0\"\n\
             network = \"10.89.0.0/24\"\n\
             white_list = []\n\
             lease_duration = 60\n\
             web_bind = \"{legacy_http}\"\n\
             username = \"udp-admin\"\n\
             password = \"udp-password\"\n\
             persistence = false\n\
             [custom_nets]\n"
        ),
    )
    .unwrap();
    let mut legacy_server = ChildGuard::spawn(server_command(&binary, &legacy_config));
    wait_for_http(legacy_server.child_mut(), legacy_http);
    legacy_server.stop();

    let no_persistence = TestDirectory::new("no-persistence");
    let no_persistence_key = no_persistence.0.join("master.key");
    fs::write(&no_persistence_key, [0x11; 32]).unwrap();
    let no_persistence_config = no_persistence.0.join("config.toml");
    fs::write(
        &no_persistence_config,
        base_config(
            unused_tcp_addr(),
            unused_udp_addr(),
            Some(&no_persistence_key),
            false,
        ),
    )
    .unwrap();
    let output = wait_for_failure(failure_command(&binary, &no_persistence_config));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("requires persistence = true"),
        "unexpected error: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let no_key = TestDirectory::new("no-key");
    let no_key_config = no_key.0.join("config.toml");
    fs::write(
        &no_key_config,
        base_config(unused_tcp_addr(), unused_udp_addr(), None, true),
    )
    .unwrap();
    let output = wait_for_failure(failure_command(&binary, &no_key_config));
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires wireguard_master_key_file"));

    let invalid_key = TestDirectory::new("invalid-key");
    let invalid_key_file = invalid_key.0.join("master.key");
    fs::write(&invalid_key_file, [0x22; 31]).unwrap();
    let invalid_key_config = invalid_key.0.join("config.toml");
    fs::write(
        &invalid_key_config,
        base_config(
            unused_tcp_addr(),
            unused_udp_addr(),
            Some(&invalid_key_file),
            true,
        ),
    )
    .unwrap();
    let output = wait_for_failure(failure_command(&binary, &invalid_key_config));
    assert!(String::from_utf8_lossy(&output.stderr).contains("exactly 32 bytes"));

    let database_failure = TestDirectory::new("database-failure");
    let database_key = database_failure.0.join("master.key");
    fs::write(&database_key, [0x33; 32]).unwrap();
    fs::create_dir(database_failure.0.join("network_control.db")).unwrap();
    let database_config = database_failure.0.join("config.toml");
    fs::write(
        &database_config,
        base_config(
            unused_tcp_addr(),
            unused_udp_addr(),
            Some(&database_key),
            true,
        ),
    )
    .unwrap();
    let output = wait_for_failure(failure_command(&binary, &database_config));
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires an initialized database"));

    let bind_failure = TestDirectory::new("bind-failure");
    let bind_key = bind_failure.0.join("master.key");
    fs::write(&bind_key, [0x44; 32]).unwrap();
    let occupied = UdpSocket::bind("127.0.0.1:0").unwrap();
    let bind_config = bind_failure.0.join("config.toml");
    fs::write(
        &bind_config,
        base_config(
            unused_tcp_addr(),
            occupied.local_addr().unwrap(),
            Some(&bind_key),
            true,
        ),
    )
    .unwrap();
    let output = wait_for_failure(failure_command(&binary, &bind_config));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Failed to bind WireGuard UDP listener")
    );
}

#[test]
fn capable_vnt_and_wireguard_exchange_raw_ipv4_without_legacy_downgrade() {
    let directory = TestDirectory::new("vnt-bridge");
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let master_key = directory.0.join("master.key");
    let config = directory.0.join("config.toml");
    let log = directory.0.join("logs").join("vnts2.log");
    let http = unused_tcp_addr();
    let vnt_tcp = unused_tcp_addr();
    let wireguard = unused_udp_addr();
    fs::write(&master_key, [0x67; 32]).unwrap();
    let config_text = base_config(http, wireguard, Some(&master_key), true).replace(
        "tcp_bind = \"127.0.0.1:0\"",
        &format!("tcp_bind = \"{vnt_tcp}\""),
    );
    fs::write(&config, config_text).unwrap();

    let mut server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(server.child_mut(), http);
    let server_public = wait_for_public_key(server.child_mut(), &log);
    let token = login(http);

    let private = private_key(0x76);
    create_peer(
        http,
        &token,
        "peer-bridge",
        PublicKey::from(&private).to_bytes(),
        true,
    );
    reserve_ip(http, &token, "peer-bridge", "10.26.0.3");

    let wireguard_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    wireguard_socket
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let mut wireguard_client = client_tunnel(private, server_public, 20);
    handshake(&wireguard_socket, wireguard, &mut wireguard_client).unwrap();

    let mut capable_vnt = connect_vnt(vnt_tcp, "capable-vnt", [10, 26, 0, 10], true);
    let vnt_to_wireguard = ipv4_packet_to([10, 26, 0, 10], [10, 26, 0, 3], 256);
    write_frame(
        &mut capable_vnt,
        &wireguard_relay(&vnt_to_wireguard, [10, 26, 0, 10], [10, 26, 0, 3]),
    );
    assert_eq!(
        receive_inner_ipv4(&wireguard_socket, wireguard, &mut wireguard_client),
        vnt_to_wireguard
    );

    let wireguard_to_vnt = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 10], 384);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard,
        &mut wireguard_client,
        &wireguard_to_vnt,
    );
    let relay = read_frame(&mut capable_vnt).unwrap();
    assert_eq!(relay[0] & 0x7f, 18);
    assert_eq!(&relay[8..12], &[10, 26, 0, 3]);
    assert_eq!(&relay[12..16], &[10, 26, 0, 10]);
    assert_eq!(&relay[16..], wireguard_to_vnt.as_slice());

    let wireguard_broadcast = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 255], 128);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard,
        &mut wireguard_client,
        &wireguard_broadcast,
    );
    let relay = read_frame(&mut capable_vnt).unwrap();
    assert_eq!(relay[0] & 0x7f, 22);
    assert_eq!(&relay[8..12], &[10, 26, 0, 3]);
    assert_eq!(&relay[12..16], &[10, 26, 0, 10]);
    assert_eq!(&relay[16..], wireguard_broadcast.as_slice());

    let vnt_broadcast = ipv4_packet_to([10, 26, 0, 10], [10, 26, 0, 255], 96);
    write_frame(
        &mut capable_vnt,
        &wireguard_broadcast_relay(&vnt_broadcast, [10, 26, 0, 10], [255, 255, 255, 255]),
    );
    assert_eq!(
        receive_inner_ipv4(&wireguard_socket, wireguard, &mut wireguard_client),
        vnt_broadcast
    );

    let mut legacy_vnt = connect_vnt(vnt_tcp, "legacy-vnt", [10, 26, 0, 11], false);
    legacy_vnt
        .sock
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let to_legacy = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 11], 20);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard,
        &mut wireguard_client,
        &to_legacy,
    );
    let error = read_frame(&mut legacy_vnt).unwrap_err();
    assert!(matches!(
        error.kind(),
        ErrorKind::WouldBlock | ErrorKind::TimedOut
    ));

    let legacy_to_wireguard = ipv4_packet_to([10, 26, 0, 11], [10, 26, 0, 3], 20);
    write_frame(
        &mut legacy_vnt,
        &wireguard_relay(&legacy_to_wireguard, [10, 26, 0, 11], [10, 26, 0, 3]),
    );
    assert_no_udp_response(&wireguard_socket);

    server.stop();
}

#[test]
fn managed_agent_discovers_vntc_endpoint_through_authenticated_wireguard() {
    let directory = TestDirectory::new("managed-p2p");
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let master_key = directory.0.join("master.key");
    let config = directory.0.join("config.toml");
    let log = directory.0.join("logs").join("vnts2.log");
    let http = unused_tcp_addr();
    let vnt_tcp = unused_tcp_addr();
    let wireguard = unused_udp_addr();
    fs::write(&master_key, [0x68; 32]).unwrap();
    let config_text = base_config(http, wireguard, Some(&master_key), true).replace(
        "tcp_bind = \"127.0.0.1:0\"",
        &format!("tcp_bind = \"{vnt_tcp}\""),
    );
    fs::write(&config, config_text).unwrap();

    let mut server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(server.child_mut(), http);
    let server_public = wait_for_public_key(server.child_mut(), &log);
    let token = login(http);

    let wireguard_private = private_key(0x79);
    let wireguard_public = PublicKey::from(&wireguard_private).to_bytes();
    create_peer(http, &token, "managed-agent", wireguard_public, true);
    reserve_ip(http, &token, "managed-agent", "10.26.0.3");

    let target_private = private_key(0x7a);
    let target_public = PublicKey::from(&target_private).to_bytes();
    let target_port = 43_210;
    let mut target_vnt = connect_vnt_with_p2p(
        vnt_tcp,
        "p2p-target",
        [10, 26, 0, 10],
        true,
        Some((target_public, target_port)),
    );

    let wireguard_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    wireguard_socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut wireguard_client = client_tunnel(wireguard_private, server_public, 22);
    handshake(&wireguard_socket, wireguard, &mut wireguard_client).unwrap();

    send_inner_ipv4(
        &wireguard_socket,
        wireguard,
        &mut wireguard_client,
        &agent_control_packet([10, 26, 0, 3], [10, 26, 0, 1], [10, 26, 0, 10]),
    );
    let response_packet = receive_inner_ipv4(&wireguard_socket, wireguard, &mut wireguard_client);
    let response = TestWireGuardP2pAgentResponse::decode(udp_payload(&response_packet)).unwrap();
    assert_eq!(response.request_id, 0x1234_5678);
    assert_eq!(response.status, TestWireGuardP2pStatus::Ok as i32);
    assert_eq!(response.target_ip, u32::from_be_bytes([10, 26, 0, 10]));
    assert_eq!(response.target_public_key, target_public);
    assert_eq!(response.target_endpoint, format!("127.0.0.1:{target_port}"));
    assert_ne!(response.lease_id, 0);

    let offer_frame = read_frame(&mut target_vnt).unwrap();
    assert_eq!(offer_frame[0] & 0x7f, 20);
    let offer_control = TestWireGuardP2pControl::decode(&offer_frame[16..]).unwrap();
    let test_wire_guard_p2p_control::Payload::Offer(offer) = offer_control.payload.unwrap() else {
        panic!("expected managed P2P offer");
    };
    assert_eq!(offer.lease_id, response.lease_id);
    assert_eq!(offer.expires_at_unix_ms, response.expires_at_unix_ms);
    assert_eq!(offer.peer_ip, u32::from_be_bytes([10, 26, 0, 3]));
    assert_eq!(offer.peer_public_key, wireguard_public);
    assert_eq!(
        offer.peer_endpoint,
        wireguard_socket.local_addr().unwrap().to_string()
    );

    release_ip(http, &token, "managed-agent");
    let revoke_frame = read_frame(&mut target_vnt).unwrap();
    assert_eq!(revoke_frame[0] & 0x7f, 20);
    let revoke_control = TestWireGuardP2pControl::decode(&revoke_frame[16..]).unwrap();
    let test_wire_guard_p2p_control::Payload::Revoke(revoke) = revoke_control.payload.unwrap()
    else {
        panic!("expected managed P2P revoke");
    };
    assert_eq!(revoke.lease_id, response.lease_id);

    server.stop();
}

#[test]
fn cross_server_bridge_preserves_origin_and_capability_boundaries() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let quic_b = unused_udp_addr();

    let directory_a = TestDirectory::new("cross-server-a");
    let master_key_a = directory_a.0.join("master.key");
    let config_a = directory_a.0.join("config.toml");
    let http_a = unused_tcp_addr();
    let vnt_tcp_a = unused_tcp_addr();
    let wireguard_a = unused_udp_addr();
    fs::write(&master_key_a, [0x76; 32]).unwrap();
    let config_text_a = cross_server_config(http_a, wireguard_a, &master_key_a, None, None)
        .replace(
            "tcp_bind = \"127.0.0.1:0\"",
            &format!("tcp_bind = \"{vnt_tcp_a}\""),
        );
    fs::write(&config_a, config_text_a).unwrap();

    let mut server_a = ChildGuard::spawn(server_command(&binary, &config_a));
    wait_for_http(server_a.child_mut(), http_a);
    let token_a = login(http_a);
    let mut capable_vnt = connect_vnt(vnt_tcp_a, "cross-capable-vnt", [10, 26, 0, 10], true);
    let mut legacy_vnt = connect_vnt(vnt_tcp_a, "cross-legacy-vnt", [10, 26, 0, 11], false);

    let directory_b = TestDirectory::new("cross-server-b");
    let master_key_b = directory_b.0.join("master.key");
    let config_b = directory_b.0.join("config.toml");
    let log_b = directory_b.0.join("logs").join("vnts2.log");
    let http_b = unused_tcp_addr();
    let wireguard_b = unused_udp_addr();
    fs::write(&master_key_b, [0x77; 32]).unwrap();
    fs::write(
        &config_b,
        cross_server_config(http_b, wireguard_b, &master_key_b, Some(quic_b), None),
    )
    .unwrap();

    let mut server_b = ChildGuard::spawn(server_command(&binary, &config_b));
    wait_for_http(server_b.child_mut(), http_b);
    let server_public_b = wait_for_public_key(server_b.child_mut(), &log_b);
    let token_b = login(http_b);
    let wireguard_private = private_key(0x78);
    create_peer(
        http_b,
        &token_b,
        "cross-wireguard",
        PublicKey::from(&wireguard_private).to_bytes(),
        true,
    );
    reserve_ip(http_b, &token_b, "cross-wireguard", "10.26.0.3");
    update_peer_routes(
        http_b,
        &token_b,
        "cross-wireguard",
        r#"[{"lan_network":"192.168.10.0/24","vnt_cli_ip":"10.26.0.10"}]"#,
    );

    let wireguard_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    wireguard_socket
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let mut wireguard_client = client_tunnel(wireguard_private, server_public_b, 21);
    handshake(&wireguard_socket, wireguard_b, &mut wireguard_client).unwrap();
    assert_api_ok(&http_request(
        http_a,
        "POST",
        "/api/peer_servers",
        Some(&token_a),
        Some(&format!(r#"{{"server_addr":"{quic_b}"}}"#)),
    ));

    let vnt_to_wireguard = ipv4_packet_to([10, 26, 0, 10], [10, 26, 0, 3], 320);
    let mut bridged_to_wireguard = None;
    for _ in 0..80 {
        write_frame(
            &mut capable_vnt,
            &wireguard_relay(&vnt_to_wireguard, [10, 26, 0, 10], [10, 26, 0, 3]),
        );
        if let Some(packet) =
            try_receive_inner_ipv4(&wireguard_socket, wireguard_b, &mut wireguard_client)
        {
            bridged_to_wireguard = Some(packet);
            break;
        }
    }
    assert_eq!(
        bridged_to_wireguard.as_deref(),
        Some(vnt_to_wireguard.as_slice()),
        "peer-server route must carry capable VNT traffic to WireGuard"
    );

    write_frame(
        &mut capable_vnt,
        &client_list_request([10, 26, 0, 10], [10, 26, 0, 1]),
    );
    let client_list_frame = read_frame(&mut capable_vnt).unwrap();
    assert_eq!(client_list_frame[0] & 0x7f, 13);
    let client_list = TestClientSimpleInfoList::decode(&client_list_frame[16..]).unwrap();
    assert!(client_list.is_all);
    assert!(client_list.list.iter().any(|client| {
        client.ip == u32::from_be_bytes([10, 26, 0, 3]) && client.online && client.node_type == 1
    }));

    capable_vnt
        .sock
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let wireguard_to_vnt = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 10], 448);
    let mut relay_to_vnt = None;
    for _ in 0..80 {
        send_inner_ipv4(
            &wireguard_socket,
            wireguard_b,
            &mut wireguard_client,
            &wireguard_to_vnt,
        );
        match read_frame(&mut capable_vnt) {
            Ok(frame) => {
                relay_to_vnt = Some(frame);
                break;
            }
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(error) => panic!("capable VNT receive failed: {error}"),
        }
    }
    let relay_to_vnt = relay_to_vnt.expect("peer-server route must reach capable VNT");
    assert_eq!(relay_to_vnt[0] & 0x7f, 18);
    assert_eq!(&relay_to_vnt[8..12], &[10, 26, 0, 3]);
    assert_eq!(&relay_to_vnt[12..16], &[10, 26, 0, 10]);
    assert_eq!(&relay_to_vnt[16..], wireguard_to_vnt.as_slice());

    let subnet_packet = ipv4_packet_to([10, 26, 0, 3], [192, 168, 10, 25], 192);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard_b,
        &mut wireguard_client,
        &subnet_packet,
    );
    let subnet_relay = read_frame(&mut capable_vnt).unwrap();
    assert_eq!(subnet_relay[0] & 0x7f, 21);
    assert_eq!(&subnet_relay[8..12], &[10, 26, 0, 3]);
    assert_eq!(&subnet_relay[12..16], &[10, 26, 0, 10]);
    assert_eq!(&subnet_relay[16..], subnet_packet.as_slice());

    let subnet_reply = ipv4_packet_to([192, 168, 10, 25], [10, 26, 0, 3], 176);
    write_frame(
        &mut capable_vnt,
        &wireguard_subnet_relay(&subnet_reply, [10, 26, 0, 10], [10, 26, 0, 3]),
    );
    assert_eq!(
        receive_inner_ipv4(&wireguard_socket, wireguard_b, &mut wireguard_client),
        subnet_reply,
        "VNT LAN reply must return through the owning WireGuard peer route"
    );
    let unauthorized_subnet_reply = ipv4_packet_to([192, 168, 11, 25], [10, 26, 0, 3], 64);
    write_frame(
        &mut capable_vnt,
        &wireguard_subnet_relay(&unauthorized_subnet_reply, [10, 26, 0, 10], [10, 26, 0, 3]),
    );
    assert_no_udp_response(&wireguard_socket);

    let wireguard_broadcast = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 255], 144);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard_b,
        &mut wireguard_client,
        &wireguard_broadcast,
    );
    let relay_to_vnt = read_frame(&mut capable_vnt).unwrap();
    assert_eq!(relay_to_vnt[0] & 0x7f, 22);
    assert_eq!(&relay_to_vnt[8..12], &[10, 26, 0, 3]);
    assert_eq!(&relay_to_vnt[12..16], &[10, 26, 0, 10]);
    assert_eq!(&relay_to_vnt[16..], wireguard_broadcast.as_slice());

    let vnt_broadcast = ipv4_packet_to([10, 26, 0, 10], [10, 26, 0, 255], 112);
    write_frame(
        &mut capable_vnt,
        &wireguard_broadcast_relay(&vnt_broadcast, [10, 26, 0, 10], [255, 255, 255, 255]),
    );
    assert_eq!(
        receive_inner_ipv4(&wireguard_socket, wireguard_b, &mut wireguard_client),
        vnt_broadcast,
        "peer-server broadcast must reach remote WireGuard"
    );

    legacy_vnt
        .sock
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let to_legacy = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 11], 20);
    send_inner_ipv4(
        &wireguard_socket,
        wireguard_b,
        &mut wireguard_client,
        &to_legacy,
    );
    let error = read_frame(&mut legacy_vnt).unwrap_err();
    assert!(matches!(
        error.kind(),
        ErrorKind::WouldBlock | ErrorKind::TimedOut
    ));

    let legacy_to_wireguard = ipv4_packet_to([10, 26, 0, 11], [10, 26, 0, 3], 20);
    write_frame(
        &mut legacy_vnt,
        &wireguard_relay(&legacy_to_wireguard, [10, 26, 0, 11], [10, 26, 0, 3]),
    );
    assert_no_udp_response(&wireguard_socket);

    server_b.stop();
    server_a.stop();
}

#[test]
fn real_udp_runtime_enforces_peer_dispatch_capacity_revocation_and_cookie_limit() {
    let directory = TestDirectory::new("runtime");
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let master_key = directory.0.join("master.key");
    let config = directory.0.join("config.toml");
    let log = directory.0.join("logs").join("vnts2.log");
    let http = unused_tcp_addr();
    let wireguard = unused_udp_addr();
    fs::write(&master_key, [0x66; 32]).unwrap();
    fs::write(
        &config,
        base_config(http, wireguard, Some(&master_key), true),
    )
    .unwrap();

    let mut server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(server.child_mut(), http);
    let server_public = wait_for_public_key(server.child_mut(), &log);
    let token = login(http);

    let private_a = private_key(0x71);
    let private_b = private_key(0x72);
    let private_disabled = private_key(0x73);
    let private_no_ip = private_key(0x74);
    let private_capacity = private_key(0x75);
    create_peer(
        http,
        &token,
        "peer-a",
        PublicKey::from(&private_a).to_bytes(),
        true,
    );
    reserve_ip(http, &token, "peer-a", "10.26.0.2");
    create_peer(
        http,
        &token,
        "peer-b",
        PublicKey::from(&private_b).to_bytes(),
        true,
    );
    reserve_ip(http, &token, "peer-b", "10.26.0.3");
    create_peer(
        http,
        &token,
        "peer-disabled",
        PublicKey::from(&private_disabled).to_bytes(),
        false,
    );
    reserve_ip(http, &token, "peer-disabled", "10.26.0.4");
    create_peer(
        http,
        &token,
        "peer-no-ip",
        PublicKey::from(&private_no_ip).to_bytes(),
        true,
    );
    create_peer(
        http,
        &token,
        "peer-capacity",
        PublicKey::from(&private_capacity).to_bytes(),
        true,
    );
    reserve_ip(http, &token, "peer-capacity", "10.26.0.5");

    let socket_a = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket_a
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let mut disabled = client_tunnel(private_disabled.clone(), server_public, 3);
    assert_no_handshake(&socket_a, wireguard, &mut disabled);
    let mut no_ip = client_tunnel(private_no_ip.clone(), server_public, 4);
    assert_no_handshake(&socket_a, wireguard, &mut no_ip);
    let mut unknown = client_tunnel(private_key(0x7f), server_public, 5);
    assert_no_handshake(&socket_a, wireguard, &mut unknown);

    let mut client_a = client_tunnel(private_a.clone(), server_public, 10);
    let (_, receiver_a) = handshake(&socket_a, wireguard, &mut client_a).unwrap();
    let socket_b = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket_b
        .set_read_timeout(Some(Duration::from_millis(250)))
        .unwrap();
    let mut client_b = client_tunnel(private_b.clone(), server_public, 11);
    let (_, receiver_b) = handshake(&socket_b, wireguard, &mut client_b).unwrap();
    assert_ne!(
        receiver_a, receiver_b,
        "receiver index must not cross peers"
    );
    assert!(receiver_a <= 0x00ff_ffff && receiver_b <= 0x00ff_ffff);

    let ping = icmp_echo_request([10, 26, 0, 2], [10, 26, 0, 1]);
    send_inner_ipv4(&socket_a, wireguard, &mut client_a, &ping);
    let pong = receive_inner_ipv4(&socket_a, wireguard, &mut client_a);
    assert_eq!(&pong[12..16], &[10, 26, 0, 1]);
    assert_eq!(&pong[16..20], &[10, 26, 0, 2]);
    assert_eq!(pong[20], 0, "gateway must answer with ICMP Echo Reply");
    assert_eq!(internet_checksum(&pong[..20]), 0);
    assert_eq!(internet_checksum(&pong[20..]), 0);

    let maximum = ipv4_packet_to([10, 26, 0, 2], [10, 26, 0, 3], 1420);
    send_inner_ipv4(&socket_a, wireguard, &mut client_a, &maximum);
    assert_eq!(
        receive_inner_ipv4(&socket_b, wireguard, &mut client_b),
        maximum,
        "maximum-size IPv4 packet must bridge from peer A to peer B"
    );

    let reply = ipv4_packet_to([10, 26, 0, 3], [10, 26, 0, 2], 128);
    send_inner_ipv4(&socket_b, wireguard, &mut client_b, &reply);
    assert_eq!(
        receive_inner_ipv4(&socket_a, wireguard, &mut client_a),
        reply,
        "IPv4 reply must bridge from peer B to peer A"
    );

    let oversized = ipv4_packet_to([10, 26, 0, 2], [10, 26, 0, 3], 1421);
    send_inner_ipv4(&socket_a, wireguard, &mut client_a, &oversized);
    assert_no_udp_response(&socket_b);

    let multicast = ipv4_packet_to([10, 26, 0, 2], [224, 0, 0, 1], 20);
    send_inner_ipv4(&socket_a, wireguard, &mut client_a, &multicast);
    assert_eq!(
        receive_inner_ipv4(&socket_b, wireguard, &mut client_b),
        multicast,
        "WireGuard multicast must fan out to other WireGuard peers"
    );

    let mut capacity = client_tunnel(private_capacity.clone(), server_public, 12);
    assert_no_handshake(&socket_a, wireguard, &mut capacity);

    reserve_ip(http, &token, "peer-a", "10.26.0.6");
    let stale_after_move = ipv4_packet_to([10, 26, 0, 2], [10, 26, 0, 3], 20);
    send_inner_ipv4(&socket_a, wireguard, &mut client_a, &stale_after_move);
    assert_no_udp_response(&socket_b);
    let mut moved_a = client_tunnel(private_a.clone(), server_public, 13);
    handshake(&socket_a, wireguard, &mut moved_a).unwrap();

    release_ip(http, &token, "peer-b");
    let mut released_b = client_tunnel(private_b.clone(), server_public, 14);
    assert_no_handshake(&socket_b, wireguard, &mut released_b);
    reserve_ip(http, &token, "peer-b", "10.26.0.3");
    let mut rereserved_b = client_tunnel(private_b.clone(), server_public, 15);
    handshake(&socket_b, wireguard, &mut rereserved_b).unwrap();

    let disable = http_request(
        http,
        "PUT",
        "/api/wireguard/peers/enabled",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"peer-a","enabled":false}"#),
    );
    assert_api_ok(&disable);
    let mut disabled_after_return = client_tunnel(private_a.clone(), server_public, 16);
    assert_no_handshake(&socket_a, wireguard, &mut disabled_after_return);

    let enable = http_request(
        http,
        "PUT",
        "/api/wireguard/peers/enabled",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"peer-a","enabled":true}"#),
    );
    assert_api_ok(&enable);
    let mut reenabled_a = client_tunnel(private_a.clone(), server_public, 17);
    handshake(&socket_a, wireguard, &mut reenabled_a).unwrap();

    let delete = http_request(
        http,
        "DELETE",
        "/api/wireguard/peers?network_code=network-a&peer_id=peer-b",
        Some(&token),
        None,
    );
    assert_api_ok(&delete);
    let mut deleted_after_return = client_tunnel(private_b, server_public, 18);
    assert_no_handshake(&socket_b, wireguard, &mut deleted_after_return);

    let roam_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    roam_socket
        .set_read_timeout(Some(Duration::from_millis(150)))
        .unwrap();
    let mut buffer = vec![0; 2048];
    let wrong_source =
        network_packet(reenabled_a.encapsulate(&ipv4_packet([10, 26, 0, 99]), &mut buffer));
    roam_socket.send_to(&wrong_source, wireguard).unwrap();
    assert_no_udp_response(&roam_socket);
    let ipv6 = network_packet(reenabled_a.encapsulate(&ipv6_packet(), &mut buffer));
    roam_socket.send_to(&ipv6, wireguard).unwrap();
    assert_no_udp_response(&roam_socket);
    let allowed_but_not_bridged =
        network_packet(reenabled_a.encapsulate(&ipv4_packet([10, 26, 0, 6]), &mut buffer));
    roam_socket
        .send_to(&allowed_but_not_bridged, wireguard)
        .unwrap();
    assert_no_udp_response(&roam_socket);

    thread::sleep(Duration::from_millis(1100));
    let flood_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    flood_socket
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let mut flood = client_tunnel(private_key(0x7e), server_public, 19);
    for _ in 0..120 {
        let initiation = network_packet(flood.format_handshake_initiation(&mut buffer, true));
        flood_socket.send_to(&initiation, wireguard).unwrap();
    }
    let mut cookie = vec![0; 2048];
    let mut challenged = false;
    while let Ok((length, _)) = flood_socket.recv_from(&mut cookie) {
        if length == 64 && u32::from_le_bytes(cookie[0..4].try_into().unwrap()) == 3 {
            challenged = true;
            break;
        }
    }
    assert!(
        challenged,
        "global handshake limit must issue a Cookie Reply"
    );

    server.stop();
}

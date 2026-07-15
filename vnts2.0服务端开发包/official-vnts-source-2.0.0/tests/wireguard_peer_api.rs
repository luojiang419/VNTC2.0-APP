use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use x25519_dalek::{PublicKey, StaticSecret};

const CREATE_NO_WINDOW: u32 = 0x08000000;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "vnts2-wireguard-peer-api-{}-{unique}",
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
    headers: String,
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

fn unused_local_addr() -> SocketAddr {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
}

fn unused_local_udp_addr() -> SocketAddr {
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
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
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
    let status = head
        .lines()
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    HttpResponse {
        status,
        headers: head.to_string(),
        body: body.to_string(),
    }
}

fn login(address: SocketAddr) -> String {
    let response = http_request(
        address,
        "POST",
        "/api/login",
        None,
        Some(r#"{"username":"api-admin","password":"api-password"}"#),
    );
    assert_eq!(response.status, 200, "login response: {}", response.body);
    assert_api_code(&response, 200);
    response
        .body
        .split_once("\"token\":\"")
        .and_then(|(_, suffix)| suffix.split('"').next())
        .unwrap()
        .to_string()
}

fn assert_api_code(response: &HttpResponse, code: i32) {
    assert!(
        response.body.contains(&format!(r#""code":{code}"#)),
        "unexpected API response: status={}, body={}",
        response.status,
        response.body
    );
}

fn json_string(body: &str, field: &str) -> String {
    body.split_once(&format!(r#""{field}":""#))
        .and_then(|(_, suffix)| suffix.split('"').next())
        .unwrap_or_else(|| panic!("missing JSON string field '{field}' in {body}"))
        .to_string()
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

#[test]
fn peer_management_api_is_authenticated_persistent_and_ip_consistent() {
    let directory = TestDirectory::new();
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let config = directory.0.join("config.toml");
    let address = unused_local_addr();
    let persistent_config = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
         network = \"10.89.0.0/24\"\n\
         white_list = []\n\
         lease_duration = 60\n\
         web_bind = \"{address}\"\n\
         username = \"api-admin\"\n\
         password = \"api-password\"\n\
         persistence = true\n\
         [custom_nets]\n\
         network-a = \"10.26.0.0/24\"\n\
         network-b = \"10.27.0.0/24\"\n"
    );
    fs::write(&config, &persistent_config).unwrap();

    let public_key = BASE64_STANDARD.encode([0x42; 32]);
    let create_body = format!(
        r#"{{"network_code":"network-a","peer_id":"peer-a","public_key":"{public_key}","enabled":false}}"#
    );

    let mut initial_server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(initial_server.child_mut(), address);

    let unauthorized = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        None,
        Some(&create_body),
    );
    assert_eq!(unauthorized.status, 401);
    assert_api_code(&unauthorized, 401);

    let token = login(address);
    let generated_without_config = http_request(
        address,
        "POST",
        "/api/wireguard/peers/generated",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"not-created"}"#),
    );
    assert_eq!(generated_without_config.status, 503);
    assert_api_code(&generated_without_config, 503);
    assert!(generated_without_config.body.contains("WireGuard UDP"));
    assert!(!generated_without_config.body.contains("private_key"));

    let server_status = http_request(address, "GET", "/api/status", Some(&token), None);
    assert_eq!(server_status.status, 200);
    assert_api_code(&server_status, 200);
    assert!(server_status.body.contains(r#""version":"2.0.0""#));
    assert!(
        server_status
            .body
            .contains(r#""persistence_enabled":true,"ready":true"#)
    );
    assert!(server_status.body.contains(r#""web":"127.0.0.1:"#));
    assert!(server_status.body.contains(r#""active_peers":0"#));
    assert!(!server_status.body.contains("password"));
    assert!(!server_status.body.contains("jwt"));

    let invalid_key = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"invalid-key","public_key":"not-base64"}"#),
    );
    assert_eq!(invalid_key.status, 400);
    assert_api_code(&invalid_key, 400);

    let created = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&token),
        Some(&create_body),
    );
    assert_api_code(&created, 200);
    assert!(created.body.contains(r#""peer_id":"peer-a""#));
    assert!(
        created
            .body
            .contains(&format!(r#""public_key":"{public_key}""#))
    );
    assert!(created.body.contains(r#""enabled":false"#));
    assert!(created.body.contains(r#""ip":null"#));
    assert!(created.body.contains(r#""created_at":"#));
    assert!(created.body.contains(r#""updated_at":"#));

    let duplicate_peer = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&token),
        Some(&create_body),
    );
    assert_eq!(duplicate_peer.status, 409);
    assert_api_code(&duplicate_peer, 409);

    let reserved = http_request(
        address,
        "PUT",
        "/api/wireguard/peer_ips",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"peer-a","ip":"10.26.0.2"}"#),
    );
    assert_api_code(&reserved, 200);

    let listed = http_request(
        address,
        "GET",
        "/api/wireguard/peers?network_code=network-a",
        Some(&token),
        None,
    );
    assert_api_code(&listed, 200);
    assert!(listed.body.contains(r#""ip":"10.26.0.2""#));

    let enabled = http_request(
        address,
        "PUT",
        "/api/wireguard/peers/enabled",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"peer-a","enabled":true}"#),
    );
    assert_api_code(&enabled, 200);
    assert!(enabled.body.contains(r#""enabled":true"#));
    assert!(enabled.body.contains(r#""ip":"10.26.0.2""#));

    let enabled_again = http_request(
        address,
        "PUT",
        "/api/wireguard/peers/enabled",
        Some(&token),
        Some(r#"{"network_code":"network-a","peer_id":"peer-a","enabled":true}"#),
    );
    assert_api_code(&enabled_again, 200);
    assert!(enabled_again.body.contains(r#""enabled":true"#));
    assert!(enabled_again.body.contains(r#""ip":"10.26.0.2""#));

    let duplicate_key_body =
        format!(r#"{{"network_code":"network-b","peer_id":"peer-b","public_key":"{public_key}"}}"#);
    let duplicate_key = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&token),
        Some(&duplicate_key_body),
    );
    assert_eq!(duplicate_key.status, 409);
    assert_api_code(&duplicate_key, 409);

    let default_public_key = BASE64_STANDARD.encode([0x43; 32]);
    let default_enabled_body = format!(
        r#"{{"network_code":"network-b","peer_id":"peer-default","public_key":"{default_public_key}"}}"#
    );
    let default_enabled = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&token),
        Some(&default_enabled_body),
    );
    assert_api_code(&default_enabled, 200);
    assert!(default_enabled.body.contains(r#""enabled":true"#));
    let default_deleted = http_request(
        address,
        "DELETE",
        "/api/wireguard/peers?network_code=network-b&peer_id=peer-default",
        Some(&token),
        None,
    );
    assert_api_code(&default_deleted, 200);
    assert!(default_deleted.body.contains(r#""peer_removed":true"#));
    assert!(default_deleted.body.contains(r#""ip_released":false"#));
    initial_server.stop();

    let mut restarted_server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(restarted_server.child_mut(), address);
    let restarted_token = login(address);
    let persisted = http_request(
        address,
        "GET",
        "/api/wireguard/peers?network_code=network-a",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&persisted, 200);
    assert!(persisted.body.contains(r#""peer_id":"peer-a""#));
    assert!(persisted.body.contains(r#""enabled":true"#));
    assert!(persisted.body.contains(r#""ip":"10.26.0.2""#));

    let deleted = http_request(
        address,
        "DELETE",
        "/api/wireguard/peers?network_code=network-a&peer_id=peer-a",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&deleted, 200);
    assert!(deleted.body.contains(r#""peer_removed":true"#));
    assert!(deleted.body.contains(r#""ip_released":true"#));

    let deleted_again = http_request(
        address,
        "DELETE",
        "/api/wireguard/peers?network_code=network-a&peer_id=peer-a",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&deleted_again, 200);
    assert!(deleted_again.body.contains(r#""peer_removed":false"#));
    assert!(deleted_again.body.contains(r#""ip_released":false"#));

    let empty_peers = http_request(
        address,
        "GET",
        "/api/wireguard/peers?network_code=network-a",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&empty_peers, 200);
    assert!(empty_peers.body.contains(r#""data":[]"#));
    let empty_ips = http_request(
        address,
        "GET",
        "/api/wireguard/peer_ips?network_code=network-a",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&empty_ips, 200);
    assert!(empty_ips.body.contains(r#""data":[]"#));
    restarted_server.stop();

    let no_persistence_config =
        persistent_config.replace("persistence = true", "persistence = false");
    fs::write(&config, no_persistence_config).unwrap();
    let mut no_persistence_server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(no_persistence_server.child_mut(), address);
    let no_persistence_token = login(address);
    let network = http_request(
        address,
        "POST",
        "/api/networks",
        Some(&no_persistence_token),
        Some(
            r#"{"network_code":"network-a","gateway":"10.26.0.1","netmask":24,"lease_duration":60}"#,
        ),
    );
    assert_api_code(&network, 200);
    let rejected_without_persistence = http_request(
        address,
        "POST",
        "/api/wireguard/peers",
        Some(&no_persistence_token),
        Some(&create_body),
    );
    assert_eq!(rejected_without_persistence.status, 503);
    assert_api_code(&rejected_without_persistence, 503);
    assert!(
        rejected_without_persistence.body.contains("服务暂不可用"),
        "unexpected persistence-disabled response: {}",
        rejected_without_persistence.body
    );
    assert!(!rejected_without_persistence.body.contains("SQLite"));
    no_persistence_server.stop();
}

#[test]
fn generated_peer_api_auto_starts_wireguard_after_live_config_update() {
    let directory = TestDirectory::new();
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let config = directory.0.join("config.toml");
    let master_key = directory.0.join("wireguard-master.key");
    let address = unused_local_addr();
    let initial_config = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
             network = \"10.89.0.0/24\"\n\
             white_list = []\n\
             lease_duration = 60\n\
             web_bind = \"{address}\"\n\
             username = \"api-admin\"\n\
             password = \"api-password\"\n\
             persistence = true\n\
             [custom_nets]\n\
             autostart-network = \"10.45.0.0/24\"\n"
    );
    fs::write(&config, &initial_config).unwrap();

    let mut server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(server.child_mut(), address);
    let token = login(address);
    let initial_status = http_request(address, "GET", "/api/status", Some(&token), None);
    assert_api_code(&initial_status, 200);
    assert!(initial_status.body.contains(r#""configured":false"#));
    assert!(initial_status.body.contains(r#""running":false"#));

    fs::write(&master_key, [0x4b; 32]).unwrap();
    let enabled_config = initial_config.replace(
        "[custom_nets]",
        "wireguard_master_key_file = \"wireguard-master.key\"\n\
         wireguard_bind = \"127.0.0.1:0\"\n\
         wireguard_public_endpoint = \"vpn.example.com:51820\"\n\
         wireguard_max_active_peers = 64\n\
         [custom_nets]",
    );
    fs::write(&config, enabled_config).unwrap();

    let barrier = Arc::new(Barrier::new(3));
    let (first, second) = thread::scope(|scope| {
        let first_barrier = barrier.clone();
        let first_token = token.clone();
        let first = scope.spawn(move || {
            first_barrier.wait();
            http_request(
                address,
                "POST",
                "/api/wireguard/peers/generated",
                Some(&first_token),
                Some(r#"{"network_code":"autostart-network","peer_id":"auto-peer-a"}"#),
            )
        });
        let second_barrier = barrier.clone();
        let second_token = token.clone();
        let second = scope.spawn(move || {
            second_barrier.wait();
            http_request(
                address,
                "POST",
                "/api/wireguard/peers/generated",
                Some(&second_token),
                Some(r#"{"network_code":"autostart-network","peer_id":"auto-peer-b"}"#),
            )
        });
        barrier.wait();
        (first.join().unwrap(), second.join().unwrap())
    });

    for generated in [&first, &second] {
        assert_eq!(
            generated.status, 200,
            "generated response: {}",
            generated.body
        );
        assert_api_code(generated, 200);
        assert!(
            generated
                .body
                .contains(r#""endpoint":"vpn.example.com:51820""#)
        );
        assert!(generated.body.contains(r#""listen_addr":"127.0.0.1:"#));
        assert!(generated.body.contains("private_key"));
    }
    assert!(first.body.contains(r#""peer_id":"auto-peer-a""#));
    assert!(second.body.contains(r#""peer_id":"auto-peer-b""#));

    let running_status = http_request(address, "GET", "/api/status", Some(&token), None);
    assert_api_code(&running_status, 200);
    assert!(running_status.body.contains(r#""configured":true"#));
    assert!(running_status.body.contains(r#""running":true"#));
    server.stop();
}

#[test]
fn generated_peer_api_returns_one_time_key_material_and_persists_only_public_identity() {
    let directory = TestDirectory::new();
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_vnts2"));
    let config = directory.0.join("config.toml");
    let master_key = directory.0.join("wireguard-master.key");
    let database = directory.0.join("network_control.db");
    let address = unused_local_addr();
    let wireguard_address = unused_local_udp_addr();
    fs::write(&master_key, [0x6a; 32]).unwrap();
    let config_without_endpoint = format!(
        "tcp_bind = \"127.0.0.1:0\"\n\
             network = \"10.89.0.0/24\"\n\
             white_list = []\n\
             lease_duration = 60\n\
             web_bind = \"{address}\"\n\
             username = \"api-admin\"\n\
             password = \"api-password\"\n\
             persistence = true\n\
             wireguard_master_key_file = \"wireguard-master.key\"\n\
             wireguard_bind = \"{wireguard_address}\"\n\
             [custom_nets]\n\
             generated-network = \"10.44.0.0/24\"\n"
    );
    fs::write(&config, &config_without_endpoint).unwrap();

    let request_body = r#"{"network_code":"generated-network","peer_id":"alice-laptop"}"#;
    let mut server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(server.child_mut(), address);

    let unauthorized = http_request(
        address,
        "POST",
        "/api/wireguard/peers/generated",
        None,
        Some(request_body),
    );
    assert_eq!(unauthorized.status, 401);
    assert_api_code(&unauthorized, 401);

    let token = login(address);
    let generated = http_request(
        address,
        "POST",
        "/api/wireguard/peers/generated",
        Some(&token),
        Some(request_body),
    );
    assert_eq!(
        generated.status, 200,
        "generated response: {}",
        generated.body
    );
    assert_api_code(&generated, 200);
    assert!(
        generated
            .headers
            .to_ascii_lowercase()
            .contains("cache-control: no-store")
    );
    assert!(generated.body.contains(r#""peer_id":"alice-laptop""#));
    assert!(generated.body.contains(r#""ip":"10.44.0.2""#));
    assert!(generated.body.contains(r#""allowed_ips":"10.44.0.0/24""#));
    assert!(
        generated
            .body
            .contains(&format!(r#""endpoint":"{wireguard_address}""#))
    );
    assert!(
        generated
            .body
            .contains(&format!(r#""listen_addr":"{wireguard_address}""#))
    );

    let private_key_text = json_string(&generated.body, "private_key");
    let public_key_text = json_string(&generated.body, "public_key");
    let server_public_key_text = json_string(&generated.body, "server_public_key");
    let private_key: [u8; 32] = BASE64_STANDARD
        .decode(&private_key_text)
        .unwrap()
        .try_into()
        .unwrap();
    let public_key: [u8; 32] = BASE64_STANDARD
        .decode(&public_key_text)
        .unwrap()
        .try_into()
        .unwrap();
    let server_public_key: [u8; 32] = BASE64_STANDARD
        .decode(&server_public_key_text)
        .unwrap()
        .try_into()
        .unwrap();
    assert_eq!(
        PublicKey::from(&StaticSecret::from(private_key)).to_bytes(),
        public_key
    );
    assert_ne!(server_public_key, public_key);
    let status = http_request(address, "GET", "/api/status", Some(&token), None);
    assert_api_code(&status, 200);
    assert_eq!(
        json_string(&status.body, "public_key"),
        server_public_key_text
    );

    let duplicate = http_request(
        address,
        "POST",
        "/api/wireguard/peers/generated",
        Some(&token),
        Some(request_body),
    );
    assert_eq!(duplicate.status, 409);
    assert_api_code(&duplicate, 409);
    assert!(!duplicate.body.contains("private_key"));

    let listed = http_request(
        address,
        "GET",
        "/api/wireguard/peers?network_code=generated-network",
        Some(&token),
        None,
    );
    assert_api_code(&listed, 200);
    assert!(
        listed
            .body
            .contains(&format!(r#""public_key":"{public_key_text}""#))
    );
    assert!(listed.body.contains(r#""ip":"10.44.0.2""#));
    assert!(!listed.body.contains(&private_key_text));
    server.stop();

    let database_bytes = fs::read(&database).unwrap();
    assert!(!contains_bytes(
        &database_bytes,
        private_key_text.as_bytes()
    ));
    assert!(!contains_bytes(&database_bytes, &private_key));

    let mut restarted_server = ChildGuard::spawn(server_command(&binary, &config));
    wait_for_http(restarted_server.child_mut(), address);
    let restarted_token = login(address);
    let persisted = http_request(
        address,
        "GET",
        "/api/wireguard/peers?network_code=generated-network",
        Some(&restarted_token),
        None,
    );
    assert_api_code(&persisted, 200);
    assert!(
        persisted
            .body
            .contains(&format!(r#""public_key":"{public_key_text}""#))
    );
    assert!(persisted.body.contains(r#""ip":"10.44.0.2""#));
    assert!(!persisted.body.contains(&private_key_text));
    restarted_server.stop();
}

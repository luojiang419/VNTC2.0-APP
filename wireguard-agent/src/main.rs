use anyhow::{Context, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use prost::Message;
use rand::Rng;
use std::collections::HashMap;
use std::env;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::process::Command;
use tokio::sync::Mutex;
use tokio::time::{Instant, timeout};

const CONTROL_PORT: u16 = 51_821;
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(3);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(8);
const HANDSHAKE_POLL_INTERVAL: Duration = Duration::from_millis(500);
const MAX_HANDSHAKE_AGE: Duration = Duration::from_secs(180);
const REFRESH_INTERVAL: Duration = Duration::from_secs(20);
const RETRY_INTERVAL: Duration = Duration::from_secs(5);
const MAX_LEASE_AHEAD_MS: u64 = 120_000;

#[derive(Clone, PartialEq, Message)]
struct WireGuardP2pAgentRequest {
    #[prost(fixed32, tag = "1")]
    target_ip: u32,
    #[prost(uint64, tag = "2")]
    request_id: u64,
}

#[derive(Clone, PartialEq, Message)]
struct WireGuardP2pAgentResponse {
    #[prost(uint64, tag = "1")]
    request_id: u64,
    #[prost(enumeration = "WireGuardP2pStatus", tag = "2")]
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
enum WireGuardP2pStatus {
    Ok = 0,
    NotFound = 1,
    NotCapable = 2,
    Rejected = 3,
    Busy = 4,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Lease {
    public_key: [u8; 32],
    endpoint: SocketAddr,
    lease_id: u64,
    expires_at_unix_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Config {
    interface: String,
    gateway: Ipv4Addr,
    wg_path: PathBuf,
    targets: Vec<Ipv4Addr>,
}

impl Config {
    fn parse(args: impl IntoIterator<Item = String>) -> anyhow::Result<Self> {
        let mut args = args.into_iter();
        let _program = args.next();
        let mut interface = None;
        let mut gateway = None;
        let mut wg_path = PathBuf::from(if cfg!(windows) { "wg.exe" } else { "wg" });
        let mut targets = Vec::new();
        while let Some(arg) = args.next() {
            let value = || anyhow::anyhow!("{arg} requires a value");
            match arg.as_str() {
                "--interface" => interface = Some(args.next().ok_or_else(value)?),
                "--gateway" => {
                    gateway = Some(
                        args.next()
                            .ok_or_else(value)?
                            .parse()
                            .context("invalid gateway")?,
                    )
                }
                "--wg" => wg_path = PathBuf::from(args.next().ok_or_else(value)?),
                "--target" => targets.push(
                    args.next()
                        .ok_or_else(value)?
                        .parse()
                        .context("invalid target")?,
                ),
                "--help" | "-h" => {
                    println!(
                        "Usage: vnts-wireguard-agent --interface <name> --gateway <IPv4> --target <IPv4> [--target <IPv4> ...] [--wg <path>]"
                    );
                    std::process::exit(0);
                }
                _ => bail!("unknown argument: {arg}"),
            }
        }
        let interface = interface.context("--interface is required")?;
        let gateway = gateway.context("--gateway is required")?;
        if targets.is_empty() {
            bail!("at least one --target is required");
        }
        targets.sort_unstable();
        targets.dedup();
        if targets.contains(&gateway) {
            bail!("gateway cannot be a P2P target");
        }
        Ok(Self {
            interface,
            gateway,
            wg_path,
            targets,
        })
    }
}

#[derive(Clone)]
struct WgCli {
    path: PathBuf,
    interface: String,
}

impl WgCli {
    async fn run(&self, args: &[String]) -> anyhow::Result<String> {
        let output = Command::new(&self.path)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .await
            .with_context(|| format!("failed to run {}", self.path.display()))?;
        if !output.status.success() {
            bail!(
                "wg command failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        String::from_utf8(output.stdout).context("wg output is not UTF-8")
    }

    async fn probe(&self, public_key: &str, endpoint: SocketAddr) -> anyhow::Result<()> {
        self.run(&probe_args(&self.interface, public_key, endpoint))
            .await?;
        Ok(())
    }

    async fn activate(&self, public_key: &str, target: Ipv4Addr) -> anyhow::Result<()> {
        self.run(&activate_args(&self.interface, public_key, target))
            .await?;
        Ok(())
    }

    async fn remove(&self, public_key: &str) -> anyhow::Result<()> {
        self.run(&remove_args(&self.interface, public_key)).await?;
        Ok(())
    }

    async fn latest_handshake(&self, public_key: &str) -> anyhow::Result<u64> {
        let output = self
            .run(&[
                "show".to_string(),
                self.interface.clone(),
                "latest-handshakes".to_string(),
            ])
            .await?;
        Ok(parse_latest_handshake(&output, public_key).unwrap_or_default())
    }
}

fn probe_args(interface: &str, public_key: &str, endpoint: SocketAddr) -> Vec<String> {
    vec![
        "set".into(),
        interface.into(),
        "peer".into(),
        public_key.into(),
        "endpoint".into(),
        endpoint.to_string(),
        "persistent-keepalive".into(),
        "15".into(),
    ]
}

fn activate_args(interface: &str, public_key: &str, target: Ipv4Addr) -> Vec<String> {
    vec![
        "set".into(),
        interface.into(),
        "peer".into(),
        public_key.into(),
        "allowed-ips".into(),
        format!("{target}/32"),
    ]
}

fn remove_args(interface: &str, public_key: &str) -> Vec<String> {
    vec![
        "set".into(),
        interface.into(),
        "peer".into(),
        public_key.into(),
        "remove".into(),
    ]
}

fn parse_latest_handshake(output: &str, public_key: &str) -> Option<u64> {
    output.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        (fields.next()? == public_key)
            .then(|| fields.next()?.parse().ok())
            .flatten()
    })
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn validate_response(bytes: &[u8], request_id: u64, target: Ipv4Addr) -> anyhow::Result<Lease> {
    let response = WireGuardP2pAgentResponse::decode(bytes)?;
    if response.request_id != request_id || Ipv4Addr::from(response.target_ip) != target {
        bail!("mismatched P2P response");
    }
    if response.status != WireGuardP2pStatus::Ok as i32 {
        bail!("P2P target is unavailable (status={})", response.status);
    }
    let public_key: [u8; 32] = response
        .target_public_key
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid target public key"))?;
    let endpoint: SocketAddr = response
        .target_endpoint
        .parse()
        .context("invalid target endpoint")?;
    if !endpoint.is_ipv4() {
        bail!("target endpoint is not IPv4");
    }
    let now = unix_ms();
    if response.lease_id == 0
        || response.expires_at_unix_ms <= now
        || response.expires_at_unix_ms.saturating_sub(now) > MAX_LEASE_AHEAD_MS
    {
        bail!("invalid P2P lease lifetime");
    }
    Ok(Lease {
        public_key,
        endpoint,
        lease_id: response.lease_id,
        expires_at_unix_ms: response.expires_at_unix_ms,
    })
}

async fn discover(gateway: Ipv4Addr, target: Ipv4Addr) -> anyhow::Result<Lease> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    socket.connect((gateway, CONTROL_PORT)).await?;
    let request_id = loop {
        let candidate = rand::rng().random::<u64>();
        if candidate != 0 {
            break candidate;
        }
    };
    let request = WireGuardP2pAgentRequest {
        target_ip: target.into(),
        request_id,
    }
    .encode_to_vec();
    socket.send(&request).await?;
    let mut buffer = [0u8; 1024];
    let length = timeout(DISCOVERY_TIMEOUT, socket.recv(&mut buffer))
        .await
        .context("P2P discovery timed out")??;
    validate_response(&buffer[..length], request_id, target)
}

async fn wait_for_handshake(wg: &WgCli, public_key: &str, started: u64) -> anyhow::Result<bool> {
    let deadline = Instant::now() + HANDSHAKE_TIMEOUT;
    loop {
        if wg.latest_handshake(public_key).await? >= started {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        tokio::time::sleep(HANDSHAKE_POLL_INTERVAL).await;
    }
}

async fn run_target(
    gateway: Ipv4Addr,
    target: Ipv4Addr,
    wg: WgCli,
    managed: Arc<Mutex<HashMap<Ipv4Addr, String>>>,
) {
    loop {
        let result = async {
            let lease = discover(gateway, target).await?;
            let public_key = BASE64_STANDARD.encode(lease.public_key);
            let previous = managed.lock().await.get(&target).cloned();
            let same_peer = previous.as_deref() == Some(public_key.as_str());
            if let Some(previous) = previous
                && !same_peer
            {
                let _ = wg.remove(&previous).await;
            }
            wg.probe(&public_key, lease.endpoint).await?;
            managed.lock().await.insert(target, public_key.clone());
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let latest = wg.latest_handshake(&public_key).await?;
            let still_fresh = same_peer
                && latest > 0
                && now.saturating_sub(latest) <= MAX_HANDSHAKE_AGE.as_secs();
            if !still_fresh && !wait_for_handshake(&wg, &public_key, now.saturating_sub(1)).await? {
                wg.remove(&public_key).await?;
                managed.lock().await.remove(&target);
                bail!("direct handshake timed out");
            }
            wg.activate(&public_key, target).await?;
            anyhow::Ok(())
        }
        .await;

        match result {
            Ok(()) => tokio::time::sleep(REFRESH_INTERVAL).await,
            Err(error) => {
                eprintln!("target {target}: {error:#}");
                if let Some(public_key) = managed.lock().await.remove(&target) {
                    let _ = wg.remove(&public_key).await;
                }
                tokio::time::sleep(RETRY_INTERVAL).await;
            }
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::parse(env::args())?;
    let wg = WgCli {
        path: config.wg_path,
        interface: config.interface,
    };
    let managed = Arc::new(Mutex::new(HashMap::new()));
    let mut tasks = Vec::new();
    for target in config.targets {
        tasks.push(tokio::spawn(run_target(
            config.gateway,
            target,
            wg.clone(),
            managed.clone(),
        )));
    }
    tokio::signal::ctrl_c().await?;
    for task in tasks {
        task.abort();
    }
    let peers: Vec<_> = managed.lock().await.drain().map(|(_, key)| key).collect();
    for peer in peers {
        let _ = wg.remove(&peer).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_requires_interface_gateway_and_targets() {
        let config = Config::parse([
            "agent".into(),
            "--interface".into(),
            "wg0".into(),
            "--gateway".into(),
            "10.26.0.1".into(),
            "--target".into(),
            "10.26.0.3".into(),
            "--target".into(),
            "10.26.0.3".into(),
        ])
        .unwrap();
        assert_eq!(config.targets, vec![Ipv4Addr::new(10, 26, 0, 3)]);
        assert!(Config::parse(["agent".into()]).is_err());
    }

    #[test]
    fn wg_commands_keep_route_absent_until_activation() {
        let endpoint: SocketAddr = "198.51.100.8:51820".parse().unwrap();
        let probe = probe_args("wg0", "key", endpoint);
        assert!(!probe.iter().any(|arg| arg == "allowed-ips"));
        assert!(
            activate_args("wg0", "key", Ipv4Addr::new(10, 26, 0, 3))
                .windows(2)
                .any(|args| args == ["allowed-ips", "10.26.0.3/32"])
        );
        assert_eq!(remove_args("wg0", "key").last().unwrap(), "remove");
    }

    #[test]
    fn response_validation_is_bound_to_request_target_key_and_short_lease() {
        let target = Ipv4Addr::new(10, 26, 0, 3);
        let response = WireGuardP2pAgentResponse {
            request_id: 7,
            status: WireGuardP2pStatus::Ok as i32,
            target_ip: target.into(),
            target_public_key: vec![0x2a; 32],
            target_endpoint: "198.51.100.8:51820".into(),
            lease_id: 9,
            expires_at_unix_ms: unix_ms() + 60_000,
        }
        .encode_to_vec();
        assert!(validate_response(&response, 7, target).is_ok());
        assert!(validate_response(&response, 8, target).is_err());
    }

    #[test]
    fn latest_handshake_parser_matches_only_the_managed_peer() {
        let output = "other\t20\nmanaged\t30\n";
        assert_eq!(parse_latest_handshake(output, "managed"), Some(30));
        assert_eq!(parse_latest_handshake(output, "missing"), None);
    }
}

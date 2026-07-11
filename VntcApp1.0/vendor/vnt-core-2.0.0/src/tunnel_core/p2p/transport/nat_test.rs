use crate::context::AppState;
use rust_p2p_core::nat::{NatInfo, NatType};
use rust_p2p_core::tunnel::SocketManager;
use rust_p2p_core::tunnel::udp::Model;
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const NETWORK_CHANGE_POLL_INTERVAL: Duration = Duration::from_secs(5);
const NAT_INFO_REFRESH_INTERVAL: Duration = Duration::from_secs(60 * 30);

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct LocalInterfaceFingerprint {
    ipv4: Vec<Ipv4Addr>,
    ipv6: Vec<Ipv6Addr>,
}

impl LocalInterfaceFingerprint {
    fn new(mut ipv4: Vec<Ipv4Addr>, mut ipv6: Vec<Ipv6Addr>) -> Self {
        ipv4.sort_unstable();
        ipv4.dedup();
        ipv6.sort_unstable();
        ipv6.dedup();
        Self { ipv4, ipv6 }
    }
}

pub async fn my_nat_info(app_context: AppState, socket_manager: SocketManager) {
    let mut last_fingerprint = local_interface_fingerprint(app_context.network.network().as_ref());
    my_nat_info_impl(&app_context, &socket_manager).await;
    let mut last_probe = Instant::now();

    loop {
        tokio::time::sleep(NETWORK_CHANGE_POLL_INTERVAL).await;
        let next_fingerprint = local_interface_fingerprint(app_context.network.network().as_ref());
        let network_changed = should_reprobe_for_network_change(
            last_fingerprint.as_ref(),
            next_fingerprint.as_ref(),
        );
        let periodic_refresh_due = last_probe.elapsed() >= NAT_INFO_REFRESH_INTERVAL;
        if network_changed || periodic_refresh_due {
            if network_changed {
                log::info!(
                    "local network addresses changed from {:?} to {:?}; re-probing NAT",
                    last_fingerprint,
                    next_fingerprint
                );
            }
            my_nat_info_impl(&app_context, &socket_manager).await;
            last_probe = Instant::now();
        }
        if next_fingerprint.is_some() {
            last_fingerprint = next_fingerprint;
        }
    }
}

fn local_interface_fingerprint(
    network: Option<&ipnet::Ipv4Net>,
) -> Option<LocalInterfaceFingerprint> {
    let mut ipv4 = Vec::new();
    let mut ipv6 = Vec::new();
    let addrs = match getifaddrs::getifaddrs() {
        Ok(addrs) => addrs,
        Err(error) => {
            log::warn!("getifaddrs failed while checking network changes: {error}");
            return None;
        }
    };
    for interface in addrs {
        let Some(ip) = interface.address.ip_addr() else {
            continue;
        };
        if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() {
            continue;
        }
        match ip {
            IpAddr::V4(addr) => {
                if addr.is_documentation() || addr.is_broadcast() {
                    continue;
                }
                if network.is_some_and(|network| network.contains(&addr)) {
                    continue;
                }
                ipv4.push(addr);
            }
            IpAddr::V6(addr) => {
                if addr.is_unique_local() || addr.is_unicast_link_local() {
                    continue;
                }
                ipv6.push(addr);
            }
        }
    }
    Some(LocalInterfaceFingerprint::new(ipv4, ipv6))
}

fn should_reprobe_for_network_change(
    previous: Option<&LocalInterfaceFingerprint>,
    current: Option<&LocalInterfaceFingerprint>,
) -> bool {
    matches!((previous, current), (Some(previous), Some(current)) if previous != current)
}

async fn my_nat_info_impl(app_context: &AppState, socket_manager: &SocketManager) {
    let network = app_context.network.network();
    let mut local_ipv4s = Vec::new();
    let mut local_ipv6 = Vec::new();
    match getifaddrs::getifaddrs() {
        Ok(addrs) => {
            for x in addrs {
                let Some(ip) = x.address.ip_addr() else {
                    continue;
                };
                if ip.is_loopback() {
                    continue;
                }
                if ip.is_unspecified() {
                    continue;
                }
                if ip.is_multicast() {
                    continue;
                }

                match ip {
                    IpAddr::V4(addr) => {
                        if addr.is_documentation() {
                            continue;
                        }
                        if addr.is_broadcast() {
                            continue;
                        }
                        if let Some(network) = &network
                            && network.contains(&addr)
                        {
                            continue;
                        }
                        local_ipv4s.push(addr);
                    }
                    IpAddr::V6(addr) => {
                        if addr.is_unique_local() {
                            continue;
                        }
                        if addr.is_unicast_link_local() {
                            continue;
                        }
                        local_ipv6.push(addr);
                    }
                }
            }
        }
        Err(e) => {
            log::error!("getifaddrs error: {e}");
        }
    }
    log::info!("local_ipv4s: {:?}", local_ipv4s);
    let local_ipv4 = rust_p2p_core::extend::addr::local_ipv4()
        .await
        .unwrap_or_else(|e| {
            log::warn!("local ipv4 failed {e:?}");
            local_ipv4s
                .first()
                .cloned()
                .unwrap_or(Ipv4Addr::UNSPECIFIED)
        });
    local_ipv4s = complete_local_ipv4s(local_ipv4s, local_ipv4);
    let mut ipv6 = rust_p2p_core::extend::addr::local_ipv6().await.ok();
    if let Some(addr) = ipv6 {
        if addr.is_loopback()
            || addr.is_unique_local()
            || addr.is_unicast_link_local()
            || addr.is_unspecified()
            || addr.is_multicast()
        {
            ipv6 = local_ipv6.first().cloned();
        }
    } else {
        ipv6 = local_ipv6.first().cloned();
    }
    let local_udp_ports = socket_manager
        .udp_socket_manager_as_ref()
        .unwrap()
        .local_ports()
        .unwrap();
    let local_tcp_port = socket_manager
        .tcp_socket_manager_as_ref()
        .unwrap()
        .local_addr()
        .port();
    log::info!(
        "local_ipv4={local_ipv4},ipv6={ipv6:?},local_udp_ports:{local_udp_ports:?},local_tcp_port:{local_tcp_port:?}"
    );
    let mut public_ports = local_udp_ports.clone();
    public_ports.fill(0);
    let mut nat_info = NatInfo {
        nat_type: NatType::Symmetric,
        public_ips: vec![],
        public_udp_ports: public_ports,
        mapping_tcp_addr: vec![],
        mapping_udp_addr: vec![],
        public_port_range: 0,
        local_ipv4s,
        local_ipv4,
        ipv6,
        local_udp_ports,
        local_tcp_port,
        public_tcp_port: 0,
    };
    let mut stun_server = app_context.udp_stun();
    if stun_server.is_empty() {
        stun_server = default_udp_stun();
    }
    let (nat_type, public_ips, port_range) = match rust_p2p_core::stun::stun_test_nat(
        stun_server,
        None,
    )
    .await
    {
        Ok(result) => result,
        Err(e) => {
            log::warn!(
                "stun_test_nat failed; use conservative symmetric NAT strategy until next probe: {e:?}"
            );
            (NatType::Symmetric, vec![], 0)
        }
    };
    log::info!("nat_type:{nat_type:?},public_ips:{public_ips:?},port_range={port_range}");
    nat_info.nat_type = nat_type;
    nat_info.public_ips = public_ips;
    nat_info.public_port_range = port_range;
    app_context.nat_info.replace_nat_info(nat_info);
    let model = match nat_type {
        NatType::Cone => Model::Low,
        NatType::Symmetric => Model::High,
    };
    if let Err(e) = socket_manager
        .udp_socket_manager_as_ref()
        .unwrap()
        .switch_model(model)
    {
        log::error!("switch_model error: {e:?}");
    }
}

fn complete_local_ipv4s(mut candidates: Vec<Ipv4Addr>, preferred: Ipv4Addr) -> Vec<Ipv4Addr> {
    if !preferred.is_unspecified() && !candidates.contains(&preferred) {
        candidates.insert(0, preferred);
    }
    candidates
}

pub async fn query_udp_public_addr_loop(app_context: AppState, socket_manager: SocketManager) {
    let mut udp_stun_servers = app_context.udp_stun();
    if udp_stun_servers.is_empty() {
        udp_stun_servers = default_udp_stun();
    }
    let udp_len = udp_stun_servers.len();
    let mut udp_count = 0;
    let stun_request = rust_p2p_core::stun::send_stun_request();
    loop {
        let stun = &udp_stun_servers[udp_count % udp_len];
        udp_count += 1;
        match tokio::net::lookup_host(stun.as_str()).await {
            Ok(mut addr) => {
                if let Some(addr) = addr.next()
                    && let Some(w) = socket_manager.udp_socket_manager_as_ref()
                    && let Err(e) = w.detect_pub_addrs(&stun_request, addr).await
                {
                    log::info!("detect_pub_addrs {e:?} {addr:?}");
                }
            }
            Err(e) => {
                log::info!("query_public_addr lookup_host {e:?} {stun:?}",);
            }
        }
        let not_port = app_context
            .get_nat_info()
            .map(|v| v.public_udp_ports.contains(&0))
            .unwrap_or(true);
        if not_port {
            tokio::time::sleep(Duration::from_secs(2)).await;
        } else {
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    }
}

pub(crate) async fn query_tcp_public_addr_loop(
    app_context: AppState,
    socket_manager: SocketManager,
) {
    use rand::Rng;
    use rand::seq::SliceRandom;

    let tcp_stun_servers = {
        let servers = app_context.tcp_stun();
        if servers.is_empty() {
            default_tcp_stun()
        } else {
            servers
        }
    };

    if tcp_stun_servers.is_empty() {
        return;
    }
    log::debug!("tcp_stun_servers = {tcp_stun_servers:?}");

    let stun_request = rust_p2p_core::stun::send_stun_request();
    let target_conn_count = tcp_stun_servers.len().min(2);
    let mut active_connections: HashMap<SocketAddr, (TcpStream, SocketAddr)> = HashMap::new();

    'outer: loop {
        while active_connections.len() < target_conn_count {
            let mut candidates: Vec<&String> = tcp_stun_servers.iter().collect();
            candidates.shuffle(&mut rand::rng());

            let mut connected = false;
            for stun in candidates {
                let addr = match tokio::net::lookup_host(stun.as_str()).await {
                    Ok(mut addrs) => addrs.next(),
                    Err(e) => {
                        log::debug!("lookup_host failed {stun} {e}");
                        continue;
                    }
                };

                let Some(addr) = addr else {
                    continue;
                };

                if active_connections.contains_key(&addr) {
                    continue;
                }

                let Some(w) = socket_manager.tcp_socket_manager_as_ref() else {
                    continue;
                };

                match tokio::time::timeout(Duration::from_secs(5), w.connect_reuse_port_raw(addr))
                    .await
                {
                    Ok(Ok(mut tcp_stream)) => {
                        let write_result = tokio::time::timeout(
                            Duration::from_secs(5),
                            tcp_stream.write_all(&stun_request),
                        )
                        .await;

                        if let Ok(Ok(_)) = write_result {
                            match stun_tcp_read(&mut tcp_stream).await {
                                Ok(pub_addr) => {
                                    log::debug!(
                                        "update_tcp_public_addr {stun} {addr} -> {pub_addr}"
                                    );

                                    let existing_pub_addr =
                                        active_connections.values().next().map(|(_, p)| *p);

                                    if let Some(existing) = existing_pub_addr
                                        && existing != pub_addr
                                    {
                                        log::debug!(
                                            "pub_addr mismatch: {existing} != {pub_addr}, wait 60s"
                                        );
                                        active_connections.clear();
                                        app_context.nat_info.update_tcp_public_addr(
                                            SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0).into(),
                                        );
                                        tokio::time::sleep(Duration::from_secs(5 * 60)).await;
                                        continue 'outer;
                                    }

                                    active_connections.insert(addr, (tcp_stream, pub_addr));
                                    connected = true;
                                    break;
                                }
                                Err(e) => {
                                    log::debug!("stun_tcp_read failed {stun} {addr} {e}");
                                }
                            }
                        } else {
                            log::debug!("write stun request failed {stun} {addr}");
                        }
                    }
                    Ok(Err(e)) => {
                        log::debug!("connect_reuse_port_raw failed {stun} {addr} {e}");
                    }
                    Err(_) => {
                        log::debug!("connect_reuse_port_raw timeout {stun} {addr}");
                    }
                }
            }

            if !connected {
                break;
            }
        }
        let existing_pub_addr = active_connections.values().next().map(|(_, p)| *p);
        if let Some(existing) = existing_pub_addr {
            app_context.nat_info.update_tcp_public_addr(existing);
        }

        let sleep_secs = rand::rng().random_range(10u64..=15);
        tokio::time::sleep(Duration::from_secs(sleep_secs)).await;

        let mut to_remove = Vec::new();
        let addrs: Vec<SocketAddr> = active_connections.keys().cloned().collect();

        for addr in addrs {
            let (tcp_stream, _) = active_connections.get_mut(&addr).unwrap();
            let mut buf = [0u8; 1024];

            match tcp_stream.try_read(&mut buf) {
                Ok(0) => {
                    log::warn!("stun tcp close {addr} EOF");
                    to_remove.push(addr);
                    continue;
                }
                Err(e) if e.kind() != std::io::ErrorKind::WouldBlock => {
                    log::warn!("stun tcp read error {addr} {e}");
                    to_remove.push(addr);
                    continue;
                }
                _ => {}
            }

            match tokio::time::timeout(Duration::from_secs(3), tcp_stream.write_all(&stun_request))
                .await
            {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => {
                    log::warn!("stun tcp write error {addr} {e}");
                    to_remove.push(addr);
                }
                Err(_) => {
                    log::warn!("stun tcp write timeout {addr}");
                    to_remove.push(addr);
                }
            }
        }

        for addr in to_remove {
            active_connections.remove(&addr);
        }
    }
}

async fn stun_tcp_read(tcp_stream: &mut TcpStream) -> io::Result<SocketAddr> {
    let mut head = [0; 20];
    match tokio::time::timeout(Duration::from_secs(5), tcp_stream.read_exact(&mut head)).await {
        Ok(rs) => rs?,
        Err(_) => Err(io::Error::from(io::ErrorKind::TimedOut))?,
    };
    let len = u16::from_be_bytes([head[2], head[3]]) as usize;
    let mut buf = vec![0; len + 20];
    buf[..20].copy_from_slice(&head);
    match tokio::time::timeout(
        Duration::from_secs(5),
        tcp_stream.read_exact(&mut buf[20..]),
    )
    .await
    {
        Ok(rs) => rs?,
        Err(_) => Err(io::Error::from(io::ErrorKind::TimedOut))?,
    };
    if let Some(addr) = rust_p2p_core::stun::recv_stun_response(&buf) {
        Ok(addr)
    } else {
        log::debug!("stun_tcp_read {buf:?}");
        Err(io::Error::from(io::ErrorKind::InvalidData))
    }
}

fn default_udp_stun() -> Vec<String> {
    vec![
        "stun.miwifi.com:3478".to_string(),
        "stun.chat.bilibili.com:3478".to_string(),
        "stun.l.google.com:19302".to_string(),
    ]
}

fn default_tcp_stun() -> Vec<String> {
    vec![
        "stun.flashdance.cx:3478".to_string(),
        "stun.sipnet.net:3478".to_string(),
        "stun.nextcloud.com:443".to_string(),
    ]
}

#[cfg(test)]
mod tests {
    use super::{
        LocalInterfaceFingerprint, NAT_INFO_REFRESH_INTERVAL, complete_local_ipv4s,
        should_reprobe_for_network_change,
    };
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::time::Duration;

    #[test]
    fn complete_local_ipv4s_preserves_all_interfaces_and_adds_preferred() {
        let wifi = Ipv4Addr::new(192, 168, 1, 20);
        let ethernet = Ipv4Addr::new(10, 0, 0, 20);
        let result = complete_local_ipv4s(vec![wifi], ethernet);

        assert_eq!(result, vec![ethernet, wifi]);
    }

    #[test]
    fn complete_local_ipv4s_does_not_duplicate_preferred_address() {
        let wifi = Ipv4Addr::new(192, 168, 1, 20);
        let result = complete_local_ipv4s(vec![wifi], wifi);

        assert_eq!(result, vec![wifi]);
    }

    #[test]
    fn interface_fingerprint_is_order_independent_and_deduplicated() {
        let wifi = Ipv4Addr::new(192, 168, 1, 20);
        let ethernet = Ipv4Addr::new(10, 0, 0, 20);
        let ipv6 = Ipv6Addr::LOCALHOST;
        let first = LocalInterfaceFingerprint::new(vec![wifi, ethernet, wifi], vec![ipv6]);
        let second = LocalInterfaceFingerprint::new(vec![ethernet, wifi], vec![ipv6, ipv6]);

        assert_eq!(first, second);
        assert!(!should_reprobe_for_network_change(Some(&first), Some(&second)));
    }

    #[test]
    fn interface_address_change_requests_nat_reprobe() {
        let previous = LocalInterfaceFingerprint::new(vec![Ipv4Addr::new(192, 168, 1, 20)], vec![]);
        let current = LocalInterfaceFingerprint::new(vec![Ipv4Addr::new(10, 0, 0, 20)], vec![]);

        assert!(should_reprobe_for_network_change(Some(&previous), Some(&current)));
        assert!(!should_reprobe_for_network_change(Some(&previous), None));
        assert_eq!(NAT_INFO_REFRESH_INTERVAL, Duration::from_secs(60 * 30));
    }
}

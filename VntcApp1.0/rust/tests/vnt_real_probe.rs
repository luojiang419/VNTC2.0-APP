use std::sync::{Arc, Mutex};

use flutter_rust_bridge::DartFnFuture;
use rust_lib_vnt_app::api::vnt_api::{
    RustConnectInfo, RustDeviceConfig, RustDeviceInfo, RustErrorInfo, RustHandshakeInfo,
    RustPeerClientInfo, RustRegisterInfo, VntApi, VntApiCallback, VntConfig,
};

fn ready<T: Send + 'static>(value: T) -> DartFnFuture<T> {
    Box::pin(async move { value })
}

#[test]
fn probe_real_quic_server_registers_virtual_ip() {
    if std::env::var("VNT_REAL_PROBE").ok().as_deref() != Some("1") {
        eprintln!("skip real VNT probe; set VNT_REAL_PROBE=1 to run");
        return;
    }

    let events = Arc::new(Mutex::new(Vec::<String>::new()));
    let push = |message: String| {
        let events = Arc::clone(&events);
        move || {
            let events = Arc::clone(&events);
            let message = message.clone();
            Box::pin(async move {
                events.lock().unwrap().push(message);
            }) as DartFnFuture<()>
        }
    };

    let connect_events = Arc::clone(&events);
    let register_events = Arc::clone(&events);
    let error_events = Arc::clone(&events);

    let call = VntApiCallback::new(
        push("success".to_string()),
        |_info: RustDeviceInfo| ready(()),
        move |info: RustConnectInfo| {
            let events = Arc::clone(&connect_events);
            Box::pin(async move {
                events
                    .lock()
                    .unwrap()
                    .push(format!("connect {} {}", info.count, info.address));
            })
        },
        |_info: RustHandshakeInfo| ready(true),
        move |info: RustRegisterInfo| {
            let events = Arc::clone(&register_events);
            Box::pin(async move {
                events.lock().unwrap().push(format!(
                    "register ip={} mask={} gateway={}",
                    info.virtual_ip, info.virtual_netmask, info.virtual_gateway
                ));
                true
            })
        },
        |_info: RustDeviceConfig| ready(0),
        |_info: Vec<RustPeerClientInfo>| ready(()),
        move |info: RustErrorInfo| {
            let events = Arc::clone(&error_events);
            Box::pin(async move {
                events
                    .lock()
                    .unwrap()
                    .push(format!("error {:?} {:?}", info.code, info.msg));
            })
        },
        push("stop".to_string()),
    );
    let server_address = std::env::var("VNT_PROBE_SERVER")
        .unwrap_or_else(|_| "quic://115.231.35.105:2225".to_string());

    let config = VntConfig {
        tap: false,
        token: "a".to_string(),
        device_id: format!("codex-probe-{}", std::process::id()),
        name: "codex-probe".to_string(),
        server_address_str: server_address,
        name_servers: Vec::new(),
        stun_server: Vec::new(),
        in_ips: Vec::new(),
        out_ips: Vec::new(),
        password: None,
        mtu: Some(1410),
        ip: None,
        no_proxy: false,
        server_encrypt: false,
        cipher_model: "__vnt_bridge_json__={\"cert_mode\":\"skip\",\"no_tun\":true}".to_string(),
        finger: false,
        punch_model: "all".to_string(),
        ports: None,
        first_latency: false,
        device_name: None,
        use_channel_type: "relay".to_string(),
        packet_loss_rate: None,
        packet_delay: 0,
        port_mapping_list: Vec::new(),
        compressor: "none".to_string(),
        allow_wire_guard: false,
        local_dev: None,
        disable_relay: false,
    };

    let api = VntApi::new(config, call).expect("real VNT register should succeed");
    let current = api.current_device();
    let event_log = events.lock().unwrap().join("\n");
    eprintln!("{event_log}");
    eprintln!(
        "current ip={} mask={} gateway={} network={} status={}",
        current.virtual_ip,
        current.virtual_netmask,
        current.virtual_gateway,
        current.virtual_network,
        current.status
    );

    assert!(
        !current.virtual_ip.is_empty() && current.virtual_ip != "0.0.0.0",
        "virtual ip should be assigned, events:\n{event_log}"
    );
}

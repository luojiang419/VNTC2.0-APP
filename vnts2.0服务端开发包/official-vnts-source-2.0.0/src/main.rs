use crate::server::TurnConfig;
use crate::server::control_server::service::ControlService;
use crate::server::peer_server::PeerServerManager;
use crate::utils::config::ConfigFile;
use anyhow::Context;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64_STANDARD};
use clap::Parser;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

mod http;
mod protocol;
mod server;
mod utils;
#[cfg(windows)]
mod windows_service;

#[derive(Clone, Debug, Parser)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// 配置文件路径，默认 ./config.toml
    #[arg(short, long)]
    conf: Option<PathBuf>,
    /// 输出配置文件示例
    #[clap(long)]
    pub conf_example: bool,
    /// 停机轮换 WireGuard 加密主密钥；参数为新的32字节主密钥文件
    #[arg(
        long,
        value_name = "NEW_KEY_FILE",
        requires = "conf",
        conflicts_with_all = ["conf_example", "rotate_wireguard_identity"]
    )]
    rotate_wireguard_master_key: Option<PathBuf>,
    /// 停机轮换 WireGuard 服务端身份；立即切换且不保留旧身份
    #[arg(
        long,
        requires = "conf",
        conflicts_with_all = ["conf_example", "rotate_wireguard_master_key"]
    )]
    rotate_wireguard_identity: bool,
    /// 由 Windows Service Control Manager 启动服务模式
    #[cfg(windows)]
    #[arg(long, hide = true)]
    pub service: bool,
    /// Windows 服务名；仅供服务安装和 SCM 启动使用
    #[cfg(windows)]
    #[arg(long, hide = true, value_name = "NAME", requires = "service")]
    service_name: Option<String>,
}

fn main() {
    let args = Args::parse();
    if args.conf_example {
        utils::config::print_example();
        return;
    }

    if let Err(err) = run(args) {
        eprintln!("{err:?}");
        std::process::exit(1);
    }
}

fn run(args: Args) -> anyhow::Result<()> {
    let rotate_wireguard_master_key = args.rotate_wireguard_master_key;
    let rotate_wireguard_identity = args.rotate_wireguard_identity;
    let conf_path = normalize_conf_path(args.conf)?;
    prepare_process_working_directory(conf_path.as_deref())?;

    utils::log::log_init("vnts2");
    log::info!("version: {:?}", env!("CARGO_PKG_VERSION"));

    #[cfg(windows)]
    if args.service {
        anyhow::ensure!(
            rotate_wireguard_master_key.is_none() && !rotate_wireguard_identity,
            "WireGuard rotation cannot run in Windows service mode"
        );
        let service_name = args.service_name.as_deref().unwrap_or("vnts2");
        return windows_service::run_service_mode(service_name, conf_path);
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("创建 Tokio 运行时失败")?;
    match (rotate_wireguard_master_key, rotate_wireguard_identity) {
        (Some(new_master_key_file), false) => runtime.block_on(run_master_key_rotation(
            conf_path.context("WireGuard master key rotation requires --conf")?,
            new_master_key_file,
        )),
        (None, true) => runtime.block_on(run_identity_rotation(
            conf_path.context("WireGuard identity rotation requires --conf")?,
        )),
        (None, false) => runtime.block_on(run_app(conf_path, None, None)),
        (Some(_), true) => anyhow::bail!(
            "WireGuard master key rotation and identity rotation are mutually exclusive"
        ),
    }
}

async fn run_master_key_rotation(
    conf_path: PathBuf,
    new_master_key_file: PathBuf,
) -> anyhow::Result<()> {
    let conf = ConfigFile::load_from(Some(conf_path)).context("Failed to load rotation config")?;
    anyhow::ensure!(
        conf.persistence,
        "WireGuard master key rotation requires persistence = true"
    );
    let current_master_key_file = conf
        .wireguard_master_key_file
        .context("WireGuard master key rotation requires wireguard_master_key_file in config")?;
    anyhow::ensure!(
        server::control_server::db::database_exists(),
        "WireGuard master key rotation requires an existing network_control.db"
    );
    server::control_server::db::init_db_pool()
        .await
        .context("Failed to exclusively open the database for WireGuard master key rotation")?;
    let rotation = server::control_server::wireguard_identity::rotate_master_key(
        &current_master_key_file,
        &new_master_key_file,
    )
    .await?;
    println!(
        "WireGuard master key rotated from version {} to {}; public key remains {}",
        rotation.previous_version,
        rotation.new_version,
        hex::encode(rotation.public_key)
    );
    println!(
        "Update wireguard_master_key_file to '{}' before restarting VNTS",
        new_master_key_file.display()
    );
    Ok(())
}

async fn run_identity_rotation(conf_path: PathBuf) -> anyhow::Result<()> {
    let conf = ConfigFile::load_from(Some(conf_path)).context("Failed to load rotation config")?;
    anyhow::ensure!(
        conf.persistence,
        "WireGuard identity rotation requires persistence = true"
    );
    let master_key_file = conf
        .wireguard_master_key_file
        .context("WireGuard identity rotation requires wireguard_master_key_file in config")?;
    anyhow::ensure!(
        server::control_server::db::database_exists(),
        "WireGuard identity rotation requires an existing network_control.db"
    );
    server::control_server::db::init_db_pool()
        .await
        .context("Failed to exclusively open the database for WireGuard identity rotation")?;
    let rotation =
        server::control_server::wireguard_identity::rotate_identity(&master_key_file).await?;
    println!(
        "WireGuard server identity rotated; old public key {}; new public key {}",
        hex::encode(rotation.previous_public_key),
        hex::encode(rotation.new_public_key)
    );
    println!(
        "New WireGuard client public key (Base64): {}",
        BASE64_STANDARD.encode(rotation.new_public_key)
    );
    println!("Update every WireGuard client with the new server public key before restarting VNTS");
    Ok(())
}

pub(crate) async fn run_app(
    conf_path: Option<PathBuf>,
    shutdown_rx: Option<oneshot::Receiver<()>>,
    startup_tx: Option<oneshot::Sender<()>>,
) -> anyhow::Result<()> {
    let runtime_config_path = conf_path
        .clone()
        .unwrap_or_else(|| PathBuf::from("config.toml"));
    let conf = ConfigFile::load_from(conf_path).context("加载配置文件失败")?;
    let web_management = conf.web_management_config()?;
    let wireguard_public_endpoint = conf.effective_wireguard_public_endpoint()?;
    let database_ready = if conf.persistence {
        match server::control_server::db::init_db_pool().await {
            Ok(()) => true,
            Err(e) => {
                log::error!("{:?}", e);
                false
            }
        }
    } else {
        false
    };
    let web_status_config =
        web_management
            .as_ref()
            .map(|(web_bind, _, _)| http::web_server::ServerStatusConfig {
                persistence_enabled: conf.persistence,
                database_ready,
                web_bind: *web_bind,
                tcp_bind: conf.tcp_bind,
                quic_bind: conf.quic_bind,
                websocket_bind: conf.ws_bind,
                peer_server_bind: conf.server_quic_bind,
                wireguard_configured: conf.wireguard_bind.is_some(),
                wireguard_public_endpoint: wireguard_public_endpoint.clone(),
                wireguard_max_active_peers: conf.wireguard_max_active_peers,
            });

    if conf.wireguard_bind.is_some() {
        anyhow::ensure!(
            conf.persistence,
            "WireGuard UDP listener requires persistence = true"
        );
        anyhow::ensure!(
            database_ready,
            "WireGuard UDP listener requires an initialized database"
        );
        anyhow::ensure!(
            conf.wireguard_master_key_file.is_some(),
            "WireGuard UDP listener requires wireguard_master_key_file in config"
        );
    }

    let wireguard_identity = match conf.wireguard_master_key_file.as_deref() {
        None => None,
        Some(_) if !conf.persistence => {
            anyhow::bail!("WireGuard server identity requires persistence = true")
        }
        Some(_) if !database_ready => {
            anyhow::bail!("WireGuard server identity requires an initialized database")
        }
        Some(master_key_file) => {
            let identity =
                server::control_server::wireguard_identity::load_or_create(master_key_file)
                    .await
                    .context("Failed to initialize WireGuard server identity")?;
            log::info!(
                "WireGuard server identity initialized, public key: {}",
                hex::encode(identity.public_key())
            );
            Some(identity)
        }
    };

    // 提前提取需要在 move 之后使用的字段
    let need_peer_manager = !conf.peer_servers.is_empty() || web_management.is_some();
    let peer_conf = PeerConf {
        persistence: conf.persistence,
        server_quic_bind: conf.server_quic_bind,
        peer_servers: conf.peer_servers.clone(),
        server_token: conf.server_token.clone(),
        cert: conf.cert.clone(),
        key: conf.key.clone(),
    };

    let turn_config = TurnConfig {
        tcp_bind: conf.tcp_bind,
        quic_bind: conf.quic_bind,
        ws_bind: conf.ws_bind,
        cert: conf.cert.clone(),
        key: conf.key.clone(),
    };

    let wireguard_bind = conf.wireguard_bind;
    let wireguard_max_active_peers = conf.wireguard_max_active_peers;

    let control_service = ControlService::new(
        conf.network,
        conf.custom_nets,
        Duration::from_secs(conf.lease_duration),
    )
    .await;

    server::turn_server_start(turn_config, control_service.clone())
        .await
        .context("启动 VNT 监听失败")?;

    if need_peer_manager {
        init_peer_manager(&peer_conf, &control_service).await?;
    }

    let shutdown_token = CancellationToken::new();
    let wireguard_autostart =
        http::web_server::WireGuardAutostart::new(runtime_config_path, shutdown_token.clone());
    let wireguard_task = if let Some(bind_addr) = wireguard_bind {
        let identity = wireguard_identity
            .as_ref()
            .context("WireGuard UDP listener requires an initialized server identity")?;
        let (handle, task) = server::wireguard_runtime::start(
            bind_addr,
            identity,
            wireguard_max_active_peers,
            control_service.clone(),
            shutdown_token.clone(),
        )
        .await?;
        let listen_addr = handle.local_addr();
        let public_key = handle.public_key();
        log::info!("WireGuard UDP listener started on {listen_addr}");
        control_service.set_wireguard_runtime(handle);
        let monitored_service = control_service.clone();
        Some(tokio::spawn(async move {
            let result = task.await;
            monitored_service.clear_wireguard_runtime_if(listen_addr, public_key);
            result.context("等待 WireGuard UDP 运行时任务失败")?
        }))
    } else {
        None
    };
    let (http_task, http_startup_rx) = web_management.zip(web_status_config).map_or(
        (None, None),
        |((bind_addr, username, password), status_config)| {
            let control_service = control_service.clone();
            let shutdown = shutdown_token.clone();
            let wireguard_autostart = wireguard_autostart.clone();
            let (http_startup_tx, http_startup_rx) = oneshot::channel();
            let task = tokio::spawn(async move {
                http::web_server::start_http_server(
                    control_service,
                    username,
                    password,
                    bind_addr,
                    status_config,
                    wireguard_autostart,
                    shutdown,
                    Some(http_startup_tx),
                )
                .await
            });
            (Some(task), Some(http_startup_rx))
        },
    );

    if let Some(http_startup_rx) = http_startup_rx {
        http_startup_rx
            .await
            .context("HTTP 服务在报告启动结果前退出")?
            .map_err(anyhow::Error::msg)?;
    }
    if let Some(startup_tx) = startup_tx {
        startup_tx
            .send(())
            .map_err(|_| anyhow::anyhow!("Windows 服务启动就绪接收端已关闭"))?;
    }

    wait_for_shutdown(shutdown_rx).await?;
    shutdown_token.cancel();

    if let Some(task) = http_task {
        task.await
            .context("等待 HTTP 服务退出失败")?
            .context("HTTP 服务运行失败")?;
    }
    if let Some(task) = wireguard_task {
        task.await
            .context("等待 WireGuard UDP 运行时退出失败")?
            .context("WireGuard UDP 运行时失败")?;
    }

    Ok(())
}

struct PeerConf {
    persistence: bool,
    server_quic_bind: Option<std::net::SocketAddr>,
    peer_servers: Vec<String>,
    server_token: Option<String>,
    cert: Option<PathBuf>,
    key: Option<PathBuf>,
}

async fn init_peer_manager(
    conf: &PeerConf,
    control_service: &ControlService,
) -> anyhow::Result<()> {
    let server_token = conf
        .server_token
        .clone()
        .unwrap_or_else(|| "default_token".to_string());
    let network_state_provider = control_service.get_network_state_provider().clone();

    let peer_manager = Arc::new(PeerServerManager::new(server_token, network_state_provider));
    control_service.set_peer_manager(peer_manager.clone());

    if let Some(server_quic_bind) = conf.server_quic_bind {
        let (certs, key) =
            crate::utils::cert::get_cert_and_key(conf.cert.clone(), conf.key.clone())
                .context("加载 peer server 证书失败")?;
        peer_manager
            .clone()
            .start_server(server_quic_bind, certs, key)
            .await
            .with_context(|| format!("启动 peer server 失败: {server_quic_bind}"))?;
        log::info!("Peer server started on {}", server_quic_bind);
    }

    if conf.persistence {
        sync_peer_servers_to_db(&conf.peer_servers).await;
        if let Err(e) = peer_manager.clone().load_and_start_outbound_peers().await {
            log::error!("Failed to load and start outbound peers: {:?}", e);
        }
    } else {
        for peer_addr in conf.peer_servers.clone() {
            let manager = peer_manager.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(2)).await;
                manager.connect_to_peer(peer_addr);
            });
        }
    }
    Ok(())
}

/// 将配置文件中的 peer server 写入数据库（已存在的跳过）
async fn sync_peer_servers_to_db(peer_servers: &[String]) {
    use server::control_server::db::{PeerServerRecord, PeerServerSource};
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    for peer_addr in peer_servers {
        let record = PeerServerRecord {
            server_addr: peer_addr.clone(),
            source: PeerServerSource::Config,
            created_at: now,
        };
        match server::control_server::db::save_peer_server_if_not_exists(&record).await {
            Ok(true) => log::info!("Initialized peer server '{}' from config", peer_addr),
            Ok(false) => {}
            Err(e) => log::error!("Failed to save peer server {}: {}", peer_addr, e),
        }
    }
}

async fn wait_for_shutdown(shutdown_rx: Option<oneshot::Receiver<()>>) -> anyhow::Result<()> {
    match shutdown_rx {
        Some(receiver) => {
            let _ = receiver.await;
            Ok(())
        }
        None => tokio::signal::ctrl_c().await.context("监听 Ctrl+C 失败"),
    }
}

fn normalize_conf_path(conf_path: Option<PathBuf>) -> anyhow::Result<Option<PathBuf>> {
    conf_path
        .map(|path| {
            if path.is_absolute() {
                Ok(path)
            } else {
                Ok(std::env::current_dir()
                    .context("读取当前工作目录失败")?
                    .join(path))
            }
        })
        .transpose()
}

fn prepare_process_working_directory(conf_path: Option<&Path>) -> anyhow::Result<()> {
    let target_dir = conf_path
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|path| path.parent().map(Path::to_path_buf))
        })
        .unwrap_or(std::env::current_dir().context("读取当前目录失败")?);

    if !target_dir.exists() {
        std::fs::create_dir_all(&target_dir)
            .with_context(|| format!("创建工作目录失败: {}", target_dir.display()))?;
    }
    std::env::set_current_dir(&target_dir)
        .with_context(|| format!("切换工作目录失败: {}", target_dir.display()))?;
    Ok(())
}

#[cfg(test)]
mod cli_tests {
    use super::{Args, run_app};
    use clap::Parser;
    use std::path::PathBuf;

    #[test]
    fn wireguard_master_key_rotation_requires_explicit_config() {
        let error =
            Args::try_parse_from(["vnts2", "--rotate-wireguard-master-key", "new-master.key"])
                .unwrap_err();
        assert!(error.to_string().contains("--conf <CONF>"));
    }

    #[test]
    fn wireguard_master_key_rotation_cli_contract_parses() {
        let args = Args::try_parse_from([
            "vnts2",
            "--conf",
            "config.toml",
            "--rotate-wireguard-master-key",
            "new-master.key",
        ])
        .unwrap();
        assert_eq!(args.conf, Some(PathBuf::from("config.toml")));
        assert_eq!(
            args.rotate_wireguard_master_key,
            Some(PathBuf::from("new-master.key"))
        );
    }

    #[test]
    fn wireguard_identity_rotation_requires_explicit_config() {
        let error = Args::try_parse_from(["vnts2", "--rotate-wireguard-identity"]).unwrap_err();
        assert!(error.to_string().contains("--conf <CONF>"));
    }

    #[test]
    fn wireguard_identity_rotation_cli_contract_parses() {
        let args = Args::try_parse_from([
            "vnts2",
            "--conf",
            "config.toml",
            "--rotate-wireguard-identity",
        ])
        .unwrap();
        assert_eq!(args.conf, Some(PathBuf::from("config.toml")));
        assert!(args.rotate_wireguard_identity);
        assert!(args.rotate_wireguard_master_key.is_none());
    }

    #[test]
    fn wireguard_rotation_modes_are_mutually_exclusive() {
        assert!(
            Args::try_parse_from([
                "vnts2",
                "--conf",
                "config.toml",
                "--rotate-wireguard-master-key",
                "new-master.key",
                "--rotate-wireguard-identity",
            ])
            .is_err()
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_service_name_requires_service_mode() {
        assert!(Args::try_parse_from(["vnts2", "--service-name", "vnts2-test"]).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn windows_service_cli_accepts_an_isolated_service_name() {
        let args = Args::try_parse_from([
            "vnts2",
            "--service",
            "--service-name",
            "vnts2-contract-test",
            "--conf",
            "C:\\ProgramData\\VNTS2-Test\\config.toml",
        ])
        .unwrap();
        assert!(args.service);
        assert_eq!(args.service_name.as_deref(), Some("vnts2-contract-test"));
    }

    #[tokio::test]
    async fn missing_config_returns_an_error_instead_of_panicking() {
        let missing = std::env::temp_dir().join(format!(
            "vnts2-missing-config-{}-{}.toml",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let error = run_app(Some(missing), None, None).await.unwrap_err();
        assert!(error.to_string().contains("加载配置文件失败"));
    }
}

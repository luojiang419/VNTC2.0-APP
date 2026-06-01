use crate::server::TurnConfig;
use crate::server::control_server::service::ControlService;
use crate::server::peer_server::PeerServerManager;
use crate::utils::config::ConfigFile;
use anyhow::Context;
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
    /// 由 Windows Service Control Manager 启动服务模式
    #[cfg(windows)]
    #[arg(long, hide = true)]
    pub service: bool,
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
    let conf_path = normalize_conf_path(args.conf)?;
    prepare_process_working_directory(conf_path.as_deref())?;

    utils::log::log_init("vnts2");
    log::info!("version: {:?}", env!("CARGO_PKG_VERSION"));

    #[cfg(windows)]
    if args.service {
        return windows_service::run_service_mode(conf_path);
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("创建 Tokio 运行时失败")?;
    runtime.block_on(run_app(conf_path, None))
}

pub(crate) async fn run_app(
    conf_path: Option<PathBuf>,
    shutdown_rx: Option<oneshot::Receiver<()>>,
) -> anyhow::Result<()> {
    let conf = match ConfigFile::load_from(conf_path) {
        Ok(conf) => conf,
        Err(e) => {
            log::error!("{e:?}");
            panic!("{e:?}")
        }
    };
    if conf.persistence {
        if let Err(e) = server::control_server::db::init_db_pool().await {
            log::error!("{:?}", e);
        }
    }

    // 提前提取需要在 move 之后使用的字段
    let need_peer_manager = !conf.peer_servers.is_empty() || conf.web_bind.is_some();
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

    let web_bind = conf.web_bind;
    let username = conf.username.unwrap_or("admin".to_string());
    let password = conf.password.unwrap_or("admin".to_string());

    let control_service = ControlService::new(
        conf.network,
        conf.custom_nets,
        Duration::from_secs(conf.lease_duration),
    )
    .await;

    if let Err(e) = server::turn_server_start(turn_config, control_service.clone()).await {
        log::error!("{:?}", e);
        panic!("{:?}", e)
    }

    if need_peer_manager {
        init_peer_manager(&peer_conf, &control_service).await;
    }

    let shutdown_token = CancellationToken::new();
    let http_task = web_bind.map(|bind_addr| {
        let control_service = control_service.clone();
        let shutdown = shutdown_token.clone();
        tokio::spawn(async move {
            http::web_server::start_http_server(
                control_service,
                username,
                password,
                bind_addr,
                shutdown,
            )
            .await
        })
    });

    wait_for_shutdown(shutdown_rx).await?;
    shutdown_token.cancel();

    if let Some(task) = http_task {
        task.await
            .context("等待 HTTP 服务退出失败")?
            .context("HTTP 服务运行失败")?;
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

async fn init_peer_manager(conf: &PeerConf, control_service: &ControlService) {
    let server_token = conf
        .server_token
        .clone()
        .unwrap_or_else(|| "default_token".to_string());
    let network_state_provider = control_service.get_network_state_provider().clone();

    let peer_manager = Arc::new(PeerServerManager::new(server_token, network_state_provider));
    control_service.set_peer_manager(peer_manager.clone());

    if let Some(server_quic_bind) = conf.server_quic_bind {
        let (certs, key) =
            match crate::utils::cert::get_cert_and_key(conf.cert.clone(), conf.key.clone()) {
                Ok((certs, key)) => (certs, key),
                Err(e) => {
                    log::error!("Failed to load cert/key for peer server: {:?}", e);
                    panic!("{:?}", e)
                }
            };
        if let Err(e) = peer_manager
            .clone()
            .start_server(server_quic_bind, certs, key)
            .await
        {
            log::error!("Failed to start peer server: {:?}", e);
        } else {
            log::info!("Peer server started on {}", server_quic_bind);
        }
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

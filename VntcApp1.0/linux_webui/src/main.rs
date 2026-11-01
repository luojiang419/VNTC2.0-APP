use std::env;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use tokio::net::TcpListener;
use vntc_linux_webui::api::{ApiState, router};
use vntc_linux_webui::config::AppConfig;
use vntc_linux_webui::vnt_service::to_core_config;

fn main() -> Result<()> {
    let mut runtime = tokio::runtime::Builder::new_multi_thread();
    #[cfg(feature = "openwrt")]
    runtime
        .worker_threads(1)
        .max_blocking_threads(4)
        .thread_stack_size(512 * 1024);
    runtime.enable_all().build()?.block_on(async_main())
}

async fn async_main() -> Result<()> {
    env_logger::init();
    let command = Command::parse(env::args().skip(1))?;

    match command {
        Command::Help => {
            print_help();
            Ok(())
        }
        Command::CheckConfig(path) => {
            let config = AppConfig::load(&path)?;
            to_core_config(&config.vnt)?;
            println!(
                "配置有效：WebUI http://{}:{}，设备 {}",
                config.web.listen, config.web.port, config.vnt.device_name
            );
            Ok(())
        }
        Command::Run(path) => {
            let config = AppConfig::load(&path)?;
            run_server(config, path).await
        }
    }
}

async fn run_server(config: AppConfig, config_path: PathBuf) -> Result<()> {
    let listen_address = (config.web.listen, config.web.port);
    let auto_start = config.auto_start;
    let state = Arc::new(ApiState::new(config, config_path)?);
    state
        .logs
        .push("info", format!("{} 控制面已初始化", product_name()))
        .await;
    let listener = TcpListener::bind(listen_address)
        .await
        .with_context(|| format!("监听 {}:{} 失败", listen_address.0, listen_address.1))?;

    if auto_start {
        tokio::spawn(state.clone().connect_on_startup());
    }

    println!(
        "{} 已启动：http://{}:{}",
        product_name(),
        listen_address.0,
        listen_address.1
    );
    axum::serve(listener, router(state.clone()))
        .with_graceful_shutdown(shutdown_signal(state))
        .await
        .context("WebUI 服务异常退出")
}

async fn shutdown_signal(state: Arc<ApiState>) {
    #[cfg(unix)]
    {
        // procd 和 systemd 正常停止服务时发送 SIGTERM。
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("无法注册 SIGTERM 处理器");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
        }
    }
    #[cfg(not(unix))]
    let _ = tokio::signal::ctrl_c().await;

    state.controller.stop().await;
}

enum Command {
    Help,
    CheckConfig(PathBuf),
    Run(PathBuf),
}

impl Command {
    fn parse(mut args: impl Iterator<Item = String>) -> Result<Self> {
        let mut config_path = PathBuf::from("config.json");
        let mut check_config = false;

        while let Some(argument) = args.next() {
            match argument.as_str() {
                "-h" | "--help" => return Ok(Self::Help),
                "--check-config" => check_config = true,
                "-c" | "--config" => {
                    let value = args.next().context("--config 后必须提供文件路径")?;
                    config_path = PathBuf::from(value);
                }
                _ => bail!("未知参数：{argument}；使用 --help 查看帮助"),
            }
        }

        if check_config {
            Ok(Self::CheckConfig(config_path))
        } else {
            Ok(Self::Run(config_path))
        }
    }
}

fn print_help() {
    println!(
        "vntc-linux-webui {}\n\n用法：\n  vntc-linux-webui --config <路径>\n  vntc-linux-webui --config <路径> --check-config\n\n参数：\n  -c, --config <路径>  JSON 配置文件，默认 config.json\n      --check-config    校验配置后退出\n  -h, --help            显示帮助",
        app_version()
    );
}

fn product_name() -> &'static str {
    if cfg!(windows) {
        "VNTC Windows WebUI"
    } else {
        "VNTC Linux WebUI"
    }
}

fn app_version() -> &'static str {
    option_env!("VNTC_APP_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

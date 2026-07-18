use std::env;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use tokio::net::TcpListener;
use vntc_linux_webui::api::{ApiState, router};
use vntc_linux_webui::config::AppConfig;
use vntc_linux_webui::vnt_service::to_core_config;

#[tokio::main]
async fn main() -> Result<()> {
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
    state.logs.push("info", "Linux WebUI 控制面已初始化").await;
    let listener = TcpListener::bind(listen_address)
        .await
        .with_context(|| format!("监听 {}:{} 失败", listen_address.0, listen_address.1))?;

    if auto_start {
        let controller = state.controller.clone();
        let vnt_config = state.config.read().await.vnt.clone();
        let state_for_profile = state.clone();
        tokio::spawn(async move {
            if let Err(error) = controller.start(vnt_config).await {
                log::error!("自动启动 VNT 失败：{error:#}");
                state_for_profile
                    .logs
                    .push("error", format!("自动连接失败：{error:#}"))
                    .await;
            } else {
                let default_id = state_for_profile
                    .profiles
                    .read()
                    .await
                    .default_profile_id
                    .clone();
                *state_for_profile.active_profile_id.write().await = Some(default_id);
                state_for_profile
                    .logs
                    .push("info", "已自动连接默认配置")
                    .await;
            }
        });
    }

    println!(
        "VNTC Linux WebUI 已启动：http://{}:{}",
        listen_address.0, listen_address.1
    );
    axum::serve(listener, router(state.clone()))
        .with_graceful_shutdown(shutdown_signal(state))
        .await
        .context("WebUI 服务异常退出")
}

async fn shutdown_signal(state: Arc<ApiState>) {
    if tokio::signal::ctrl_c().await.is_ok() {
        state.controller.stop().await;
    }
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

fn app_version() -> &'static str {
    option_env!("VNTC_APP_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

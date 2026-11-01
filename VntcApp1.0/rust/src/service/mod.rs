mod config;
mod runtime;
mod windows;

use std::env;

use anyhow::Context;

pub const SERVICE_NAME: &str = "VntCoreService";

pub fn run() -> anyhow::Result<()> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    if arguments
        .iter()
        .any(|argument| argument == "--validate-config")
    {
        let root = config::machine_root_from_environment();
        let snapshot = config::load_snapshot(&root)?
            .context("未找到 VNT 系统服务配置，请先从客户端启用系统服务")?;
        let selected = snapshot.selected_config()?;
        let _ = selected.to_vnt_config()?;
        println!(
            "配置有效: defaultConfigKey={} autoConnect={} revision={}",
            snapshot.settings.default_config_key,
            snapshot.settings.auto_connect,
            snapshot.revision()
        );
        return Ok(());
    }
    windows::run_dispatcher().map_err(anyhow::Error::from)
}

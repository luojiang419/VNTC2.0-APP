use anyhow::Context;
use std::ffi::OsString;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::oneshot;
use windows_service::define_windows_service;
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;

const SERVICE_NAME: &str = "vnts2";
static SERVICE_CONF_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();

define_windows_service!(ffi_service_main, service_main);

pub fn run_service_mode(conf_path: Option<PathBuf>) -> anyhow::Result<()> {
    SERVICE_CONF_PATH
        .set(conf_path)
        .map_err(|_| anyhow::anyhow!("Windows 服务启动参数重复初始化"))?;
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
        .context("连接 Windows Service Control Manager 失败")?;
    Ok(())
}

fn service_main(_arguments: Vec<OsString>) {
    if let Err(err) = service_main_impl() {
        log::error!("Windows 服务启动失败: {:?}", err);
    }
}

fn service_main_impl() -> anyhow::Result<()> {
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let shutdown_tx = Arc::new(Mutex::new(Some(shutdown_tx)));
    let event_handler = {
        let shutdown_tx = Arc::clone(&shutdown_tx);
        move |control_event| -> ServiceControlHandlerResult {
            match control_event {
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    if let Ok(mut sender) = shutdown_tx.lock() {
                        if let Some(tx) = sender.take() {
                            let _ = tx.send(());
                        }
                    }
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        }
    };

    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)
        .context("注册 Windows 服务控制回调失败")?;
    status_handle
        .set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::StartPending,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 1,
            wait_hint: Duration::from_secs(10),
            process_id: None,
        })
        .context("更新 Windows 服务启动状态失败")?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("创建 Windows 服务 Tokio 运行时失败")?;

    status_handle
        .set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })
        .context("更新 Windows 服务运行状态失败")?;

    let conf_path = SERVICE_CONF_PATH.get().cloned().unwrap_or(None);
    let result = runtime.block_on(crate::run_app(conf_path, Some(shutdown_rx)));
    let exit_code = if result.is_ok() { 0 } else { 1 };

    status_handle
        .set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(exit_code),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })
        .context("更新 Windows 服务停止状态失败")?;

    result
}

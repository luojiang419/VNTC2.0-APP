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
use windows_service::service_control_handler::{
    self, ServiceControlHandlerResult, ServiceStatusHandle,
};
use windows_service::service_dispatcher;

struct ServiceContext {
    name: String,
    conf_path: Option<PathBuf>,
}

static SERVICE_CONTEXT: OnceLock<ServiceContext> = OnceLock::new();

define_windows_service!(ffi_service_main, service_main);

pub fn run_service_mode(service_name: &str, conf_path: Option<PathBuf>) -> anyhow::Result<()> {
    anyhow::ensure!(
        is_valid_service_name(service_name),
        "Windows 服务名只能包含字母、数字、点、下划线和连字符，且长度为 1–80"
    );
    SERVICE_CONTEXT
        .set(ServiceContext {
            name: service_name.to_string(),
            conf_path,
        })
        .map_err(|_| anyhow::anyhow!("Windows 服务启动参数重复初始化"))?;
    service_dispatcher::start(service_name, ffi_service_main)
        .context("连接 Windows Service Control Manager 失败")?;
    Ok(())
}

fn is_valid_service_name(service_name: &str) -> bool {
    !service_name.is_empty()
        && service_name.len() <= 80
        && service_name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn service_status(
    current_state: ServiceState,
    controls_accepted: ServiceControlAccept,
    exit_code: ServiceExitCode,
    checkpoint: u32,
    wait_hint: Duration,
) -> ServiceStatus {
    ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state,
        controls_accepted,
        exit_code,
        checkpoint,
        wait_hint,
        process_id: None,
    }
}

fn service_main(_arguments: Vec<OsString>) {
    if let Err(error) = service_main_impl() {
        log::error!("Windows 服务退出失败: {error:#}");
    }
}

fn service_main_impl() -> anyhow::Result<()> {
    let context = SERVICE_CONTEXT
        .get()
        .context("Windows 服务上下文尚未初始化")?;
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let shutdown_tx = Arc::new(Mutex::new(Some(shutdown_tx)));
    let status_slot = Arc::new(Mutex::new(None::<ServiceStatusHandle>));
    let event_handler = {
        let shutdown_tx = Arc::clone(&shutdown_tx);
        let status_slot = Arc::clone(&status_slot);
        move |control_event| -> ServiceControlHandlerResult {
            match control_event {
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    if let Ok(slot) = status_slot.lock()
                        && let Some(status_handle) = *slot
                        && let Err(error) = status_handle.set_service_status(service_status(
                            ServiceState::StopPending,
                            ServiceControlAccept::empty(),
                            ServiceExitCode::NO_ERROR,
                            1,
                            Duration::from_secs(30),
                        ))
                    {
                        log::error!("更新 Windows 服务停止中状态失败: {error}");
                    }
                    if let Ok(mut sender) = shutdown_tx.lock()
                        && let Some(tx) = sender.take()
                    {
                        let _ = tx.send(());
                    }
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        }
    };

    let status_handle = service_control_handler::register(&context.name, event_handler)
        .context("注册 Windows 服务控制回调失败")?;
    if let Ok(mut slot) = status_slot.lock() {
        *slot = Some(status_handle);
    }
    status_handle
        .set_service_status(service_status(
            ServiceState::StartPending,
            ServiceControlAccept::empty(),
            ServiceExitCode::NO_ERROR,
            1,
            Duration::from_secs(30),
        ))
        .context("更新 Windows 服务启动状态失败")?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("创建 Windows 服务 Tokio 运行时失败")?;
    let (startup_tx, startup_rx) = oneshot::channel();
    let app = crate::run_app(
        context.conf_path.clone(),
        Some(shutdown_rx),
        Some(startup_tx),
    );
    let result = runtime.block_on(async {
        tokio::pin!(app);
        tokio::select! {
            biased;
            result = &mut app => result,
            startup = startup_rx => {
                startup.context("应用在报告启动就绪前退出")?;
                status_handle
                    .set_service_status(service_status(
                        ServiceState::Running,
                        ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
                        ServiceExitCode::NO_ERROR,
                        0,
                        Duration::default(),
                    ))
                    .context("更新 Windows 服务运行状态失败")?;
                app.await
            }
        }
    });

    if let Err(error) = &result {
        log::error!("Windows 服务运行失败: {error:#}");
    }
    let exit_code = if result.is_ok() {
        ServiceExitCode::NO_ERROR
    } else {
        ServiceExitCode::ServiceSpecific(1)
    };
    status_handle
        .set_service_status(service_status(
            ServiceState::Stopped,
            ServiceControlAccept::empty(),
            exit_code,
            0,
            Duration::default(),
        ))
        .context("更新 Windows 服务停止状态失败")?;

    result
}

#[cfg(test)]
mod tests {
    use super::is_valid_service_name;

    #[test]
    fn service_name_contract_matches_windows_scripts() {
        assert!(is_valid_service_name("vnts2"));
        assert!(is_valid_service_name("vnts2.contract-test_1"));
        assert!(!is_valid_service_name(""));
        assert!(!is_valid_service_name("vnts2 test"));
        assert!(!is_valid_service_name("vnts2';delete"));
        assert!(!is_valid_service_name(&"a".repeat(81)));
    }
}

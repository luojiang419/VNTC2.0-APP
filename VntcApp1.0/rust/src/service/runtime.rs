use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use serde::Serialize;

use crate::api::vnt_api::{
    init_log_with_path, RustConnectInfo, RustDeviceConfig, RustErrorInfo, RustHandshakeInfo,
    RustRegisterInfo, VntApi, VntEventSink,
};

use super::config::{load_snapshot, ServiceConfigurationSnapshot};

const CONFIG_POLL_INTERVAL: Duration = Duration::from_secs(2);
const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(5);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub(crate) struct ServiceStatusStore {
    state: Arc<Mutex<ServiceRuntimeState>>,
    state_path: PathBuf,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ServiceRuntimeState {
    schema_version: u32,
    service_state: String,
    connection_state: String,
    config_key: String,
    revision: String,
    virtual_ip: String,
    connect_target: String,
    last_error: String,
    updated_at_unix_ms: u128,
}

impl ServiceRuntimeState {
    fn initial() -> Self {
        Self {
            schema_version: 1,
            service_state: "running".to_string(),
            connection_state: "idle".to_string(),
            config_key: String::new(),
            revision: String::new(),
            virtual_ip: String::new(),
            connect_target: String::new(),
            last_error: String::new(),
            updated_at_unix_ms: now_unix_ms(),
        }
    }
}

impl ServiceStatusStore {
    pub(crate) fn new(state_path: PathBuf) -> Self {
        Self {
            state: Arc::new(Mutex::new(ServiceRuntimeState::initial())),
            state_path,
        }
    }

    fn update(&self, mutate: impl FnOnce(&mut ServiceRuntimeState)) {
        if let Ok(mut state) = self.state.lock() {
            mutate(&mut state);
            state.updated_at_unix_ms = now_unix_ms();
            let _ = write_json_atomically(&self.state_path, &*state);
        }
    }

    pub(crate) fn snapshot_json(&self) -> serde_json::Value {
        self.state
            .lock()
            .ok()
            .and_then(|state| serde_json::to_value(&*state).ok())
            .unwrap_or_else(|| serde_json::json!({"serviceState": "unavailable"}))
    }
}

#[derive(Clone)]
struct ServiceEventSink {
    status: ServiceStatusStore,
}

impl ServiceEventSink {
    fn new(status: ServiceStatusStore) -> Self {
        Self { status }
    }

    fn update(&self, mutate: impl FnOnce(&mut ServiceRuntimeState)) {
        self.status.update(mutate);
    }
}

#[derive(Clone, Default)]
pub(crate) struct ServiceSignals {
    pub(crate) stopping: Arc<AtomicBool>,
    pub(crate) reload_requested: Arc<AtomicBool>,
}

impl VntEventSink for ServiceEventSink {
    fn emit_success(&self) {
        self.update(|state| {
            state.connection_state = "connected".to_string();
            state.last_error.clear();
        });
    }

    fn emit_connect(&self, info: RustConnectInfo) {
        self.update(|state| {
            state.connection_state = "connecting".to_string();
            state.connect_target = info.address;
        });
    }

    fn emit_handshake(&self, _info: RustHandshakeInfo) {}

    fn emit_register(&self, info: RustRegisterInfo) {
        self.update(|state| state.virtual_ip = info.virtual_ip);
    }

    fn emit_error(&self, info: RustErrorInfo) {
        self.update(|state| {
            state.connection_state = "error".to_string();
            state.last_error = info.msg.unwrap_or_else(|| format!("{:?}", info.code));
        });
    }

    fn request_android_vpn_fd(
        &self,
        _info: RustDeviceConfig,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<u32>> + Send + '_>> {
        Box::pin(async { anyhow::bail!("Windows 服务不支持 Android VPN fd") })
    }
}

pub fn run_worker(
    root: &Path,
    signals: ServiceSignals,
    status: ServiceStatusStore,
) -> anyhow::Result<()> {
    let config_dir = root.join("config");
    let data_dir = root.join("data");
    let logs_dir = root.join("logs");
    fs::create_dir_all(&config_dir).context("创建系统服务配置目录失败")?;
    fs::create_dir_all(&data_dir).context("创建系统服务数据目录失败")?;
    fs::create_dir_all(&logs_dir).context("创建系统服务日志目录失败")?;
    init_log_with_path(
        logs_dir.to_string_lossy().to_string(),
        config_dir
            .join("service.json")
            .to_string_lossy()
            .to_string(),
    )?;

    let sink = ServiceEventSink::new(status);
    sink.update(|state| state.service_state = "running".to_string());
    let mut retry_delay = Duration::from_secs(2);

    while !signals.stopping.load(Ordering::SeqCst) {
        signals.reload_requested.store(false, Ordering::SeqCst);
        let snapshot = match load_snapshot(root) {
            Ok(Some(snapshot)) => snapshot,
            Ok(None) => {
                sink.update(|state| {
                    state.connection_state = "unconfigured".to_string();
                    state.last_error.clear();
                });
                wait_or_signal(&signals, IDLE_POLL_INTERVAL);
                continue;
            }
            Err(error) => {
                sink.update(|state| {
                    state.connection_state = "configurationError".to_string();
                    state.last_error = format!("{error:#}");
                });
                wait_or_signal(&signals, IDLE_POLL_INTERVAL);
                continue;
            }
        };

        if !snapshot.settings.auto_connect {
            sink.update(|state| {
                state.connection_state = "idle".to_string();
                state.config_key.clear();
                state.revision = snapshot.revision();
                state.last_error.clear();
            });
            wait_or_signal(&signals, IDLE_POLL_INTERVAL);
            continue;
        }

        let revision = snapshot.revision();
        let selected = match snapshot.selected_config() {
            Ok(config) => config,
            Err(error) => {
                sink.update(|state| {
                    state.connection_state = "configurationError".to_string();
                    state.last_error = format!("{error:#}");
                });
                wait_or_signal(&signals, IDLE_POLL_INTERVAL);
                continue;
            }
        };
        let config_key = selected.item_key.clone();
        let vnt_config = match selected.to_vnt_config() {
            Ok(config) => config,
            Err(error) => {
                sink.update(|state| {
                    state.connection_state = "configurationError".to_string();
                    state.last_error = format!("{error:#}");
                });
                wait_or_signal(&signals, IDLE_POLL_INTERVAL);
                continue;
            }
        };
        sink.update(|state| {
            state.connection_state = "connecting".to_string();
            state.config_key = config_key;
            state.revision = revision.clone();
            state.virtual_ip.clear();
            state.last_error.clear();
        });

        match VntApi::new_with_sink(vnt_config, sink.clone()) {
            Ok(api) => {
                retry_delay = Duration::from_secs(2);
                while !signals.stopping.load(Ordering::SeqCst) {
                    thread::sleep(CONFIG_POLL_INTERVAL);
                    if signals.reload_requested.swap(false, Ordering::SeqCst) {
                        break;
                    }
                    if configuration_revision(root).as_deref() != Some(revision.as_str()) {
                        break;
                    }
                }
                api.stop();
                sink.update(|state| {
                    state.connection_state = if signals.stopping.load(Ordering::SeqCst) {
                        "stopping"
                    } else {
                        "reloading"
                    }
                    .to_string();
                });
            }
            Err(error) => {
                sink.update(|state| {
                    state.connection_state = "retrying".to_string();
                    state.last_error = format!("{error:#}");
                });
                wait_or_signal(&signals, retry_delay);
                retry_delay = (retry_delay * 2).min(MAX_RETRY_DELAY);
            }
        }
    }

    sink.update(|state| {
        state.service_state = "stopped".to_string();
        state.connection_state = "stopped".to_string();
    });
    Ok(())
}

fn configuration_revision(root: &Path) -> Option<String> {
    load_snapshot(root)
        .ok()
        .flatten()
        .map(|snapshot: ServiceConfigurationSnapshot| snapshot.revision())
}

fn wait_or_signal(signals: &ServiceSignals, duration: Duration) {
    let deadline = SystemTime::now() + duration;
    while !signals.stopping.load(Ordering::SeqCst)
        && !signals.reload_requested.load(Ordering::SeqCst)
        && SystemTime::now() < deadline
    {
        thread::sleep(Duration::from_millis(200));
    }
}

fn write_json_atomically(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_vec_pretty(value)?)?;
    if let Err(rename_error) = fs::rename(&temporary, path) {
        fs::copy(&temporary, path).with_context(|| {
            format!(
                "写入服务状态失败，rename={rename_error}, path={}",
                path.display()
            )
        })?;
        let _ = fs::remove_file(temporary);
    }
    Ok(())
}

fn now_unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

use std::ffi::c_void;
use std::fs;
use std::path::Path;
use std::ptr::null_mut;
use std::sync::atomic::Ordering;

use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    FlushFileBuffers, ReadFile, WriteFile, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_MESSAGE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_WAIT,
};

use super::runtime::{ServiceSignals, ServiceStatusStore};

pub const PIPE_NAME: &str = r"\\.\pipe\VntCoreService.v1";
const PROTOCOL_VERSION: u32 = 1;
const MAX_FRAME_SIZE: usize = 64 * 1024;
const PIPE_BUFFER_SIZE: u32 = MAX_FRAME_SIZE as u32;
const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IpcRequest {
    version: u32,
    id: String,
    command: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct IpcResponse {
    version: u32,
    id: String,
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
}

pub(crate) fn run_server(
    root: &Path,
    signals: ServiceSignals,
    status: ServiceStatusStore,
) -> anyhow::Result<()> {
    run_server_with_limit(root, signals, status, None)
}

pub(crate) fn run_test_server(
    root: &Path,
    signals: ServiceSignals,
    status: ServiceStatusStore,
) -> anyhow::Result<()> {
    run_server_with_limit(root, signals, status, Some(3))
}

fn run_server_with_limit(
    root: &Path,
    signals: ServiceSignals,
    status: ServiceStatusStore,
    request_limit: Option<usize>,
) -> anyhow::Result<()> {
    fs::create_dir_all(root.join("data")).context("创建 IPC 数据目录失败")?;
    let mut request_count = 0_usize;
    while !signals.stopping.load(Ordering::SeqCst) {
        let pipe = create_pipe()?;
        let connected = unsafe {
            ConnectNamedPipe(pipe, null_mut()) != 0 || GetLastError() == ERROR_PIPE_CONNECTED
        };
        if connected {
            handle_client(pipe, &signals, &status);
            request_count += 1;
            unsafe {
                FlushFileBuffers(pipe);
                DisconnectNamedPipe(pipe);
            }
        }
        unsafe {
            CloseHandle(pipe);
        }
        if request_limit.is_some_and(|limit| request_count >= limit) {
            break;
        }
    }
    Ok(())
}

fn create_pipe() -> anyhow::Result<HANDLE> {
    let pipe_name = wide(PIPE_NAME);
    let sddl = wide(PIPE_SDDL);
    let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
    let converted = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            null_mut(),
        )
    };
    if converted == 0 {
        bail!("创建命名管道安全描述符失败: {}", unsafe {
            GetLastError()
        });
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let pipe = unsafe {
        CreateNamedPipeW(
            pipe_name.as_ptr(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            4,
            PIPE_BUFFER_SIZE,
            PIPE_BUFFER_SIZE,
            5000,
            &attributes,
        )
    };
    unsafe {
        LocalFree(descriptor as *mut c_void);
    }
    if pipe == INVALID_HANDLE_VALUE {
        bail!("创建命名管道失败: {}", unsafe { GetLastError() });
    }
    Ok(pipe)
}

fn handle_client(pipe: HANDLE, signals: &ServiceSignals, status: &ServiceStatusStore) {
    let mut buffer = vec![0_u8; MAX_FRAME_SIZE];
    let mut bytes_read = 0_u32;
    let read_ok = unsafe {
        ReadFile(
            pipe,
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut bytes_read,
            null_mut(),
        )
    };
    if read_ok == 0 || bytes_read == 0 {
        return;
    }
    buffer.truncate(bytes_read as usize);
    let response = process_request(&buffer, signals, status);
    let encoded = serde_json::to_vec(&response).unwrap_or_else(|_| {
        r#"{"version":1,"id":"","ok":false,"error":"响应序列化失败"}"#
            .as_bytes()
            .to_vec()
    });
    if encoded.len() > MAX_FRAME_SIZE {
        return;
    }
    let mut bytes_written = 0_u32;
    unsafe {
        WriteFile(
            pipe,
            encoded.as_ptr(),
            encoded.len() as u32,
            &mut bytes_written,
            null_mut(),
        );
    }
}

fn process_request(
    payload: &[u8],
    signals: &ServiceSignals,
    status: &ServiceStatusStore,
) -> IpcResponse {
    let request: IpcRequest = match serde_json::from_slice(payload) {
        Ok(request) => request,
        Err(error) => return failure("", format!("无效 IPC 请求: {error}")),
    };
    if request.version != PROTOCOL_VERSION {
        return failure(
            &request.id,
            format!("不支持的 IPC 协议版本: {}", request.version),
        );
    }
    if request.id.trim().is_empty() || request.id.len() > 128 {
        return failure("", "IPC 请求 ID 无效".to_string());
    }
    match request.command.as_str() {
        "ping" => success(
            &request.id,
            json!({"service": super::SERVICE_NAME, "protocolVersion": PROTOCOL_VERSION}),
        ),
        "getStatus" => success(&request.id, status.snapshot_json()),
        "reload" => {
            signals.reload_requested.store(true, Ordering::SeqCst);
            success(&request.id, json!({"accepted": true}))
        }
        _ => failure(&request.id, "不支持的 IPC 命令".to_string()),
    }
}

fn success(id: &str, result: Value) -> IpcResponse {
    IpcResponse {
        version: PROTOCOL_VERSION,
        id: id.to_string(),
        ok: true,
        result: Some(result),
        error: None,
    }
}

fn failure(id: &str, error: String) -> IpcResponse {
    IpcResponse {
        version: PROTOCOL_VERSION,
        id: id.to_string(),
        ok: false,
        result: None,
        error: Some(error),
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;

    use super::process_request;
    use crate::service::runtime::{ServiceSignals, ServiceStatusStore};

    #[test]
    fn protocol_rejects_unknown_versions_and_commands() {
        let status = ServiceStatusStore::new(std::env::temp_dir().join("unused-state.json"));
        let signals = ServiceSignals::default();
        let version = process_request(
            br#"{"version":2,"id":"a","command":"ping"}"#,
            &signals,
            &status,
        );
        assert!(!version.ok);
        let command = process_request(
            br#"{"version":1,"id":"a","command":"execute"}"#,
            &signals,
            &status,
        );
        assert!(!command.ok);
    }

    #[test]
    fn reload_only_sets_the_bounded_service_signal() {
        let status = ServiceStatusStore::new(std::env::temp_dir().join("unused-state.json"));
        let signals = ServiceSignals::default();
        let response = process_request(
            br#"{"version":1,"id":"reload-1","command":"reload"}"#,
            &signals,
            &status,
        );
        assert!(response.ok);
        assert!(signals.reload_requested.load(Ordering::SeqCst));
        assert!(!signals.stopping.load(Ordering::SeqCst));
    }
}

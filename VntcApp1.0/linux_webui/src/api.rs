use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::Json;
use axum::extract::{Path, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Router, body::Body};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock};

use crate::app_settings::AppSettings;
use crate::config::{AppConfig, VntConfig};
use crate::profile_store::{
    ImportProfiles, NetworkProfile, ProfileBackup, ProfileInput, ProfileStore,
};
use crate::runtime_log::{LogEntry, RuntimeLog};
use crate::vnt_service::{VntController, to_core_config};

pub struct ApiState {
    pub config: RwLock<AppConfig>,
    pub config_path: PathBuf,
    pub controller: Arc<VntController>,
    pub profiles: RwLock<ProfileStore>,
    pub profiles_path: PathBuf,
    pub active_profile_id: RwLock<Option<String>>,
    pub settings: RwLock<AppSettings>,
    pub settings_path: PathBuf,
    pub logs: RuntimeLog,
    mutation: Mutex<()>,
}

impl ApiState {
    pub fn new(mut config: AppConfig, config_path: PathBuf) -> anyhow::Result<Self> {
        let profiles = ProfileStore::load_or_migrate(&config_path, &config.vnt)?;
        let settings = AppSettings::load(&config_path)?;
        let settings_path = AppSettings::path_for(&config_path);
        config.vnt = profiles.default_profile().vnt.clone();
        Ok(Self {
            config: RwLock::new(config),
            profiles_path: ProfileStore::path_for(&config_path),
            config_path,
            controller: VntController::new(),
            profiles: RwLock::new(profiles),
            active_profile_id: RwLock::new(None),
            settings_path,
            settings: RwLock::new(settings),
            logs: RuntimeLog::default(),
            mutation: Mutex::new(()),
        })
    }
}

pub fn router(state: Arc<ApiState>) -> Router {
    let protected = Router::new()
        .route("/status", get(status))
        .route("/config", get(get_config).put(update_config))
        .route("/start", post(start))
        .route("/stop", post(stop))
        .route("/peers", get(peers))
        .route("/routes", get(routes))
        .route("/traffic", get(traffic))
        .route("/profiles", get(list_profiles).post(create_profile))
        .route("/profiles/export", get(export_profiles))
        .route("/profiles/import", post(import_profiles))
        .route(
            "/profiles/{id}",
            get(get_profile).put(update_profile).delete(delete_profile),
        )
        .route("/profiles/{id}/copy", post(copy_profile))
        .route("/profiles/{id}/default", post(set_default_profile))
        .route("/profiles/{id}/connect", post(connect_profile))
        .route("/settings", get(get_settings).put(update_settings))
        .route("/settings/access-token", put(update_access_token))
        .route("/backup", get(export_backup))
        .route("/backup/restore", post(restore_backup))
        .route("/data/clear", post(clear_data))
        .route("/logs", get(get_logs).delete(clear_logs))
        .route("/logs/download", get(download_logs))
        .route("/about", get(about))
        .route_layer(middleware::from_fn_with_state(state.clone(), authorize));

    Router::new()
        .route("/", get(index_page))
        .route("/assets/{*path}", get(web_asset))
        .route("/favicon.svg", get(favicon))
        .route("/api/health", get(health))
        .nest("/api", protected)
        .with_state(state)
}

async fn index_page() -> Response {
    static_asset(
        "text/html; charset=utf-8",
        include_str!("../web/index.html"),
    )
}

async fn web_asset(Path(path): Path<String>) -> Response {
    match crate::web_assets::get(&path) {
        Some((content_type, body)) => static_asset(content_type, body),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn favicon() -> Response {
    static_asset("image/svg+xml", include_str!("../web/favicon.svg"))
}

fn static_asset(content_type: &'static str, body: &'static str) -> Response {
    let mut response = Response::new(Body::from(body));
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response.headers_mut().insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        ),
    );
    response
}

async fn health() -> Json<ApiMessage> {
    Json(ApiMessage::new("ok"))
}

async fn status(State(state): State<Arc<ApiState>>) -> Json<impl Serialize> {
    Json(state.controller.status().await)
}

async fn peers(State(state): State<Arc<ApiState>>) -> Json<impl Serialize> {
    Json(state.controller.peers().await)
}

async fn routes(State(state): State<Arc<ApiState>>) -> Json<impl Serialize> {
    Json(state.controller.routes().await)
}

async fn traffic(State(state): State<Arc<ApiState>>) -> Json<impl Serialize> {
    Json(state.controller.traffic().await)
}

async fn get_config(State(state): State<Arc<ApiState>>) -> Json<VntConfig> {
    Json(state.config.read().await.vnt.clone())
}

async fn update_config(
    State(state): State<Arc<ApiState>>,
    Json(vnt): Json<VntConfig>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await {
        return Err(ApiError::conflict("请先停止 VNT，再修改配置"));
    }
    let mut candidate = state.config.read().await.clone();
    candidate.vnt = vnt;
    candidate.validate().map_err(ApiError::bad_request)?;
    to_core_config(&candidate.vnt).map_err(ApiError::bad_request)?;
    candidate
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    let active_id = state.active_profile_id.read().await.clone();
    let selected_id = match active_id {
        Some(id) => id,
        None => state.profiles.read().await.default_profile_id.clone(),
    };
    let mut profiles = state.profiles.read().await.clone();
    let selected = profiles
        .find(&selected_id)
        .cloned()
        .ok_or_else(|| ApiError::internal("当前配置档案不存在"))?;
    profiles
        .update(
            &selected_id,
            ProfileInput {
                name: selected.name,
                vnt: candidate.vnt.clone(),
            },
        )
        .map_err(ApiError::bad_request)?;
    profiles
        .save(&state.profiles_path)
        .await
        .map_err(ApiError::internal)?;
    *state.profiles.write().await = profiles;
    *state.config.write().await = candidate;
    Ok(Json(ApiMessage::new("配置已保存")))
}

async fn start(State(state): State<Arc<ApiState>>) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let profile = state.profiles.read().await.default_profile().clone();
    activate_profile_config(&state, &profile).await?;
    state
        .controller
        .start(profile.vnt)
        .await
        .map_err(ApiError::internal)?;
    *state.active_profile_id.write().await = Some(profile.id);
    state.logs.push("info", "VNT 网络已启动").await;
    Ok(Json(ApiMessage::new("VNT 已启动")))
}

#[derive(Serialize)]
struct ProfileListResponse {
    schema_version: u32,
    default_profile_id: String,
    active_profile_id: Option<String>,
    profiles: Vec<NetworkProfile>,
}

async fn list_profiles(State(state): State<Arc<ApiState>>) -> Json<ProfileListResponse> {
    let profiles = state.profiles.read().await;
    Json(ProfileListResponse {
        schema_version: profiles.schema_version,
        default_profile_id: profiles.default_profile_id.clone(),
        active_profile_id: state.active_profile_id.read().await.clone(),
        profiles: profiles.profiles.clone(),
    })
}

async fn get_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
) -> Result<Json<NetworkProfile>, ApiError> {
    state
        .profiles
        .read()
        .await
        .find(&id)
        .cloned()
        .map(Json)
        .ok_or_else(|| ApiError::not_found("配置不存在"))
}

async fn create_profile(
    State(state): State<Arc<ApiState>>,
    Json(input): Json<ProfileInput>,
) -> Result<Json<NetworkProfile>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let mut candidate = state.profiles.read().await.clone();
    let profile = candidate.create(input).map_err(ApiError::bad_request)?;
    save_profiles(&state, candidate).await?;
    state
        .logs
        .push("info", format!("已创建配置：{}", profile.name))
        .await;
    Ok(Json(profile))
}

async fn update_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
    Json(input): Json<ProfileInput>,
) -> Result<Json<NetworkProfile>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await
        && state.active_profile_id.read().await.as_deref() == Some(id.as_str())
    {
        return Err(ApiError::conflict("连接中的配置不能修改，请先断开"));
    }
    let mut candidate = state.profiles.read().await.clone();
    let profile = candidate
        .update(&id, input)
        .map_err(ApiError::bad_request)?;
    save_profiles(&state, candidate).await?;
    if state.active_profile_id.read().await.as_deref() == Some(id.as_str()) {
        activate_profile_config(&state, &profile).await?;
    }
    state
        .logs
        .push("info", format!("已更新配置：{}", profile.name))
        .await;
    Ok(Json(profile))
}

async fn delete_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await
        && state.active_profile_id.read().await.as_deref() == Some(id.as_str())
    {
        return Err(ApiError::conflict("连接中的配置不能删除，请先断开"));
    }
    let mut candidate = state.profiles.read().await.clone();
    candidate.remove(&id).map_err(ApiError::bad_request)?;
    save_profiles(&state, candidate).await?;
    if state.active_profile_id.read().await.as_deref() == Some(id.as_str()) {
        *state.active_profile_id.write().await = None;
    }
    state.logs.push("info", format!("已删除配置：{id}")).await;
    Ok(Json(ApiMessage::new("配置已删除")))
}

async fn copy_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
) -> Result<Json<NetworkProfile>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let mut candidate = state.profiles.read().await.clone();
    let profile = candidate.copy(&id).map_err(ApiError::bad_request)?;
    save_profiles(&state, candidate).await?;
    state
        .logs
        .push("info", format!("已复制配置：{}", profile.name))
        .await;
    Ok(Json(profile))
}

async fn set_default_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let mut candidate = state.profiles.read().await.clone();
    candidate.set_default(&id).map_err(ApiError::bad_request)?;
    let profile = candidate.default_profile().clone();
    save_profiles(&state, candidate).await?;
    if !state.controller.is_active().await {
        activate_profile_config(&state, &profile).await?;
    }
    state
        .logs
        .push("info", format!("已设为默认配置：{}", profile.name))
        .await;
    Ok(Json(ApiMessage::new("默认配置已更新")))
}

async fn connect_profile(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let profile = state
        .profiles
        .read()
        .await
        .find(&id)
        .cloned()
        .ok_or_else(|| ApiError::not_found("配置不存在"))?;
    state.controller.stop().await;
    activate_profile_config(&state, &profile).await?;
    state
        .controller
        .start(profile.vnt)
        .await
        .map_err(ApiError::internal)?;
    *state.active_profile_id.write().await = Some(profile.id);
    state.logs.push("info", "已切换并连接配置").await;
    Ok(Json(ApiMessage::new("配置已连接")))
}

async fn export_profiles(State(state): State<Arc<ApiState>>) -> Json<ProfileBackup> {
    Json(state.profiles.read().await.backup())
}

async fn import_profiles(
    State(state): State<Arc<ApiState>>,
    Json(request): Json<ImportProfiles>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await {
        return Err(ApiError::conflict("请先断开网络，再导入配置"));
    }
    let mut candidate = state.profiles.read().await.clone();
    candidate.import(request).map_err(ApiError::bad_request)?;
    let profile = candidate.default_profile().clone();
    save_profiles(&state, candidate).await?;
    activate_profile_config(&state, &profile).await?;
    *state.active_profile_id.write().await = None;
    state.logs.push("info", "已导入配置档案").await;
    Ok(Json(ApiMessage::new("配置已导入")))
}

async fn save_profiles(state: &ApiState, profiles: ProfileStore) -> Result<(), ApiError> {
    profiles
        .save(&state.profiles_path)
        .await
        .map_err(ApiError::internal)?;
    *state.profiles.write().await = profiles;
    Ok(())
}

async fn activate_profile_config(
    state: &ApiState,
    profile: &NetworkProfile,
) -> Result<(), ApiError> {
    let mut config = state.config.read().await.clone();
    config.vnt = profile.vnt.clone();
    config
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    *state.config.write().await = config;
    Ok(())
}

async fn stop(State(state): State<Arc<ApiState>>) -> Json<ApiMessage> {
    let _mutation = state.mutation.lock().await;
    state.controller.stop().await;
    state.logs.push("info", "VNT 网络已停止").await;
    Json(ApiMessage::new("VNT 已停止"))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct SettingsPayload {
    #[serde(default = "default_experience_mode")]
    experience_mode: String,
    theme_mode: String,
    theme_accent: String,
    refresh_interval_seconds: u64,
    auto_connect: bool,
}

fn default_experience_mode() -> String {
    "minimal".to_string()
}

async fn get_settings(State(state): State<Arc<ApiState>>) -> Json<SettingsPayload> {
    let settings = state.settings.read().await.clone();
    Json(SettingsPayload {
        experience_mode: settings.experience_mode,
        theme_mode: settings.theme_mode,
        theme_accent: settings.theme_accent,
        refresh_interval_seconds: settings.refresh_interval_seconds,
        auto_connect: state.config.read().await.auto_start,
    })
}

async fn update_settings(
    State(state): State<Arc<ApiState>>,
    Json(payload): Json<SettingsPayload>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let settings = AppSettings {
        experience_mode: payload.experience_mode,
        theme_mode: payload.theme_mode,
        theme_accent: payload.theme_accent,
        refresh_interval_seconds: payload.refresh_interval_seconds,
    };
    settings.validate().map_err(ApiError::bad_request)?;
    let mut config = state.config.read().await.clone();
    config.auto_start = payload.auto_connect;
    config
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    settings
        .save(&state.settings_path)
        .await
        .map_err(ApiError::internal)?;
    *state.config.write().await = config;
    *state.settings.write().await = settings;
    state.logs.push("info", "WebUI 设置已更新").await;
    Ok(Json(ApiMessage::new("设置已保存")))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct AccessTokenPayload {
    access_token: String,
}

async fn update_access_token(
    State(state): State<Arc<ApiState>>,
    Json(payload): Json<AccessTokenPayload>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    let mut config = state.config.read().await.clone();
    config.web.access_token = Some(payload.access_token.trim().to_string());
    config.validate().map_err(ApiError::bad_request)?;
    config
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    *state.config.write().await = config;
    state.logs.push("info", "WebUI 访问密码已更新").await;
    Ok(Json(ApiMessage::new("访问密码已更新")))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct FullBackup {
    schema_version: u32,
    exported_at_unix: u64,
    auto_connect: bool,
    settings: AppSettings,
    profiles: ProfileBackup,
}

async fn export_backup(State(state): State<Arc<ApiState>>) -> Json<FullBackup> {
    Json(FullBackup {
        schema_version: 1,
        exported_at_unix: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        auto_connect: state.config.read().await.auto_start,
        settings: state.settings.read().await.clone(),
        profiles: state.profiles.read().await.backup(),
    })
}

async fn restore_backup(
    State(state): State<Arc<ApiState>>,
    Json(backup): Json<FullBackup>,
) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await {
        return Err(ApiError::conflict("请先断开网络，再恢复备份"));
    }
    if backup.schema_version != 1 {
        return Err(ApiError::bad_request("不支持的完整备份版本"));
    }
    backup.settings.validate().map_err(ApiError::bad_request)?;
    let mut profiles = state.profiles.read().await.clone();
    profiles
        .import(ImportProfiles {
            mode: crate::profile_store::ImportMode::Replace,
            backup: backup.profiles,
        })
        .map_err(ApiError::bad_request)?;
    let default_profile = profiles.default_profile().clone();
    profiles
        .save(&state.profiles_path)
        .await
        .map_err(ApiError::internal)?;
    backup
        .settings
        .save(&state.settings_path)
        .await
        .map_err(ApiError::internal)?;
    let mut config = state.config.read().await.clone();
    config.auto_start = backup.auto_connect;
    config.vnt = default_profile.vnt;
    config
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    *state.profiles.write().await = profiles;
    *state.settings.write().await = backup.settings;
    *state.config.write().await = config;
    *state.active_profile_id.write().await = None;
    state.logs.push("info", "已恢复完整配置备份").await;
    Ok(Json(ApiMessage::new("备份已恢复")))
}

async fn clear_data(State(state): State<Arc<ApiState>>) -> Result<Json<ApiMessage>, ApiError> {
    let _mutation = state.mutation.lock().await;
    if state.controller.is_active().await {
        return Err(ApiError::conflict("请先断开网络，再清理数据"));
    }
    let current_vnt = state.config.read().await.vnt.clone();
    let profiles = ProfileStore::from_legacy(current_vnt.clone());
    let settings = AppSettings::default();
    profiles
        .save(&state.profiles_path)
        .await
        .map_err(ApiError::internal)?;
    settings
        .save(&state.settings_path)
        .await
        .map_err(ApiError::internal)?;
    let mut config = state.config.read().await.clone();
    config.auto_start = false;
    config.vnt = current_vnt;
    config
        .save(&state.config_path)
        .await
        .map_err(ApiError::internal)?;
    *state.profiles.write().await = profiles;
    *state.settings.write().await = settings;
    *state.config.write().await = config;
    *state.active_profile_id.write().await = None;
    state.logs.clear().await;
    state.logs.push("info", "WebUI 数据已重置").await;
    Ok(Json(ApiMessage::new("数据已重置")))
}

async fn get_logs(State(state): State<Arc<ApiState>>) -> Json<Vec<LogEntry>> {
    Json(state.logs.snapshot().await)
}

async fn clear_logs(State(state): State<Arc<ApiState>>) -> Json<ApiMessage> {
    state.logs.clear().await;
    Json(ApiMessage::new("日志已清空"))
}

async fn download_logs(State(state): State<Arc<ApiState>>) -> Response {
    let mut response = Response::new(Body::from(state.logs.as_text().await));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("attachment; filename=VNTC-Linux-WebUI.log"),
    );
    response
}

#[derive(Serialize)]
struct AboutInfo {
    product: &'static str,
    version: &'static str,
    vnt_core_version: &'static str,
    platform: String,
    run_mode: &'static str,
    build_profile: &'static str,
    build_time: &'static str,
}

async fn about() -> Json<AboutInfo> {
    Json(AboutInfo {
        product: "VNTC Linux WebUI",
        version: app_version(),
        vnt_core_version: "2.0.0",
        platform: format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH),
        run_mode: if PathBuf::from("/.dockerenv").exists() {
            "Docker 容器"
        } else {
            "Linux 服务"
        },
        build_profile: if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        },
        build_time: option_env!("VNTC_BUILD_TIME").unwrap_or("构建时未注入"),
    })
}

fn app_version() -> &'static str {
    option_env!("VNTC_APP_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

async fn authorize(
    State(state): State<Arc<ApiState>>,
    headers: HeaderMap,
    request: Request<Body>,
    next: Next,
) -> Result<Response, ApiError> {
    let expected = state.config.read().await.web.access_token.clone();
    let Some(expected) = expected else {
        return Ok(next.run(request).await);
    };
    let supplied = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if supplied.is_some_and(|value| constant_time_eq(value.as_bytes(), expected.as_bytes())) {
        Ok(next.run(request).await)
    } else {
        Err(ApiError::unauthorized("访问令牌无效"))
    }
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

#[derive(Serialize)]
struct ApiMessage {
    message: String,
}

impl ApiMessage {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(error: impl std::fmt::Display) -> Self {
        Self::new(StatusCode::BAD_REQUEST, error.to_string())
    }

    fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, message)
    }

    fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, message)
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, message)
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, error.to_string())
    }

    fn new(status: StatusCode, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(ApiMessage::new(self.message))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::Request;
    use tower::ServiceExt;

    fn test_state(token: Option<&str>) -> Arc<ApiState> {
        let mut config = AppConfig::default();
        config.vnt.server_addresses = vec!["quic://127.0.0.1:2225".to_string()];
        config.vnt.network_code = "test".to_string();
        config.web.access_token = token.map(str::to_string);
        Arc::new(ApiState::new(config, PathBuf::from("unused.json")).unwrap())
    }

    fn persistent_test_state() -> (tempfile::TempDir, Arc<ApiState>) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        let mut config = AppConfig::default();
        config.vnt.server_addresses = vec!["quic://127.0.0.1:2225".to_string()];
        config.vnt.network_code = "test".to_string();
        std::fs::write(&path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();
        let state = Arc::new(ApiState::new(config, path).unwrap());
        (directory, state)
    }

    #[tokio::test]
    async fn health_does_not_require_authentication() {
        let response = router(test_state(Some("1234567890abcdef")))
            .oneshot(Request::get("/api/health").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn root_serves_embedded_webui() {
        let response = router(test_state(None))
            .oneshot(Request::get("/").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "text/html; charset=utf-8"
        );
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8_lossy(&body);
        assert!(html.contains("VNTC Linux"));
        assert!(html.contains("statusUptime"));
    }

    #[tokio::test]
    async fn embedded_assets_have_safe_content_types() {
        let app = router(test_state(None));
        let javascript = app
            .clone()
            .oneshot(
                Request::get("/assets/js/app.js")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            javascript.headers().get(header::CONTENT_TYPE).unwrap(),
            "text/javascript; charset=utf-8"
        );
        assert!(
            javascript
                .headers()
                .contains_key(header::CONTENT_SECURITY_POLICY)
        );

        let stylesheet = app
            .oneshot(
                Request::get("/assets/styles/responsive.css")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            stylesheet.headers().get(header::CONTENT_TYPE).unwrap(),
            "text/css; charset=utf-8"
        );
    }

    #[tokio::test]
    async fn protected_routes_reject_missing_token() {
        let response = router(test_state(Some("1234567890abcdef")))
            .oneshot(Request::get("/api/status").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn stopped_status_is_available_with_valid_token() {
        let response = router(test_state(Some("1234567890abcdef")))
            .oneshot(
                Request::get("/api/status")
                    .header("authorization", "Bearer 1234567890abcdef")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["phase"], "stopped");
        assert!(value["uptime_seconds"].is_null());
    }

    #[tokio::test]
    async fn config_update_rejects_invalid_server_address() {
        let state = test_state(None);
        let mut config = state.config.read().await.vnt.clone();
        config.server_addresses = vec!["invalid://server".to_string()];
        let body = serde_json::to_vec(&config).unwrap();
        let response = router(state)
            .oneshot(
                Request::put("/api/config")
                    .header("content-type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn profile_api_creates_and_lists_profiles() {
        let (_directory, state) = persistent_test_state();
        let input = ProfileInput {
            name: "第二配置".to_string(),
            vnt: state.config.read().await.vnt.clone(),
        };
        let response = router(state.clone())
            .oneshot(
                Request::post("/api/profiles")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&input).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let response = router(state)
            .oneshot(Request::get("/api/profiles").body(Body::empty()).unwrap())
            .await
            .unwrap();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["profiles"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn settings_persist_and_backup_excludes_access_token() {
        let (directory, state) = persistent_test_state();
        let legacy_payload: SettingsPayload = serde_json::from_value(serde_json::json!({
            "theme_mode": "system",
            "theme_accent": "blue",
            "refresh_interval_seconds": 5,
            "auto_connect": false
        }))
        .unwrap();
        assert_eq!(legacy_payload.experience_mode, "minimal");
        let payload = SettingsPayload {
            experience_mode: "professional".to_string(),
            theme_mode: "dark".to_string(),
            theme_accent: "green".to_string(),
            refresh_interval_seconds: 10,
            auto_connect: true,
        };
        let response = router(state.clone())
            .oneshot(
                Request::put("/api/settings")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&payload).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(directory.path().join("settings.json").exists());

        let response = router(state)
            .oneshot(Request::get("/api/backup").body(Body::empty()).unwrap())
            .await
            .unwrap();
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let text = String::from_utf8(body.to_vec()).unwrap();
        assert!(text.contains("\"experience_mode\":\"professional\""));
        assert!(text.contains("\"theme_mode\":\"dark\""));
        assert!(!text.contains("access_token"));
    }

    #[tokio::test]
    async fn access_token_update_persists_and_takes_effect_immediately() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        let mut config = AppConfig::default();
        config.web.listen = "0.0.0.0".parse().unwrap();
        config.web.access_token = Some("old-password".to_string());
        config.vnt.server_addresses = vec!["quic://127.0.0.1:2225".to_string()];
        config.vnt.network_code = "test".to_string();
        std::fs::write(&path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();
        let state = Arc::new(ApiState::new(config, path.clone()).unwrap());

        let response = router(state.clone())
            .oneshot(
                Request::put("/api/settings/access-token")
                    .header("authorization", "Bearer old-password")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_vec(&AccessTokenPayload {
                            access_token: "new-password".to_string(),
                        })
                        .unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let persisted = AppConfig::load(&path).unwrap();
        assert_eq!(persisted.web.access_token.as_deref(), Some("new-password"));

        let old_password = router(state.clone())
            .oneshot(
                Request::get("/api/status")
                    .header("authorization", "Bearer old-password")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(old_password.status(), StatusCode::UNAUTHORIZED);

        let new_password = router(state.clone())
            .oneshot(
                Request::get("/api/status")
                    .header("authorization", "Bearer new-password")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(new_password.status(), StatusCode::OK);

        let empty_password = router(state)
            .oneshot(
                Request::put("/api/settings/access-token")
                    .header("authorization", "Bearer new-password")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"access_token":"   "}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(empty_password.status(), StatusCode::BAD_REQUEST);
    }
}

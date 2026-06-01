const state = {
  config: null,
  status: null,
  account: null,
  theme: "dark",
  logSource: null,
  logLines: [],
  sessionUser: null,
  refreshTimer: null,
};

const THEME_STORAGE_KEY = "vnt_panel_theme";

const dom = {};

document.addEventListener("DOMContentLoaded", () => {
  collectDom();
  applyTheme(loadThemePreference(), { persist: false });
  bindEvents();
  init();
});

async function init() {
  await checkSession();
}

function collectDom() {
  Object.assign(dom, {
    loginOverlay: document.getElementById("loginOverlay"),
    loginForm: document.getElementById("loginForm"),
    loginUsername: document.getElementById("loginUsername"),
    loginPassword: document.getElementById("loginPassword"),
    loginError: document.getElementById("loginError"),
    logoutButton: document.getElementById("logoutButton"),
    themeToggleButton: document.getElementById("themeToggleButton"),
    themeModeText: document.getElementById("themeModeText"),
    sessionUser: document.getElementById("sessionUser"),
    toastStack: document.getElementById("toastStack"),
    refreshOverviewButton: document.getElementById("refreshOverviewButton"),
    reloadConfigButton: document.getElementById("reloadConfigButton"),
    refreshLogsButton: document.getElementById("refreshLogsButton"),
    saveStructuredButton: document.getElementById("saveStructuredButton"),
    saveStructuredRestartButton: document.getElementById("saveStructuredRestartButton"),
    saveRawButton: document.getElementById("saveRawButton"),
    saveRawRestartButton: document.getElementById("saveRawRestartButton"),
    saveAccountButton: document.getElementById("saveAccountButton"),
    resetRawButton: document.getElementById("resetRawButton"),
    structuredForm: document.getElementById("structuredForm"),
    customNetsList: document.getElementById("customNetsList"),
    customNetTemplate: document.getElementById("customNetTemplate"),
    addCustomNetButton: document.getElementById("addCustomNetButton"),
    rawEditor: document.getElementById("rawEditor"),
    logConsole: document.getElementById("logConsole"),
    streamState: document.getElementById("streamState"),
    serviceBadge: document.getElementById("serviceBadge"),
    serviceHeadline: document.getElementById("serviceHeadline"),
    serviceSubline: document.getElementById("serviceSubline"),
    metricPid: document.getElementById("metricPid"),
    metricElapsed: document.getElementById("metricElapsed"),
    metricCpu: document.getElementById("metricCpu"),
    metricMemory: document.getElementById("metricMemory"),
    navStatusDot: document.getElementById("navStatusDot"),
    navStatusText: document.getElementById("navStatusText"),
    serviceNameMini: document.getElementById("serviceNameMini"),
    configPathMini: document.getElementById("configPathMini"),
    summaryConfigPath: document.getElementById("summaryConfigPath"),
    summaryServiceName: document.getElementById("summaryServiceName"),
    summaryBackupDir: document.getElementById("summaryBackupDir"),
    summaryEndpoints: document.getElementById("summaryEndpoints"),
    metaActiveState: document.getElementById("metaActiveState"),
    metaSubState: document.getElementById("metaSubState"),
    metaLoadState: document.getElementById("metaLoadState"),
    metaActiveSince: document.getElementById("metaActiveSince"),
    metaConfigUpdatedAt: document.getElementById("metaConfigUpdatedAt"),
    metaCommand: document.getElementById("metaCommand"),
    accountUsername: document.getElementById("accountUsername"),
    accountPassword: document.getElementById("accountPassword"),
    accountPasswordConfirm: document.getElementById("accountPasswordConfirm"),
    accountCurrentUsername: document.getElementById("accountCurrentUsername"),
    accountFilePath: document.getElementById("accountFilePath"),
    accountUpdatedAt: document.getElementById("accountUpdatedAt"),
  });
}

function bindEvents() {
  dom.loginForm.addEventListener("submit", login);
  dom.logoutButton.addEventListener("click", () => runTask(logout));
  dom.themeToggleButton.addEventListener("click", toggleTheme);
  dom.refreshOverviewButton.addEventListener("click", () => runTask(refreshOverview));
  dom.reloadConfigButton.addEventListener("click", () => runTask(reloadConfigOnly));
  dom.refreshLogsButton.addEventListener("click", () => runTask(refreshLogsSnapshot));
  dom.saveStructuredButton.addEventListener("click", () => runTask(() => saveStructured(false)));
  dom.saveStructuredRestartButton.addEventListener("click", () => runTask(() => saveStructured(true)));
  dom.saveRawButton.addEventListener("click", () => runTask(() => saveRaw(false)));
  dom.saveRawRestartButton.addEventListener("click", () => runTask(() => saveRaw(true)));
  dom.saveAccountButton.addEventListener("click", () => runTask(saveAccountSettings));
  dom.resetRawButton.addEventListener("click", resetRawEditor);
  dom.addCustomNetButton.addEventListener("click", () => addCustomNetRow());

  document.querySelectorAll("[data-service-action]").forEach((button) => {
    button.addEventListener("click", () => runTask(() => serviceAction(button.dataset.serviceAction)));
  });

  document.querySelectorAll("[data-scroll-target]").forEach((button) => {
    button.addEventListener("click", () => {
      document.getElementById(button.dataset.scrollTarget)?.scrollIntoView({ behavior: "smooth" });
    });
  });
}

async function checkSession() {
  try {
    const session = await api("/api/session", { allowUnauthorized: true });
    if (!session.authenticated) {
      showLoggedOut();
      return;
    }
    state.sessionUser = session.user;
    showLoggedIn();
    await loadOverview();
  } catch (error) {
    showToast(error.message, "error");
    showLoggedOut();
  }
}

async function login(event) {
  event.preventDefault();
  dom.loginError.textContent = "";
  try {
    await api("/api/login", {
      method: "POST",
      body: {
        username: dom.loginUsername.value.trim(),
        password: dom.loginPassword.value,
      },
    });
    state.sessionUser = dom.loginUsername.value.trim();
    showToast("登录成功，正在同步控制台。");
    showLoggedIn();
    await loadOverview();
  } catch (error) {
    dom.loginError.textContent = error.message;
  }
}

async function logout() {
  try {
    await api("/api/logout", { method: "POST", body: {} });
  } finally {
    closeLogStream();
    clearInterval(state.refreshTimer);
    state.refreshTimer = null;
    showLoggedOut();
  }
}

function showLoggedIn() {
  dom.loginOverlay.classList.add("hidden");
  dom.sessionUser.textContent = state.sessionUser || "已登录";
}

function showLoggedOut() {
  dom.loginOverlay.classList.remove("hidden");
  dom.sessionUser.textContent = "未登录";
  dom.streamState.textContent = "未连接";
  dom.streamState.classList.add("offline");
}

function loadThemePreference() {
  try {
    return localStorage.getItem(THEME_STORAGE_KEY) || "dark";
  } catch (error) {
    return "dark";
  }
}

function applyTheme(theme, options = {}) {
  const normalized = theme === "light" ? "light" : "dark";
  state.theme = normalized;
  document.documentElement.setAttribute("data-theme", normalized);
  updateThemeUi();
  if (options.persist === false) {
    return;
  }
  try {
    localStorage.setItem(THEME_STORAGE_KEY, normalized);
  } catch (error) {
    return;
  }
}

function updateThemeUi() {
  if (!dom.themeToggleButton || !dom.themeModeText) {
    return;
  }
  const dark = state.theme === "dark";
  dom.themeModeText.textContent = dark ? "深灰磨砂" : "暖白浅色";
  dom.themeToggleButton.textContent = dark ? "切换到浅色" : "切换到深色";
}

function toggleTheme() {
  const nextTheme = state.theme === "dark" ? "light" : "dark";
  applyTheme(nextTheme);
  showToast(nextTheme === "dark" ? "已切换到深灰磨砂主题。" : "已切换到浅色主题。");
}

async function loadOverview() {
  const overview = await api("/api/overview");
  renderMeta(overview.meta);
  renderStatus(overview.status);
  renderConfig(overview.config);
  renderAccount(overview.account);
  await refreshLogsSnapshot();
  connectLogStream();
  clearInterval(state.refreshTimer);
  state.refreshTimer = setInterval(refreshStatusSilently, 10000);
}

async function refreshOverview() {
  const overview = await api("/api/overview");
  renderMeta(overview.meta);
  renderStatus(overview.status);
  renderConfig(overview.config);
  renderAccount(overview.account);
  showToast("面板数据已刷新。");
}

async function reloadConfigOnly() {
  const config = await api("/api/config");
  renderConfig(config);
  showToast("配置已从服务器重新载入。");
}

async function refreshStatusSilently() {
  try {
    const status = await api("/api/status");
    renderStatus(status);
  } catch (error) {
    setStreamState("状态刷新失败", true);
  }
}

async function refreshLogsSnapshot() {
  const payload = await api("/api/logs?lines=200");
  state.logLines = payload.lines.slice(-200);
  renderLogs();
  showToast("日志快照已更新。");
}

async function runTask(task) {
  try {
    return await task();
  } catch (error) {
    showToast(error.message || "操作失败。", "error");
    return null;
  }
}

async function serviceAction(action) {
  if (action === "stop" && !window.confirm("确定要停止 VNT 服务吗？")) {
    return;
  }
  const payload = await api("/api/service", {
    method: "POST",
    body: { action },
  });
  renderStatus(payload.status);
  showToast(payload.message);
  await refreshLogsSnapshot();
}

async function saveStructured(restart) {
  const body = collectStructuredPayload();
  body.restart = restart;
  const payload = await api("/api/config/structured", {
    method: "PUT",
    body,
  });
  renderStatus(payload.status);
  renderConfig(payload.config);
  showToast(restart ? "配置已保存并重启服务。" : "配置已保存。");
}

async function saveRaw(restart) {
  const payload = await api("/api/config/raw", {
    method: "PUT",
    body: {
      raw: dom.rawEditor.value,
      restart,
    },
  });
  renderStatus(payload.status);
  renderConfig(payload.config);
  showToast(restart ? "TOML 已保存并重启服务。" : "TOML 已保存。");
}

async function saveAccountSettings() {
  const payload = await api("/api/settings/account", {
    method: "PUT",
    body: {
      username: dom.accountUsername.value.trim(),
      password: dom.accountPassword.value,
      confirm_password: dom.accountPasswordConfirm.value,
    },
  });
  renderAccount(payload.account);
  state.sessionUser = payload.account.username;
  dom.sessionUser.textContent = payload.account.username;
  dom.accountPassword.value = "";
  dom.accountPasswordConfirm.value = "";
  showToast(payload.message);
}

function collectStructuredPayload() {
  return {
    tcp_bind: valueOf("tcpBind"),
    quic_bind: valueOf("quicBind"),
    ws_bind: valueOf("wsBind"),
    network: valueOf("network"),
    white_list: splitLines(valueOf("whiteList")),
    lease_duration: Number(valueOf("leaseDuration") || 0),
    web_bind: valueOf("webBind"),
    username: valueOf("username"),
    password: valueOf("password"),
    persistence: document.getElementById("persistence").checked,
    cert: valueOf("cert"),
    key: valueOf("key"),
    server_quic_bind: valueOf("serverQuicBind"),
    peer_servers: splitLines(valueOf("peerServers")),
    server_token: valueOf("serverToken"),
    custom_nets: Array.from(dom.customNetsList.querySelectorAll(".custom-net-row"))
      .map((row) => ({
        name: row.querySelector(".custom-net-name").value.trim(),
        cidr: row.querySelector(".custom-net-cidr").value.trim(),
      }))
      .filter((item) => item.name || item.cidr),
  };
}

function renderMeta(meta) {
  dom.serviceNameMini.textContent = meta.service_name;
  dom.configPathMini.textContent = meta.config_path;
  dom.summaryConfigPath.textContent = meta.config_path;
  dom.summaryServiceName.textContent = meta.service_name;
  dom.summaryBackupDir.textContent = meta.backup_dir;
}

function renderAccount(account) {
  state.account = account;
  if (!account) {
    return;
  }
  dom.accountUsername.value = account.username || "";
  dom.accountCurrentUsername.textContent = account.username || "-";
  dom.accountFilePath.textContent = account.credentials_path || "-";
  dom.accountUpdatedAt.textContent = account.updated_at || "-";
}

function renderStatus(status) {
  state.status = status;
  const active = status.is_active;
  dom.serviceBadge.textContent = active ? "Active" : status.active_state || "Inactive";
  dom.serviceBadge.className = `status-badge ${active ? "active" : "inactive"}`;
  dom.serviceHeadline.textContent = active ? "VNT 服务正在运行" : "VNT 服务当前未运行";
  dom.serviceSubline.textContent = status.description || "未检测到额外描述信息。";
  dom.metricPid.textContent = status.pid || "-";
  dom.metricElapsed.textContent = status.process?.elapsed || "-";
  dom.metricCpu.textContent = status.process?.cpu_display || (status.process?.cpu_percent ? `${status.process.cpu_percent}%` : "-");
  dom.metricMemory.textContent = status.process?.memory_display || (status.process?.memory_percent ? `${status.process.memory_percent}%` : "-");
  dom.navStatusText.textContent = active ? "服务运行中" : "服务未运行";
  dom.navStatusDot.className = `dot ${active ? "active" : "inactive"}`;
  dom.metaActiveState.textContent = status.active_state || "-";
  dom.metaSubState.textContent = status.sub_state || "-";
  dom.metaLoadState.textContent = status.load_state || "-";
  dom.metaActiveSince.textContent = status.active_since || "-";
  dom.metaCommand.textContent = status.process?.command || "-";
}

function renderConfig(config) {
  state.config = config;
  const structured = config.structured;
  document.getElementById("tcpBind").value = structured.tcp_bind || "";
  document.getElementById("quicBind").value = structured.quic_bind || "";
  document.getElementById("wsBind").value = structured.ws_bind || "";
  document.getElementById("webBind").value = structured.web_bind || "";
  document.getElementById("network").value = structured.network || "";
  document.getElementById("leaseDuration").value = structured.lease_duration || "";
  document.getElementById("username").value = structured.username || "";
  document.getElementById("password").value = structured.password || "";
  document.getElementById("cert").value = structured.cert || "";
  document.getElementById("key").value = structured.key || "";
  document.getElementById("serverQuicBind").value = structured.server_quic_bind || "";
  document.getElementById("serverToken").value = structured.server_token || "";
  document.getElementById("whiteList").value = (structured.white_list || []).join("\n");
  document.getElementById("peerServers").value = (structured.peer_servers || []).join("\n");
  document.getElementById("persistence").checked = Boolean(structured.persistence);
  dom.rawEditor.value = config.raw || "";
  dom.metaConfigUpdatedAt.textContent = config.updated_at || "-";
  renderCustomNets(structured.custom_nets || []);
  dom.summaryEndpoints.textContent = summarizeEndpoints(structured);
}

function renderCustomNets(items) {
  dom.customNetsList.innerHTML = "";
  if (!items.length) {
    addCustomNetRow();
    return;
  }
  items.forEach((item) => addCustomNetRow(item));
}

function addCustomNetRow(item = {}) {
  const fragment = dom.customNetTemplate.content.cloneNode(true);
  const row = fragment.querySelector(".custom-net-row");
  row.querySelector(".custom-net-name").value = item.name || "";
  row.querySelector(".custom-net-cidr").value = item.cidr || "";
  row.querySelector("button").addEventListener("click", () => row.remove());
  dom.customNetsList.appendChild(fragment);
}

function resetRawEditor() {
  if (!state.config) {
    return;
  }
  dom.rawEditor.value = state.config.raw || "";
  showToast("高级编辑器已恢复到服务器当前版本。");
}

function renderLogs() {
  dom.logConsole.textContent = state.logLines.join("\n");
  dom.logConsole.scrollTop = dom.logConsole.scrollHeight;
}

function connectLogStream() {
  closeLogStream();
  const source = new EventSource("/api/logs/stream?lines=40");
  state.logSource = source;
  setStreamState("流连接中", false);

  source.onmessage = (event) => {
    const payload = JSON.parse(event.data);
    if (!payload.line) {
      return;
    }
    state.logLines.push(payload.line);
    if (state.logLines.length > 400) {
      state.logLines = state.logLines.slice(-400);
    }
    renderLogs();
  };

  source.onerror = () => {
    setStreamState("流连接中断，等待重连", true);
  };
}

function closeLogStream() {
  if (state.logSource) {
    state.logSource.close();
    state.logSource = null;
  }
}

function setStreamState(text, offline) {
  dom.streamState.textContent = text;
  dom.streamState.classList.toggle("offline", offline);
}

function summarizeEndpoints(config) {
  const parts = [config.tcp_bind, config.quic_bind, config.ws_bind].filter(Boolean);
  return parts.length ? parts.join(" / ") : "未配置";
}

function splitLines(value) {
  return value
    .split(/\r?\n|,/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function valueOf(id) {
  return document.getElementById(id).value.trim();
}

async function api(url, options = {}) {
  const { allowUnauthorized = false, method = "GET", body } = options;
  const response = await fetch(url, {
    method,
    headers: {
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
    credentials: "same-origin",
  });
  if (response.status === 401 && allowUnauthorized) {
    return { authenticated: false };
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || "请求失败。");
  }
  return payload;
}

function showToast(message, type = "info") {
  const toast = document.createElement("div");
  toast.className = `toast ${type}`;
  toast.textContent = message;
  dom.toastStack.appendChild(toast);
  window.setTimeout(() => {
    toast.remove();
  }, 3200);
}

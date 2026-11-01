import { get, put } from "./api.js";
import { $, isOpenWrt, refreshIntervalMs, setToken, state, updateTraffic } from "./state.js";
import { bindRouter, refreshCurrentRoute, registerRoute } from "./router.js";
import { closeModal, hideAuth, renderStatusChip, setHealth, showAuth, toast } from "./ui.js";
import { renderDashboard } from "./pages/dashboard.js";

const themeKey = "vntcThemeMode";
const accentKey = "vntcThemeAccent";
let refreshInFlight = null;
const liveRoute = () => state.route === "dashboard" || state.route === "link-status";

function applyAppearance(settings = state.settings) {
  document.documentElement.dataset.theme = localStorage.getItem(themeKey) || settings?.theme_mode || "system";
  document.documentElement.dataset.accent = localStorage.getItem(accentKey) || settings?.theme_accent || "blue";
}

function applyExperienceMode(settings = state.settings) {
  document.documentElement.dataset.experience = settings?.experience_mode || "minimal";
}

function configureRefreshTimer() {
  if (state.refreshTimer != null) window.clearTimeout(state.refreshTimer);
  state.refreshTimer = null;
  if (refreshInFlight || (isOpenWrt && (document.hidden || !liveRoute() || !$("authOverlay").hidden))) return;
  const interval = refreshIntervalMs(state.settings);
  state.refreshIntervalMs = interval;
  state.refreshTimer = window.setTimeout(() => {
    state.refreshTimer = null;
    refreshStatus(true, { full: !isOpenWrt });
  }, interval);
}

function refreshStatus(silent = true, { full = true } = {}) {
  if (refreshInFlight) return full ? refreshInFlight.then(() => refreshStatus(silent, { full })) : refreshInFlight;
  refreshInFlight = performRefresh(silent, full).finally(() => { refreshInFlight = null; configureRefreshTimer(); });
  return refreshInFlight;
}

async function performRefresh(silent, full) {
  const linkView = () => JSON.stringify([state.peers, state.routes, state.traffic, state.config, state.status?.phase, state.status?.virtual_ip, state.status?.nat_type]);
  const previousLink = isOpenWrt && state.route === "link-status" ? linkView() : null;
  try {
    if (isOpenWrt) {
      const [snapshot, config, profileData, settings] = await Promise.all([
        get(`/snapshot${state.route === "link-status" ? "?details=true" : ""}`),
        full ? get("/config") : null,
        full ? get("/profiles") : null,
        full ? get("/settings") : null,
      ]);
      state.status = snapshot.status;
      if (snapshot.peers) state.peers = snapshot.peers;
      if (snapshot.routes) state.routes = snapshot.routes;
      updateTraffic(snapshot.traffic);
      if (full) {
        state.config = config;
        state.profiles = profileData.profiles;
        state.profileMeta = { defaultId: profileData.default_profile_id, activeId: profileData.active_profile_id };
        state.settings = settings;
      }
    } else {
      const [status, peers, routes, traffic, config, profileData, settings] = await Promise.all([
        get("/status"), get("/peers"), get("/routes"), get("/traffic"), get("/config"), get("/profiles"), get("/settings"),
      ]);
      Object.assign(state, { status, peers, routes, config, settings, profiles: profileData.profiles });
      state.profileMeta = { defaultId: profileData.default_profile_id, activeId: profileData.active_profile_id };
      updateTraffic(traffic);
    }
    if (full) { applyAppearance(); applyExperienceMode(); }
    renderStatusChip(state.status);
    setHealth(true);
    if (!silent) toast("状态已刷新");
    if (liveRoute() && (!isOpenWrt || state.route === "dashboard" || full || previousLink !== linkView())) await refreshCurrentRoute();
    return true;
  } catch (error) {
    setHealth(false);
    if (error.status === 401) showAuth("访问令牌无效");
    else if (!silent) toast(error.message, "error");
    return false;
  }
}

function bindShell() {
  $("refreshButton").addEventListener("click", () => refreshStatus(false));
  document.addEventListener("vntc:refresh", () => refreshStatus(true));
  document.addEventListener("vntc:settings", () => { applyAppearance(); applyExperienceMode(); configureRefreshTimer(); });
  document.addEventListener("visibilitychange", () => {
    if (!isOpenWrt) return;
    configureRefreshTimer();
    if (!document.hidden && liveRoute() && $("authOverlay").hidden) refreshStatus(true, { full: false });
  });
  document.addEventListener("vntc:route", () => {
    if (!isOpenWrt) return;
    configureRefreshTimer();
    if (liveRoute() && state.status) refreshStatus(true);
  });
  $("themeToggle").addEventListener("click", async () => {
    const current = document.documentElement.dataset.theme;
    const next = current === "dark" ? "light" : "dark";
    localStorage.setItem(themeKey, next);
    applyAppearance();
    if (state.settings) {
      state.settings.theme_mode = next;
      try { await put("/settings", state.settings); } catch (error) { toast(error.message, "error"); }
    }
  });
  $("authForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    setToken($("accessToken").value.trim());
    if (await refreshStatus()) { hideAuth(); configureRefreshTimer(); }
  });
  $("modalLayer").addEventListener("click", (event) => { if (event.target === event.currentTarget || event.target.closest("[data-close-modal]")) closeModal(); });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeModal(); });
}

async function boot() {
  applyAppearance();
  applyExperienceMode();
  registerRoute("dashboard", renderDashboard);
  registerRoute("link-status", async (root) => (await import("./pages/link-status.js")).renderLinkStatus(root));
  registerRoute("configs", async (root) => (await import("./pages/configs.js")).renderConfigs(root));
  registerRoute("settings", async (root) => (await import("./pages/settings.js")).renderSettings(root));
  registerRoute("about", async (root) => (await import("./pages/about.js")).renderAbout(root));
  bindShell();
  bindRouter();
  await refreshStatus();
  configureRefreshTimer();
}

document.addEventListener("DOMContentLoaded", boot);

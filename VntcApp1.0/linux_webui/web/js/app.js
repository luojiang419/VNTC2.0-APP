import { get, put } from "./api.js";
import { $, setToken, state, updateTraffic } from "./state.js";
import { bindRouter, navigate, registerRoute } from "./router.js";
import { closeModal, hideAuth, renderStatusChip, setHealth, showAuth, toast } from "./ui.js";
import { renderDashboard } from "./pages/dashboard.js";
import { renderLinkStatus } from "./pages/link-status.js";
import { renderConfigs } from "./pages/configs.js";
import { renderSettings } from "./pages/settings.js";
import { renderAbout } from "./pages/about.js";

const themeKey = "vntcThemeMode";
const accentKey = "vntcThemeAccent";

function applyAppearance(settings = state.settings) {
  document.documentElement.dataset.theme = localStorage.getItem(themeKey) || settings?.theme_mode || "system";
  document.documentElement.dataset.accent = localStorage.getItem(accentKey) || settings?.theme_accent || "blue";
}

function applyExperienceMode(settings = state.settings) {
  document.documentElement.dataset.experience = settings?.experience_mode || "minimal";
}

function configureRefreshTimer() {
  const interval = (state.settings?.refresh_interval_seconds || 5) * 1000;
  if (state.refreshTimer && state.refreshIntervalMs === interval) return;
  if (state.refreshTimer) window.clearInterval(state.refreshTimer);
  state.refreshIntervalMs = interval;
  state.refreshTimer = window.setInterval(() => refreshStatus(true), interval);
}

async function refreshStatus(silent = true) {
  try {
    const [status, peers, routes, traffic, config, profileData, settings] = await Promise.all([
      get("/status"), get("/peers"), get("/routes"), get("/traffic"), get("/config"), get("/profiles"), get("/settings"),
    ]);
    state.status = status;
    state.peers = peers;
    state.routes = routes;
    state.config = config;
    state.profiles = profileData.profiles;
    state.profileMeta = { defaultId: profileData.default_profile_id, activeId: profileData.active_profile_id };
    state.settings = settings;
    applyAppearance(settings);
    applyExperienceMode(settings);
    configureRefreshTimer();
    updateTraffic(traffic);
    renderStatusChip(state.status);
    setHealth(true);
    if (!silent) toast("状态已刷新");
    if (state.route === "dashboard" || state.route === "link-status") await navigate(state.route);
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
    if (await refreshStatus()) hideAuth();
  });
  $("modalLayer").addEventListener("click", (event) => { if (event.target === event.currentTarget || event.target.closest("[data-close-modal]")) closeModal(); });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeModal(); });
}

async function boot() {
  applyAppearance();
  applyExperienceMode();
  registerRoute("dashboard", renderDashboard);
  registerRoute("link-status", renderLinkStatus);
  registerRoute("configs", renderConfigs);
  registerRoute("settings", renderSettings);
  registerRoute("about", renderAbout);
  bindShell();
  bindRouter();
  await refreshStatus();
  configureRefreshTimer();
}

document.addEventListener("DOMContentLoaded", boot);

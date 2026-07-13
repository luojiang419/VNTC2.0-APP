import { $ } from "./state.js";

export function toast(message, type = "success") {
  const element = document.createElement("div");
  element.className = `toast ${type}`;
  element.textContent = message;
  $("toastRegion").appendChild(element);
  window.setTimeout(() => element.remove(), 3600);
}

export function setHealth(ok) {
  $("healthDot").className = `health-dot ${ok ? "ok" : "error"}`;
  $("healthText").textContent = ok ? "控制面在线" : "控制面离线";
}

export function showAuth(message = "") {
  $("authError").textContent = message;
  $("authOverlay").hidden = false;
  window.setTimeout(() => $("accessToken").focus(), 30);
}

export function hideAuth() { $("authOverlay").hidden = true; $("authError").textContent = ""; }

export function openModal(content) {
  const layer = $("modalLayer");
  layer.innerHTML = content;
  layer.hidden = false;
  layer.querySelector("[data-close-modal]")?.focus();
}

export function closeModal() { const layer = $("modalLayer"); layer.hidden = true; layer.innerHTML = ""; }

export function phaseLabel(phase) {
  return { running: "运行中", starting: "连接中", stopped: "已停止", error: "连接异常" }[phase] || "未知状态";
}

export function formatUptime(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainingSeconds = total % 60;
  const pad = (value) => String(value).padStart(2, "0");
  return `${pad(days)}天${pad(hours)}小时${pad(minutes)}分${pad(remainingSeconds)}秒`;
}

export function projectedUptimeSeconds(uptimeSeconds, sampledAtMs, nowMs = Date.now()) {
  if (uptimeSeconds == null || !Number.isFinite(Number(uptimeSeconds))) return null;
  const base = Math.max(0, Math.floor(Number(uptimeSeconds)));
  const elapsed = Math.max(0, Math.floor((nowMs - sampledAtMs) / 1000));
  return base + elapsed;
}

export function statusUptimeSeconds(status, sampledAtMs, nowMs = Date.now()) {
  if (status?.phase !== "running") return null;
  return projectedUptimeSeconds(status.uptime_seconds, sampledAtMs, nowMs);
}

let uptimeTimer = null;
let uptimeBaseSeconds = null;
let uptimeSampledAtMs = 0;

function updateUptime() {
  const element = $("statusUptime");
  const seconds = projectedUptimeSeconds(uptimeBaseSeconds, uptimeSampledAtMs);
  if (seconds == null) return;
  element.textContent = formatUptime(seconds);
}

export function renderStatusChip(status) {
  const phase = status?.phase || "stopped";
  const chip = $("statusChip");
  const uptime = $("statusUptime");
  chip.className = `status-chip ${phase}`;
  chip.querySelector("strong").textContent = phaseLabel(phase);
  const sampledAtMs = Date.now();
  const initialUptime = statusUptimeSeconds(status, sampledAtMs, sampledAtMs);
  if (initialUptime != null) {
    uptimeBaseSeconds = initialUptime;
    uptimeSampledAtMs = sampledAtMs;
    uptime.hidden = false;
    updateUptime();
    if (uptimeTimer == null) uptimeTimer = window.setInterval(updateUptime, 1000);
    return;
  }
  uptimeBaseSeconds = null;
  uptimeSampledAtMs = 0;
  uptime.hidden = true;
  uptime.textContent = "";
  if (uptimeTimer != null) {
    window.clearInterval(uptimeTimer);
    uptimeTimer = null;
  }
}

export function formatBytes(bytes, suffix = "") {
  let size = Number(bytes || 0);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index += 1; }
  const digits = size >= 100 || index === 0 ? 0 : size >= 10 ? 1 : 2;
  return `${size.toFixed(digits)} ${units[index]}${suffix}`;
}

export function downloadJson(filename, value) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: "application/json" }));
  link.download = filename;
  link.click();
  URL.revokeObjectURL(link.href);
}

export function downloadText(filename, value) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([value], { type: "text/plain;charset=utf-8" }));
  link.download = filename;
  link.click();
  URL.revokeObjectURL(link.href);
}

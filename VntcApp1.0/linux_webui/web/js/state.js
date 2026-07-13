export const state = {
  token: sessionStorage.getItem("vntcAccessToken") || "",
  route: "dashboard",
  status: null,
  config: null,
  peers: [],
  routes: [],
  traffic: [],
  profiles: [],
  profileMeta: { defaultId: "", activeId: null },
  settings: null,
  trafficTotals: { tx: 0, rx: 0, txRate: 0, rxRate: 0, sampledAt: 0 },
  trafficHistory: [],
  refreshTimer: null,
  refreshIntervalMs: 0,
};

export const $ = (id) => document.getElementById(id);
export const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[char]);
export const splitLines = (value) => value.split(/\r?\n/).map((item) => item.trim()).filter(Boolean);
export const joinLines = (value) => Array.isArray(value) ? value.join("\n") : "";

export function setToken(token) {
  state.token = token;
  sessionStorage.setItem("vntcAccessToken", token);
}

export function updateTraffic(traffic) {
  const now = Date.now();
  const tx = traffic.reduce((sum, item) => sum + Number(item.tx_bytes || 0), 0);
  const rx = traffic.reduce((sum, item) => sum + Number(item.rx_bytes || 0), 0);
  const previous = state.trafficTotals;
  const seconds = previous.sampledAt ? Math.max((now - previous.sampledAt) / 1000, .25) : 0;
  const txRate = seconds ? Math.max(0, (tx - previous.tx) / seconds) : 0;
  const rxRate = seconds ? Math.max(0, (rx - previous.rx) / seconds) : 0;
  state.traffic = traffic;
  state.trafficTotals = { tx, rx, txRate, rxRate, sampledAt: now };
  state.trafficHistory.push({ txRate, rxRate });
  if (state.trafficHistory.length > 24) state.trafficHistory.shift();
}

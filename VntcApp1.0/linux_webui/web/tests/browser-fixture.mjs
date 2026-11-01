import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";

export async function boot(platform) {
  const source = await readFile(new URL("../index.html", import.meta.url), "utf8");
  const dom = new JSDOM(source, { url: "http://router.local/" });
  const { window } = dom;
  if (platform === "openwrt") window.document.documentElement.dataset.platform = platform;
  window.sessionStorage.setItem("vntcAccessToken", "test-token");
  const timers = new Map();
  let nextId = 1, now = 0, scrolls = 0, hidden = false;
  const calls = [];
  const data = {
    status: { phase: "running", virtual_ip: "10.77.0.2", virtual_network: "10.77.0.0/24", uptime_seconds: 20, connected_server: "quic://server:29872", online_peer_count: 1 },
    config: { device_name: "路由器", server_addresses: ["quic://server:29872"], tun_name: "vnt0", mtu: 1400 },
    settings: { experience_mode: "minimal", theme_mode: "light", theme_accent: "blue", auto_connect: true, refresh_interval_seconds: 5 },
    profiles: { profiles: [], default_profile_id: "p1", active_profile_id: "p1" },
  };
  window.setTimeout = (callback, delay) => { const id = nextId++; timers.set(id, { callback, at: now + delay }); return id; };
  window.clearTimeout = (id) => timers.delete(id);
  window.setInterval = (callback, delay) => { const id = nextId++; timers.set(id, { callback, at: now + delay, repeat: delay }); return id; };
  window.clearInterval = window.clearTimeout;
  window.scrollTo = () => { scrolls++; };
  Object.defineProperty(window.document, "hidden", { get: () => hidden });
  Object.assign(globalThis, { window, document: window.document, sessionStorage: window.sessionStorage, localStorage: window.localStorage,
    location: window.location, CustomEvent: window.CustomEvent, confirm: () => true });
  let heldSnapshot = null;
  globalThis.fetch = async (url, options = {}) => {
    const path = String(url).replace(/^\/api/, "");
    calls.push({ path, method: options.method || "GET" });
    if (data.requireAuth && new Headers(options.headers).get("Authorization") !== "Bearer test-token") {
      return new Response(JSON.stringify({ message: "令牌无效" }), { status: 401, headers: { "Content-Type": "application/json" } });
    }
    if (path.startsWith("/snapshot") && heldSnapshot) await heldSnapshot;
    let body;
    if (path.startsWith("/snapshot")) body = { status: data.status, traffic: [], ...(path.includes("details=true") ? { peers: [], routes: [] } : {}) };
    else if (path === "/stop") { data.status = { phase: "stopped", uptime_seconds: null }; body = { message: "已停止" }; }
    else if (path === "/start") { data.status = { ...data.status, phase: "running" }; body = { message: "已启动" }; }
    else body = data[path.slice(1)] || [];
    return new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
  };
  if (platform === "openwrt") {
    const { renderDashboard } = await import("../js/pages/openwrt-dashboard.js");
    // 实际服务器在 OpenWrt feature 下把此模块映射到 dashboard.js。
    const router = await import("../js/router.js");
    await import("../js/app.js");
    window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
    await flush();
    router.registerRoute("dashboard", renderDashboard);
    await router.navigate("dashboard");
  } else {
    await import("../js/app.js");
    window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
  }
  await flush();
  async function tick(ms) {
    now += ms;
    const due = [...timers.entries()].filter(([, timer]) => timer.at <= now);
    for (const [id, timer] of due) {
      if (!timers.has(id)) continue;
      if (timer.repeat) timer.at = now + timer.repeat; else timers.delete(id);
      timer.callback();
    }
    await flush();
  }
  return { dom, calls, data, timers, tick, scrolls: () => scrolls,
    setHidden(value) { hidden = value; document.dispatchEvent(new window.Event("visibilitychange")); },
    holdSnapshot() { let release; heldSnapshot = new Promise((resolve) => { release = resolve; }); return () => { heldSnapshot = null; release(); }; },
    close() { timers.clear(); dom.window.close(); },
  };
}

export async function flush() {
  for (let i = 0; i < 24; i++) await new Promise((resolve) => setImmediate(resolve));
}

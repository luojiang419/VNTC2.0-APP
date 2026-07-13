import { state, escapeHtml } from "../state.js";
import { formatBytes, openModal } from "../ui.js";

let activeTab = "devices";
const linkLabel = (type) => type === "p2p" ? "P2P" : type === "tcp" ? "TCP" : "Relay";
const trafficFor = (ip) => state.traffic.find((item) => item.virtual_ip === ip) || {};

function deviceCard(peer) {
  const traffic = trafficFor(peer.virtual_ip);
  const label = peer.name?.trim() || `设备 ${peer.virtual_ip}`;
  return `<button class="device-card" data-peer="${escapeHtml(peer.virtual_ip)}"><span class="device-avatar">${escapeHtml(label.slice(0, 1).toUpperCase())}</span><span class="device-copy"><strong>${escapeHtml(label)}</strong><small class="mono">${escapeHtml(peer.virtual_ip)}</small></span><span class="device-stats"><span class="badge ${peer.online ? "success" : ""}">${peer.online ? "在线" : "离线"}</span><span class="badge ${peer.link_type === "p2p" ? "success" : "info"}">${linkLabel(peer.link_type)}</span><small>${peer.rtt_ms == null ? "—" : `${peer.rtt_ms} ms`} · ↑${formatBytes(traffic.tx_bytes)} ↓${formatBytes(traffic.rx_bytes)}</small></span><b>›</b></button>`;
}

function renderDevices() {
  const online = state.peers.filter((peer) => peer.online);
  const offline = state.peers.filter((peer) => !peer.online);
  const status = state.status || {};
  const config = state.config || {};
  const protocol = (status.connected_server || config.server_addresses?.[0] || "").split("://")[0].toUpperCase() || "—";
  return `<article class="panel current-device"><div class="panel-header"><div><span class="badge info">当前设备</span><h3>${escapeHtml(config.device_name || "Linux 设备")}</h3><p class="mono">${escapeHtml(status.virtual_ip || "尚未分配虚拟 IP")}</p></div><span class="device-avatar self">${escapeHtml((config.device_name || "L").slice(0, 1).toUpperCase())}</span></div><dl class="current-device-grid"><div><dt>运行状态</dt><dd>${status.phase === "running" ? '<span class="badge success">在线</span>' : '<span class="badge">离线</span>'}</dd></div><div><dt>服务端链路</dt><dd><span class="badge info">${escapeHtml(protocol)}</span></dd></div><div><dt>NAT</dt><dd>${escapeHtml(status.nat_type || "—")}</dd></div><div><dt>有效路由</dt><dd>${Number(status.route_peer_count || 0)}</dd></div></dl></article>
    <section class="device-group"><div class="group-title"><h3>在线设备</h3><span>${online.length}</span></div>${online.length ? `<div class="device-list">${online.map(deviceCard).join("")}</div>` : '<div class="panel empty-state"><span>⌁</span><strong>暂无在线设备</strong><p>其他设备加入同一网络后会显示在这里。</p></div>'}</section>
    ${offline.length ? `<section class="device-group"><div class="group-title"><h3>离线设备</h3><span>${offline.length}</span></div><div class="device-list">${offline.map(deviceCard).join("")}</div></section>` : ""}`;
}

function renderRoutes() {
  const routes = state.routes || [];
  if (!routes.length) return '<article class="panel empty-state"><span>⌁</span><strong>暂无有效路由</strong><p>建立设备连接后会显示 P2P 与中继路由质量。</p></article>';
  return `<section class="route-summary metric-grid"><article class="metric-card"><span>路由总数</span><strong>${routes.length}</strong><small>当前采样</small></article><article class="metric-card"><span>P2P 路由</span><strong>${routes.filter((item) => item.link_type === "p2p").length}</strong><small>点对点直连</small></article><article class="metric-card"><span>中继路由</span><strong>${routes.filter((item) => item.link_type !== "p2p").length}</strong><small>服务器转发</small></article><article class="metric-card"><span>最低延迟</span><strong>${Math.min(...routes.map((item) => item.rtt_ms))} ms</strong><small>最佳有效路径</small></article></section><article class="panel route-table-panel"><div class="table-scroll"><table class="data-table"><thead><tr><th>目标设备</th><th>链路</th><th>Metric</th><th>延迟</th><th>丢包率</th><th>评分</th></tr></thead><tbody>${routes.map((route) => `<tr><td class="mono">${escapeHtml(route.virtual_ip)}</td><td><span class="badge ${route.link_type === "p2p" ? "success" : "info"}">${linkLabel(route.link_type)}</span></td><td>${route.metric}</td><td>${route.rtt_ms} ms</td><td>${Number(route.loss_rate || 0).toFixed(2)}%</td><td>${route.score}</td></tr>`).join("")}</tbody></table></div></article>`;
}

function showPeer(ip) {
  const peer = state.peers.find((item) => item.virtual_ip === ip);
  if (!peer) return;
  const traffic = trafficFor(ip);
  const routes = state.routes.filter((item) => item.virtual_ip === ip);
  const label = peer.name?.trim() || `设备 ${ip}`;
  openModal(`<article class="modal"><header class="modal-header"><div><h3>${escapeHtml(label)}</h3><p class="mono">${escapeHtml(ip)}</p></div><button class="icon-button" data-close-modal aria-label="关闭">×</button></header><div class="modal-body"><dl class="detail-grid"><div><dt>在线状态</dt><dd>${peer.online ? "在线" : "离线"}</dd></div><div><dt>首选链路</dt><dd>${linkLabel(peer.link_type)}</dd></div><div><dt>往返延迟</dt><dd>${peer.rtt_ms == null ? "—" : `${peer.rtt_ms} ms`}</dd></div><div><dt>有效路由</dt><dd>${routes.length}</dd></div><div><dt>累计上传</dt><dd>${formatBytes(traffic.tx_bytes)}</dd></div><div><dt>累计下载</dt><dd>${formatBytes(traffic.rx_bytes)}</dd></div></dl></div><footer class="modal-footer"><button class="button outline" data-close-modal>关闭</button></footer></article>`);
}

export async function renderLinkStatus(root) {
  root.innerHTML = `<section class="section-header"><div><h2>网络成员</h2><p>设备和路由数据每 5 秒自动刷新</p></div><div class="tabs"><button class="tab ${activeTab === "devices" ? "active" : ""}" data-tab="devices">设备 ${state.peers.length}</button><button class="tab ${activeTab === "routes" ? "active" : ""}" data-tab="routes">路由 ${state.routes.length}</button></div></section><div id="linkStatusContent">${activeTab === "devices" ? renderDevices() : renderRoutes()}</div>`;
  root.querySelectorAll("[data-tab]").forEach((button) => button.addEventListener("click", () => { activeTab = button.dataset.tab; renderLinkStatus(root); }));
  root.querySelectorAll("[data-peer]").forEach((button) => button.addEventListener("click", () => showPeer(button.dataset.peer)));
}

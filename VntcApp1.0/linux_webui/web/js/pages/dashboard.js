import { post } from "../api.js";
import { state, escapeHtml } from "../state.js";
import { formatBytes, phaseLabel, toast } from "../ui.js";

const average = (values) => values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : null;

function sparkline(history, key) {
  const values = history.map((item) => item[key]);
  const max = Math.max(...values, 1);
  const points = values.map((value, index) => `${(index / Math.max(values.length - 1, 1)) * 100},${34 - (value / max) * 30}`).join(" ");
  return points || "0,34 100,34";
}

function diagnostic(status) {
  if (status.phase === "error") return status.error || "连接失败，请检查配置和运行日志。";
  if (status.phase === "starting") return "正在连接服务器、注册虚拟地址并探测 NAT。";
  if (status.phase === "stopped") return "网络当前已断开，可选择默认配置后启动连接。";
  if (status.nat_state !== "ready") return "网络已注册，正在补充公网地址与 NAT 类型。";
  if (!status.online_peer_count) return "网络已就绪，正在等待同一网络中的其他设备。";
  if (status.direct_peer_count) return `已有 ${status.direct_peer_count} 个设备通过 P2P 直连。`;
  return "设备当前使用服务器中继，后台仍会继续尝试 P2P 打洞。";
}

export async function renderDashboard(root) {
  const status = state.status || { phase: "stopped", public_ips: [] };
  const config = state.config || {};
  const traffic = state.trafficTotals;
  const routes = state.routes || [];
  const latencies = routes.map((item) => Number(item.rtt_ms)).filter(Number.isFinite);
  const losses = routes.map((item) => Number(item.loss_rate)).filter(Number.isFinite);
  const latency = average(latencies);
  const loss = average(losses);
  const direct = Number(status.direct_peer_count || 0);
  const online = Number(status.online_peer_count || 0);
  const directRate = online ? Math.round((direct / online) * 100) : 0;
  const running = status.phase === "running" || status.phase === "starting";
  root.innerHTML = `
    <section class="section-header"><div><h2>你好，${escapeHtml(config.device_name || "Linux 设备")}</h2><p>${diagnostic(status)}</p></div><div class="actions"><button class="button outline" data-jump="configs">管理配置</button><button class="button ${running ? "danger" : "primary"}" id="connectionButton">${running ? "断开连接" : "启动连接"}</button></div></section>
    <section class="dashboard-hero">
      <article class="panel connection-overview"><div class="panel-header"><div><span class="badge ${running ? "success" : ""}">${phaseLabel(status.phase)}</span><h3>虚拟网络</h3></div><span class="network-orb ${running ? "active" : ""}">⌁</span></div><strong class="virtual-ip">${escapeHtml(status.virtual_ip || "—")}</strong><p>${escapeHtml(status.virtual_network || "尚未分配虚拟网络")}</p><dl class="compact-details"><div><dt>设备名称</dt><dd>${escapeHtml(config.device_name || "—")}</dd></div><div><dt>服务器</dt><dd>${escapeHtml(status.connected_server || config.server_addresses?.[0] || "—")}</dd></div><div><dt>协议</dt><dd>${escapeHtml((status.connected_server || config.server_addresses?.[0] || "—").split("://")[0].toUpperCase())}</dd></div></dl></article>
      <article class="panel traffic-panel"><div class="panel-header"><div><h3>实时流量</h3><p>最近 24 个刷新采样</p></div><span class="badge info">实时</span></div><div class="rate-grid"><div><span>↑ 上传</span><strong>${formatBytes(traffic.txRate, "/s")}</strong></div><div><span>↓ 下载</span><strong>${formatBytes(traffic.rxRate, "/s")}</strong></div></div><svg class="traffic-chart" viewBox="0 0 100 36" preserveAspectRatio="none" aria-label="上传下载速率趋势"><polyline class="tx-line" points="${sparkline(state.trafficHistory, "txRate")}"></polyline><polyline class="rx-line" points="${sparkline(state.trafficHistory, "rxRate")}"></polyline></svg><div class="total-row"><span>累计上传 ${formatBytes(traffic.tx)}</span><span>累计下载 ${formatBytes(traffic.rx)}</span></div></article>
    </section>
    <section class="metric-grid dashboard-metrics">
      <article class="metric-card"><span>平均延迟</span><strong>${latency == null ? "—" : `${Math.round(latency)} ms`}</strong><small>${latencies.length ? `${latencies.length} 条有效路由` : "等待链路数据"}</small></article>
      <article class="metric-card"><span>平均丢包</span><strong>${loss == null ? "—" : `${loss.toFixed(2)}%`}</strong><small>${loss != null && loss < 1 ? "链路质量良好" : "持续观察链路"}</small></article>
      <article class="metric-card"><span>NAT 类型</span><strong>${escapeHtml(status.nat_type || (status.nat_state === "discovering" ? "探测中" : "—"))}</strong><small>${escapeHtml(status.public_ips?.[0] || "暂无公网地址")}</small></article>
      <article class="metric-card"><span>P2P 直连率</span><strong>${directRate}%</strong><small>${direct} / ${online} 个在线设备直连</small></article>
    </section>
    <section class="dashboard-lower">
      <article class="panel"><div class="panel-header"><div><h3>网络信息</h3><p>当前运行实例</p></div></div><dl class="info-list"><div><dt>虚拟 IP</dt><dd class="mono">${escapeHtml(status.virtual_ip || "—")}</dd></div><div><dt>公网地址</dt><dd class="mono">${escapeHtml(status.public_ips?.join(", ") || "—")}</dd></div><div><dt>在线设备</dt><dd>${online}</dd></div><div><dt>有效路由</dt><dd>${Number(status.route_peer_count || 0)}</dd></div></dl></article>
      <article class="panel quick-panel"><div class="panel-header"><div><h3>快捷操作</h3><p>常用管理入口</p></div></div><button class="quick-link" data-jump="configs"><span>▤</span><span><strong>配置管理</strong><small>新增、编辑或切换网络配置</small></span><b>›</b></button><button class="quick-link" data-jump="settings"><span>⚙</span><span><strong>WebUI 设置</strong><small>主题、刷新、备份与日志</small></span><b>›</b></button></article>
    </section>`;

  root.querySelectorAll("[data-jump]").forEach((button) => button.addEventListener("click", () => { location.hash = button.dataset.jump; }));
  root.querySelector("#connectionButton").addEventListener("click", async (event) => {
    event.currentTarget.disabled = true;
    try { await post(running ? "/stop" : "/start"); toast(running ? "网络已断开" : "网络正在启动"); }
    catch (error) { toast(error.message, "error"); }
    finally { event.currentTarget.disabled = false; document.dispatchEvent(new CustomEvent("vntc:refresh")); }
  });
}

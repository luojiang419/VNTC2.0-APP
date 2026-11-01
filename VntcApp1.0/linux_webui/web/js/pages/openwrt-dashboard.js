import { post } from "../api.js";
import { state } from "../state.js";
import { formatBytes, phaseLabel, toast } from "../ui.js";

function text(root, id, value) {
  const element = root.querySelector(`#${id}`);
  const next = String(value ?? "—");
  if (element.textContent !== next) element.textContent = next;
}

export async function renderDashboard(root) {
  if (!root.querySelector("#openwrtDashboard")) {
    root.innerHTML = `<div id="openwrtDashboard">
      <section class="section-header"><div><h2 id="routerName">OpenWrt</h2><p id="connectionNote">虚拟组网</p></div><button class="button primary" id="connectionButton">启动连接</button></section>
      <section class="dashboard-hero">
        <article class="panel"><div class="panel-header"><h3>虚拟网络</h3><span class="badge" id="networkPhase">已停止</span></div><strong class="virtual-ip" id="virtualIp">—</strong><p class="subtle" id="virtualNetwork">—</p><dl class="info-list"><div><dt>服务器</dt><dd id="serverAddress" class="mono">—</dd></div><div><dt>网卡 / MTU</dt><dd id="tunMtu">—</dd></div></dl></article>
        <article class="panel"><div class="panel-header"><h3>流量</h3><span class="subtle">当前采样</span></div><div class="rate-grid"><div><span>↑ 上传</span><strong id="txRate">—</strong></div><div><span>↓ 下载</span><strong id="rxRate">—</strong></div></div><dl class="info-list"><div><dt>累计上传</dt><dd id="txTotal">—</dd></div><div><dt>累计下载</dt><dd id="rxTotal">—</dd></div></dl></article>
      </section>
      <section class="metric-grid"><article class="metric-card"><span>在线设备</span><strong id="onlineCount">0</strong></article><article class="metric-card"><span>P2P 直连</span><strong id="directCount">0</strong></article><article class="metric-card"><span>中继连接</span><strong id="relayCount">0</strong></article><article class="metric-card"><span>NAT 类型</span><strong id="natType">—</strong></article></section>
    </div>`;
    const button = root.querySelector("#connectionButton");
    button.addEventListener("click", async () => {
      button.disabled = true;
      const active = ["running", "starting"].includes(state.status?.phase);
      try { await post(active ? "/stop" : "/start"); toast(active ? "网络已断开" : "正在连接"); }
      catch (error) { toast(error.message, "error"); }
      finally { button.disabled = false; document.dispatchEvent(new CustomEvent("vntc:refresh")); }
    });
  }
  const status = state.status || { phase: "stopped" };
  const config = state.config || {};
  const traffic = state.trafficTotals;
  const active = ["running", "starting"].includes(status.phase);
  text(root, "routerName", config.device_name || "OpenWrt");
  text(root, "connectionNote", status.error || (status.phase === "running" ? "虚拟网络已连接" : status.phase === "starting" ? "正在连接服务器…" : "选择配置后即可连接虚拟网络"));
  text(root, "networkPhase", phaseLabel(status.phase));
  root.querySelector("#networkPhase").className = `badge ${status.phase === "running" ? "success" : ""}`;
  text(root, "connectionButton", active ? "断开连接" : "启动连接");
  root.querySelector("#connectionButton").className = `button ${active ? "danger" : "primary"}`;
  text(root, "virtualIp", status.virtual_ip || "未连接");
  text(root, "virtualNetwork", status.virtual_network || "尚未分配虚拟网络");
  text(root, "serverAddress", status.connected_server || config.server_addresses?.[0]);
  text(root, "tunMtu", `${config.tun_name || "vnt0"} / ${config.mtu || 1400}`);
  text(root, "txRate", formatBytes(traffic.txRate, "/s"));
  text(root, "rxRate", formatBytes(traffic.rxRate, "/s"));
  text(root, "txTotal", formatBytes(traffic.tx));
  text(root, "rxTotal", formatBytes(traffic.rx));
  text(root, "onlineCount", status.online_peer_count || 0);
  text(root, "directCount", status.direct_peer_count || 0);
  text(root, "relayCount", status.relay_peer_count || 0);
  text(root, "natType", status.nat_type || "—");
}

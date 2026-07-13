import { get, post, put, remove } from "../api.js";
import { state, escapeHtml, joinLines, splitLines } from "../state.js";
import { closeModal, downloadJson, openModal, toast } from "../ui.js";

const emptyVnt = () => ({
  server_addresses: ["quic://"], network_code: "", device_id: null, device_name: "vntc-linux", tun_name: "vnt0", virtual_ip: null, password: null,
  channel_mode: "all", mtu: 1400, compress: false, rtx: false, fec: false, no_tun: false, no_nat: false, allow_port_mapping: false,
  udp_stun: [], tcp_stun: [], tunnel_port: null, input_routes: [], output_routes: [], port_mappings: [],
});

function profileCard(profile) {
  const isDefault = profile.id === state.profileMeta.defaultId;
  const isActive = profile.id === state.profileMeta.activeId;
  const running = isActive && ["running", "starting"].includes(state.status?.phase);
  return `<article class="profile-card panel" data-profile-id="${escapeHtml(profile.id)}"><div class="profile-main"><span class="profile-icon">▤</span><div><div class="profile-title"><h3>${escapeHtml(profile.name)}</h3>${isDefault ? '<span class="badge info">默认</span>' : ""}${isActive ? `<span class="badge ${running ? "success" : "warning"}">${running ? "已连接" : "已选择"}</span>` : ""}</div><p>${escapeHtml(profile.vnt.device_name)} · ${escapeHtml(profile.vnt.network_code)}</p><div class="profile-meta"><span class="mono">${escapeHtml(profile.vnt.server_addresses?.[0] || "未设置服务器")}</span><span>${profile.vnt.channel_mode === "relay_only" ? "仅中继" : "P2P 优先"}</span><span>MTU ${profile.vnt.mtu}</span></div></div></div><div class="profile-actions"><button class="button ${running ? "danger" : "primary"}" data-action="${running ? "disconnect" : "connect"}">${running ? "断开" : "连接"}</button><button class="button outline" data-action="edit">编辑</button><button class="icon-button" data-action="more" aria-label="更多操作">⋯</button></div><div class="profile-menu" hidden><button data-action="copy">复制配置</button>${isDefault ? "" : '<button data-action="default">设为默认</button>'}<button class="danger-text" data-action="delete">删除配置</button></div></article>`;
}

function toggleField(id, title, description, checked) {
  return `<label class="toggle"><span class="toggle-copy"><strong>${title}</strong><small>${description}</small></span><span class="switch"><input id="${id}" type="checkbox" ${checked ? "checked" : ""}><i></i></span></label>`;
}

function editor(profile) {
  const value = profile?.vnt || emptyVnt();
  return `<form class="modal profile-editor" id="profileEditor"><header class="modal-header"><div><h3>${profile ? "编辑配置" : "添加配置"}</h3><p>基础连接与 Linux VNT 高级参数</p></div><button class="icon-button" type="button" data-close-modal aria-label="关闭">×</button></header><div class="modal-body"><div class="form-grid"><label class="field wide"><span>配置名称 *</span><input id="profileName" maxlength="64" required value="${escapeHtml(profile?.name || "新配置")}"></label><label class="field wide"><span>服务器地址 *</span><textarea id="serverAddresses" required rows="3">${escapeHtml(joinLines(value.server_addresses))}</textarea><small>每行一个，支持 quic://、tcp://、wss:// 和 dynamic://</small></label><label class="field"><span>网络代码 *</span><input id="networkCode" maxlength="32" required value="${escapeHtml(value.network_code)}"></label><label class="field"><span>设备名称 *</span><input id="deviceName" maxlength="128" required value="${escapeHtml(value.device_name)}"></label><label class="field"><span>虚拟网卡 *</span><input id="tunName" required value="${escapeHtml(value.tun_name)}"></label><label class="field"><span>指定虚拟 IP</span><input id="virtualIpInput" value="${escapeHtml(value.virtual_ip || "")}" placeholder="自动分配"></label><label class="field"><span>网络密码</span><input id="networkPassword" type="password" value="${escapeHtml(value.password || "")}" autocomplete="new-password"></label><label class="field"><span>链路模式</span><select id="channelMode"><option value="all" ${value.channel_mode !== "relay_only" ? "selected" : ""}>P2P 优先，允许中继</option><option value="relay_only" ${value.channel_mode === "relay_only" ? "selected" : ""}>仅中继</option></select></label><label class="field"><span>MTU</span><input id="mtu" type="number" min="576" max="1500" required value="${value.mtu || 1400}"></label><label class="field"><span>设备 ID</span><input id="deviceId" maxlength="64" value="${escapeHtml(value.device_id || "")}" placeholder="自动生成"></label></div><details class="editor-details"><summary>传输与打洞设置</summary><div class="toggle-settings">${toggleField("compress", "数据压缩", "降低低带宽链路流量", value.compress)}${toggleField("rtx", "可靠传输 RTX", "改善不稳定链路", value.rtx)}${toggleField("fec", "前向纠错 FEC", "降低丢包影响", value.fec)}${toggleField("noNat", "禁用内置 NAT", "仅使用虚拟网卡转发", value.no_nat)}${toggleField("noTun", "无 TUN 模式", "用于纯端口映射场景", value.no_tun)}${toggleField("allowPortMapping", "允许端口映射", "开放配置的 TCP/UDP 映射", value.allow_port_mapping)}</div><div class="form-grid"><label class="field"><span>UDP STUN</span><textarea id="udpStun" rows="3">${escapeHtml(joinLines(value.udp_stun))}</textarea></label><label class="field"><span>TCP STUN</span><textarea id="tcpStun" rows="3">${escapeHtml(joinLines(value.tcp_stun))}</textarea></label></div></details><details class="editor-details"><summary>高级路由与映射</summary><div class="form-grid"><label class="field"><span>输入路由</span><textarea id="inputRoutes" rows="4" placeholder="192.168.1.0/24=10.26.0.2">${escapeHtml(joinLines(value.input_routes))}</textarea></label><label class="field"><span>输出路由</span><textarea id="outputRoutes" rows="4" placeholder="192.168.2.0/24">${escapeHtml(joinLines(value.output_routes))}</textarea></label><label class="field wide"><span>端口映射</span><textarea id="portMappings" rows="3">${escapeHtml(joinLines(value.port_mappings))}</textarea></label><label class="field"><span>固定打洞端口</span><input id="tunnelPort" type="number" min="1" max="65535" value="${value.tunnel_port || ""}" placeholder="自动"></label></div></details></div><footer class="modal-footer"><button class="button outline" type="button" data-close-modal>取消</button><button class="button primary" type="submit">保存配置</button></footer></form>`;
}

function collectProfile(form) {
  const byId = (id) => form.querySelector(`#${id}`);
  return { name: byId("profileName").value.trim(), vnt: {
    server_addresses: splitLines(byId("serverAddresses").value), network_code: byId("networkCode").value.trim(), device_id: byId("deviceId").value.trim() || null,
    device_name: byId("deviceName").value.trim(), tun_name: byId("tunName").value.trim(), virtual_ip: byId("virtualIpInput").value.trim() || null,
    password: byId("networkPassword").value || null, channel_mode: byId("channelMode").value, mtu: Number(byId("mtu").value), compress: byId("compress").checked,
    rtx: byId("rtx").checked, fec: byId("fec").checked, no_tun: byId("noTun").checked, no_nat: byId("noNat").checked,
    allow_port_mapping: byId("allowPortMapping").checked, udp_stun: splitLines(byId("udpStun").value), tcp_stun: splitLines(byId("tcpStun").value),
    tunnel_port: byId("tunnelPort").value ? Number(byId("tunnelPort").value) : null, input_routes: splitLines(byId("inputRoutes").value),
    output_routes: splitLines(byId("outputRoutes").value), port_mappings: splitLines(byId("portMappings").value),
  }};
}

async function reloadProfiles() {
  const data = await get("/profiles");
  state.profiles = data.profiles;
  state.profileMeta = { defaultId: data.default_profile_id, activeId: data.active_profile_id };
  state.config = await get("/config");
}

function openEditor(root, profile = null) {
  openModal(editor(profile));
  const form = document.querySelector("#profileEditor");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!form.reportValidity()) return;
    const submit = form.querySelector('[type="submit"]'); submit.disabled = true;
    try { profile ? await put(`/profiles/${encodeURIComponent(profile.id)}`, collectProfile(form)) : await post("/profiles", collectProfile(form)); await reloadProfiles(); closeModal(); toast("配置已保存"); renderConfigs(root); }
    catch (error) { toast(error.message, "error"); }
    finally { submit.disabled = false; }
  });
}

async function handleAction(root, profile, action) {
  try {
    if (action === "edit") return openEditor(root, profile);
    if (action === "more") { const menu = root.querySelector(`[data-profile-id="${profile.id}"] .profile-menu`); menu.hidden = !menu.hidden; return; }
    if (action === "delete" && !confirm(`确定删除配置“${profile.name}”吗？`)) return;
    if (action === "connect") await post(`/profiles/${encodeURIComponent(profile.id)}/connect`);
    if (action === "disconnect") await post("/stop");
    if (action === "copy") await post(`/profiles/${encodeURIComponent(profile.id)}/copy`);
    if (action === "default") await post(`/profiles/${encodeURIComponent(profile.id)}/default`);
    if (action === "delete") await remove(`/profiles/${encodeURIComponent(profile.id)}`);
    await reloadProfiles();
    toast({ connect: "配置已连接", disconnect: "网络已断开", copy: "配置已复制", default: "默认配置已更新", delete: "配置已删除" }[action]);
    document.dispatchEvent(new CustomEvent("vntc:refresh"));
    renderConfigs(root);
  } catch (error) { toast(error.message, "error"); }
}

async function importFile(root, file) {
  try {
    const backup = JSON.parse(await file.text());
    await post("/profiles/import", { mode: "merge", backup });
    await reloadProfiles();
    toast("配置已导入");
    renderConfigs(root);
  } catch (error) { toast(error.message || "导入文件无效", "error"); }
}

export async function renderConfigs(root) {
  if (!state.profiles.length) await reloadProfiles();
  root.innerHTML = `<section class="section-header"><div><h2>网络配置</h2><p>保存不同网络环境，一键切换连接</p></div><div class="actions"><input id="profileImport" type="file" accept="application/json,.json" hidden><button class="button outline" id="importProfiles">导入</button><button class="button outline" id="exportProfiles">导出</button><button class="button primary" id="addProfile">添加配置</button></div></section><section class="profile-list">${state.profiles.map(profileCard).join("")}</section>`;
  root.querySelector("#addProfile").addEventListener("click", () => openEditor(root));
  root.querySelector("#importProfiles").addEventListener("click", () => root.querySelector("#profileImport").click());
  root.querySelector("#profileImport").addEventListener("change", (event) => event.target.files[0] && importFile(root, event.target.files[0]));
  root.querySelector("#exportProfiles").addEventListener("click", async () => { try { downloadJson(`vntc-profiles-${new Date().toISOString().slice(0, 10)}.json`, await get("/profiles/export")); } catch (error) { toast(error.message, "error"); } });
  root.querySelectorAll("[data-profile-id]").forEach((card) => card.addEventListener("click", (event) => { const button = event.target.closest("[data-action]"); if (!button) return; const profile = state.profiles.find((item) => item.id === card.dataset.profileId); if (profile) handleAction(root, profile, button.dataset.action); }));
}

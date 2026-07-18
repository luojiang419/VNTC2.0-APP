import { get, post, put, remove } from "../api.js";
import { state, escapeHtml, setToken } from "../state.js";
import { downloadJson, downloadText, toast } from "../ui.js";

const themeNames = { light: "亮色", dark: "暗色", system: "跟随系统" };
const accentNames = { blue: "蓝色", green: "绿色", purple: "紫色", orange: "橙色" };

async function saveSettings(root, patch) {
  const candidate = { ...state.settings, ...patch };
  try {
    await put("/settings", candidate);
    state.settings = candidate;
    localStorage.setItem("vntcThemeMode", candidate.theme_mode);
    localStorage.setItem("vntcThemeAccent", candidate.theme_accent);
    document.dispatchEvent(new CustomEvent("vntc:settings"));
    toast("设置已保存");
    renderSettings(root);
  } catch (error) { toast(error.message, "error"); }
}

const formatLogTime = (timestamp) => new Date(Number(timestamp) * 1000).toLocaleString("zh-CN", { hour12: false });

async function restoreBackup(root, file) {
  try {
    await post("/backup/restore", JSON.parse(await file.text()));
    localStorage.removeItem("vntcThemeMode");
    localStorage.removeItem("vntcThemeAccent");
    state.settings = await get("/settings");
    document.dispatchEvent(new CustomEvent("vntc:refresh"));
    toast("备份已恢复");
    renderSettings(root);
  } catch (error) { toast(error.message || "备份文件无效", "error"); }
}

export async function renderSettings(root) {
  const [settings, logs] = await Promise.all([state.settings ? Promise.resolve(state.settings) : get("/settings"), get("/logs")]);
  state.settings = settings;
  root.innerHTML = `<section class="settings-layout"><div class="settings-main"><article class="panel settings-section"><div class="panel-header"><div><h3>体验模式</h3><p>极简模式聚焦连接与状态，专业模式展示完整管理导航</p></div></div><div class="mode-options"><button class="mode-option ${settings.experience_mode !== "professional" ? "active" : ""}" data-experience-mode="minimal"><strong>极简模式</strong><small>保留仪表盘、添加配置、模式切换与设置入口</small></button><button class="mode-option ${settings.experience_mode === "professional" ? "active" : ""}" data-experience-mode="professional"><strong>专业模式</strong><small>展示链接状态、配置、设置和关于等完整导航</small></button></div></article><article class="panel settings-section"><div class="panel-header"><div><h3>外观</h3><p>主题会同步到 WebUI，并保存在当前浏览器</p></div></div><div class="theme-options">${Object.entries(themeNames).map(([value, label]) => `<button class="theme-option ${settings.theme_mode === value ? "active" : ""}" data-theme-mode="${value}"><span class="theme-preview ${value}"><i></i><b></b></span><strong>${label}</strong></button>`).join("")}</div><div class="accent-row"><span>主题色</span><div>${Object.entries(accentNames).map(([value, label]) => `<button class="accent-dot ${settings.theme_accent === value ? "active" : ""}" data-accent="${value}" title="${label}" aria-label="${label}"></button>`).join("")}</div></div></article>
    <article class="panel settings-section"><div class="panel-header"><div><h3>连接与刷新</h3><p>容器启动后的网络行为</p></div></div><div class="setting-row"><span class="toggle-copy"><strong>自动连接默认配置</strong><small>Linux 服务启动后连接当前默认配置</small></span><label class="switch"><input id="autoConnect" type="checkbox" ${settings.auto_connect ? "checked" : ""}><i></i></label></div><div class="setting-row"><span class="toggle-copy"><strong>自动刷新间隔</strong><small>状态、设备、路由和流量的轮询频率</small></span><select id="refreshInterval"><option value="2">2 秒</option><option value="5">5 秒</option><option value="10">10 秒</option><option value="30">30 秒</option><option value="60">60 秒</option></select></div><div class="setting-note"><strong>开机自启</strong><p>Docker 部署请使用 Compose 的 <code>restart: unless-stopped</code>；原生 Linux 部署请启用随包提供的 systemd 服务。容器不会直接修改宿主机启动策略。</p></div></article>
    <article class="panel settings-section"><div class="panel-header"><div><h3>访问密码</h3><p>自定义 WebUI 登录密码，保存后立即生效并持久化到服务器配置</p></div><span class="badge warning">不会显示当前密码</span></div><form id="accessPasswordForm" class="password-form"><div class="form-grid"><label class="field"><span>新密码 *</span><input id="newAccessPassword" type="password" required autocomplete="new-password" placeholder="输入新的访问密码"></label><label class="field"><span>确认新密码 *</span><input id="confirmAccessPassword" type="password" required autocomplete="new-password" placeholder="再次输入新密码"></label></div><div class="password-footer"><p>修改请求使用当前登录身份验证；密码不会出现在设置读取接口或完整备份中。</p><button class="button primary" type="submit">保存访问密码</button></div></form></article>
    <article class="panel settings-section"><div class="panel-header"><div><h3>备份与数据</h3><p>备份包括全部配置档案、默认项和 WebUI 设置，不包含访问令牌</p></div></div><div class="data-actions"><button class="button outline" id="exportBackup">备份全部配置</button><input id="restoreFile" type="file" accept="application/json,.json" hidden><button class="button outline" id="restoreBackup">恢复备份</button><button class="button danger" id="clearData">重置 WebUI 数据</button></div></article></div>
    <aside class="settings-side"><article class="panel log-panel"><div class="panel-header"><div><h3>运行日志</h3><p>最近 ${logs.length} 条控制面事件</p></div><div class="inline-actions"><button class="icon-button" id="downloadLogs" title="下载日志">⇩</button><button class="icon-button" id="clearLogs" title="清空日志">×</button></div></div><div class="log-list">${logs.length ? logs.slice().reverse().map((entry) => `<div class="log-entry"><span class="badge ${entry.level === "error" ? "danger" : entry.level === "warn" ? "warning" : "info"}">${escapeHtml(entry.level)}</span><p>${escapeHtml(entry.message)}</p><time>${formatLogTime(entry.timestamp_unix)}</time></div>`).join("") : '<div class="empty-state"><span>≡</span><strong>暂无运行日志</strong><p>连接与配置操作会记录在这里。</p></div>'}</div></article><article class="panel setting-note update-note"><strong>软件更新</strong><p>容器不能自我替换。请拉取新版镜像并重新创建容器，或加载新版离线包后执行 <code>docker compose up -d</code>。</p><a href="#about">查看部署说明</a></article></aside></section>`;
  root.querySelector("#refreshInterval").value = String(settings.refresh_interval_seconds);
  root.querySelectorAll("[data-experience-mode]").forEach((button) => button.addEventListener("click", () => {
    const mode = button.dataset.experienceMode;
    if (mode === settings.experience_mode) return;
    if (mode === "professional" && !confirm("除非你知道自己在做什么，否则最纯粹的虚拟组网体验更适合你。是否进入专业模式？")) return;
    saveSettings(root, { experience_mode: mode });
  }));
  root.querySelectorAll("[data-theme-mode]").forEach((button) => button.addEventListener("click", () => saveSettings(root, { theme_mode: button.dataset.themeMode })));
  root.querySelectorAll("[data-accent]").forEach((button) => button.addEventListener("click", () => saveSettings(root, { theme_accent: button.dataset.accent })));
  root.querySelector("#autoConnect").addEventListener("change", (event) => saveSettings(root, { auto_connect: event.target.checked }));
  root.querySelector("#refreshInterval").addEventListener("change", (event) => saveSettings(root, { refresh_interval_seconds: Number(event.target.value) }));
  root.querySelector("#accessPasswordForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const password = root.querySelector("#newAccessPassword").value.trim();
    const confirmation = root.querySelector("#confirmAccessPassword").value.trim();
    if (!password) { toast("访问密码不能为空", "error"); return; }
    if (password !== confirmation) { toast("两次输入的密码不一致", "error"); return; }
    const submit = event.currentTarget.querySelector('[type="submit"]');
    submit.disabled = true;
    try {
      await put("/settings/access-token", { access_token: password });
      setToken(password);
      event.currentTarget.reset();
      toast("访问密码已更新并持久化");
    } catch (error) { toast(error.message, "error"); }
    finally { submit.disabled = false; }
  });
  root.querySelector("#exportBackup").addEventListener("click", async () => { try { downloadJson(`vntc-linux-backup-${new Date().toISOString().slice(0, 10)}.json`, await get("/backup")); } catch (error) { toast(error.message, "error"); } });
  root.querySelector("#restoreBackup").addEventListener("click", () => root.querySelector("#restoreFile").click());
  root.querySelector("#restoreFile").addEventListener("change", (event) => event.target.files[0] && restoreBackup(root, event.target.files[0]));
  root.querySelector("#clearData").addEventListener("click", async () => { if (!confirm("确定重置配置档案和 WebUI 设置吗？当前网络参数会保留为唯一默认配置。")) return; try { await post("/data/clear"); state.settings = await get("/settings"); toast("WebUI 数据已重置"); document.dispatchEvent(new CustomEvent("vntc:refresh")); renderSettings(root); } catch (error) { toast(error.message, "error"); } });
  root.querySelector("#downloadLogs").addEventListener("click", async () => { try { downloadText("VNTC-Linux-WebUI.log", await get("/logs/download")); } catch (error) { toast(error.message, "error"); } });
  root.querySelector("#clearLogs").addEventListener("click", async () => { try { await remove("/logs"); toast("日志已清空"); renderSettings(root); } catch (error) { toast(error.message, "error"); } });
}

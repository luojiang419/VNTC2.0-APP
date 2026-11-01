import { get } from "../api.js";
import { escapeHtml } from "../state.js";

export async function renderAbout(root) {
  const about = await get("/about");
  const openwrt = about.platform.startsWith("openwrt/");
  const platform = openwrt ? "OpenWrt" : "Linux";
  const deployment = openwrt
    ? `<div class="guide-step"><b>1</b><div><strong>安装与升级</strong><p>安装对应 x86_64 IPK，或执行离线包内的 <code>sh install.sh</code>。升级保留现有组网配置。</p></div></div><div class="guide-step"><b>2</b><div><strong>启动与日志</strong><p>使用 <code>/etc/init.d/vntc restart</code> 重启服务，使用 <code>logread -e vntc</code> 查看日志。</p></div></div><div class="guide-step"><b>3</b><div><strong>开机连接</strong><p>服务由 procd 管理；在设置页面启用自动连接后，开机连接默认配置。业务配置保存在 <code>/etc/vntc/</code>。</p></div></div>`
    : `<div class="guide-step"><b>1</b><div><strong>Docker / Compose</strong><p>加载或拉取新镜像，更新 <code>VNTC_VERSION</code>，然后执行 <code>docker compose up -d</code> 重建容器。</p></div></div><div class="guide-step"><b>2</b><div><strong>离线环境</strong><p>校验发布包 SHA256，执行随包提供的 <code>load-image.sh</code>，再使用 Compose 启动。</p></div></div><div class="guide-step"><b>3</b><div><strong>原生 Linux</strong><p>替换二进制后重启 <code>vntc-linux-webui.service</code>。开机自启由 systemd 管理。</p></div></div>`;
  root.innerHTML = `<section class="about-hero panel"><span class="brand-mark large" aria-hidden="true"><i></i><i></i><i></i></span><h2>${escapeHtml(about.product)}</h2><p>安全、轻量的 ${platform} P2P 虚拟网络控制面</p><span class="version-badge">v${escapeHtml(about.version)}</span></section><section class="about-grid"><article class="panel"><div class="panel-header"><div><h3>运行信息</h3><p>当前服务构建与部署环境</p></div></div><dl class="info-list about-info"><div><dt>应用版本</dt><dd>v${escapeHtml(about.version)}</dd></div><div><dt>VNT Core</dt><dd>v${escapeHtml(about.vnt_core_version)}</dd></div><div><dt>平台</dt><dd>${escapeHtml(about.platform)}</dd></div><div><dt>运行模式</dt><dd>${escapeHtml(about.run_mode)}</dd></div><div><dt>构建模式</dt><dd>${escapeHtml(about.build_profile)}</dd></div><div><dt>构建时间</dt><dd>${escapeHtml(about.build_time)}</dd></div></dl></article><article class="panel deployment-guide"><div class="panel-header"><div><h3>部署与更新</h3><p>${openwrt ? "OpenWrt 路由器服务" : "Linux 原生服务和 Docker 使用不同方式"}</p></div></div>${deployment}<div class="security-note">访问令牌、TUN 权限和宿主启动策略只能由部署管理员配置，WebUI 不提供伪造的宿主机操作按钮。</div></article></section>`;
}

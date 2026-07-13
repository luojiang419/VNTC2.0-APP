import { state, $ } from "./state.js";

const routes = new Map();
const metadata = {
  dashboard: ["仪表盘", "网络概览"],
  "link-status": ["链接状态", "设备与路由"],
  configs: ["配置", "网络配置管理"],
  settings: ["设置", "Linux WebUI 偏好"],
  about: ["关于", "版本与部署信息"],
};

export function registerRoute(name, renderer) { routes.set(name, renderer); }

export async function navigate(route = "dashboard") {
  if (!routes.has(route)) route = "dashboard";
  state.route = route;
  document.querySelectorAll("[data-route]").forEach((item) => item.classList.toggle("active", item.dataset.route === route));
  const [title, kicker] = metadata[route];
  $("pageTitle").textContent = title;
  $("pageKicker").textContent = kicker;
  const root = $("pageRoot");
  root.classList.remove("page-enter");
  root.innerHTML = '<div class="loading-block">正在载入页面…</div>';
  try { await routes.get(route)(root); }
  catch (error) { root.innerHTML = `<div class="panel empty-state"><span>!</span><strong>页面载入失败</strong><p>${error.message}</p></div>`; }
  root.classList.add("page-enter");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

export function bindRouter() {
  const routeFromHash = () => navigate(location.hash.slice(1) || "dashboard");
  window.addEventListener("hashchange", routeFromHash);
  routeFromHash();
}

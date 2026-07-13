import { state } from "./state.js";

export class ApiError extends Error {
  constructor(message, status = 0) { super(message); this.status = status; }
}

export async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  let response;
  try { response = await fetch(`/api${path}`, { ...options, headers }); }
  catch { throw new ApiError("无法连接 Linux 控制面，请检查服务是否运行"); }
  const contentType = response.headers.get("content-type") || "";
  const data = contentType.includes("application/json") ? await response.json().catch(() => ({})) : await response.text();
  if (!response.ok) throw new ApiError(data?.message || `请求失败：HTTP ${response.status}`, response.status);
  return data;
}

export const get = (path) => api(path);
export const post = (path, body) => api(path, { method: "POST", body: body == null ? undefined : JSON.stringify(body) });
export const put = (path, body) => api(path, { method: "PUT", body: JSON.stringify(body) });
export const remove = (path) => api(path, { method: "DELETE" });

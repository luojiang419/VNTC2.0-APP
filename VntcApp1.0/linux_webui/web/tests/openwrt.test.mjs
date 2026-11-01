import assert from "node:assert/strict";
import test from "node:test";
import { boot, flush } from "./browser-fixture.mjs";

test("OpenWrt 页面刷新、后台暂停与连接操作", async (t) => {
  const env = await boot("openwrt");
  const { state } = await import("../js/state.js");
  try {
    await t.test("单次轮询只请求 snapshot，仪表盘原位更新", async () => {
      env.calls.length = 0;
      const dashboard = document.querySelector("#openwrtDashboard");
      const button = document.querySelector("#connectionButton");
      const scrolls = env.scrolls();
      env.data.status.online_peer_count = 3;
      await env.tick(10000);
      assert.deepEqual(env.calls.map((call) => call.path), ["/snapshot"]);
      assert.equal(document.querySelector("#openwrtDashboard"), dashboard);
      assert.equal(document.querySelector("#connectionButton"), button);
      assert.equal(document.querySelector("#onlineCount").textContent, "3");
      assert.equal(env.scrolls(), scrolls);
      assert.equal(document.querySelectorAll(".traffic-chart").length, 0);
      assert.equal(state.trafficHistory.length, 0);
    });
    await t.test("标签页隐藏后停止轮询，显示时恢复", async () => {
      env.setHidden(true);
      env.calls.length = 0;
      await env.tick(60000);
      assert.equal(env.calls.length, 0);
      env.setHidden(false);
      await flush();
      assert.deepEqual(env.calls.map((call) => call.path), ["/snapshot"]);
    });
    await t.test("慢响应期间不产生重叠轮询", async () => {
      env.calls.length = 0;
      const release = env.holdSnapshot();
      await env.tick(10000);
      await env.tick(60000);
      assert.equal(env.calls.filter((call) => call.path === "/snapshot").length, 1);
      release();
      await flush();
    });
    await t.test("原位刷新的连接按钮根据最新状态断开与重连", async () => {
      env.calls.length = 0;
      document.querySelector("#connectionButton").click();
      await flush();
      assert.ok(env.calls.some((call) => call.path === "/stop" && call.method === "POST"));
      assert.equal(document.querySelector("#connectionButton").textContent, "启动连接");
      document.querySelector("#connectionButton").click();
      await flush();
      assert.equal(document.querySelector("#connectionButton").textContent, "断开连接");
    });
    await t.test("成员页按需读取详情，数据不变时保留 DOM", async () => {
      const { navigate } = await import("../js/router.js");
      await navigate("link-status");
      await flush();
      env.calls.length = 0;
      const page = document.querySelector("#pageRoot").firstElementChild;
      await env.tick(10000);
      assert.deepEqual(env.calls.map((call) => call.path), ["/snapshot?details=true"]);
      assert.equal(document.querySelector("#pageRoot").firstElementChild, page);
    });
    await t.test("进入配置页暂停自动刷新，避免编辑表单被重建", async () => {
      const { navigate } = await import("../js/router.js");
      await navigate("configs");
      await flush();
      env.calls.length = 0;
      const page = document.querySelector("#pageRoot").firstElementChild;
      await env.tick(60000);
      assert.equal(env.calls.length, 0);
      assert.equal(document.querySelector("#pageRoot").firstElementChild, page);
    });
    await t.test("鉴权失败暂停轮询，重新登录后恢复", async () => {
      const { navigate } = await import("../js/router.js");
      const { setToken } = await import("../js/state.js");
      env.data.requireAuth = true;
      setToken("");
      await navigate("dashboard");
      await flush();
      assert.equal(document.querySelector("#authOverlay").hidden, false);
      env.calls.length = 0;
      await env.tick(60000);
      assert.equal(env.calls.length, 0);
      document.querySelector("#accessToken").value = "test-token";
      document.querySelector("#authForm").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
      await flush();
      assert.equal(document.querySelector("#authOverlay").hidden, true);
      env.calls.length = 0;
      await env.tick(10000);
      assert.deepEqual(env.calls.map((call) => call.path), ["/snapshot"]);
    });
  } finally { env.close(); }
});

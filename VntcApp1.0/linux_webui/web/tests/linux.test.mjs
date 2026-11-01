import assert from "node:assert/strict";
import test from "node:test";
import { boot } from "./browser-fixture.mjs";

test("Linux 版保留流量图表和原有刷新接口", async () => {
  const env = await boot("linux");
  try {
    assert.equal(document.querySelectorAll(".traffic-chart").length, 1);
    env.calls.length = 0;
    await env.tick(5000);
    assert.deepEqual(env.calls.map((call) => call.path).sort(), ["/status", "/peers", "/routes", "/traffic", "/config", "/profiles", "/settings"].sort());
    const { navigate } = await import("../js/router.js");
    await navigate("settings");
    assert.ok(document.querySelector("#refreshInterval"));
  } finally { env.close(); }
});

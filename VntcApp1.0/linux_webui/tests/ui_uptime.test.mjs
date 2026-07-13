import assert from "node:assert/strict";
import test from "node:test";

globalThis.sessionStorage = {
  getItem() { return null; },
  setItem() {},
};

const { formatUptime, projectedUptimeSeconds, statusUptimeSeconds } = await import("../web/js/ui.js");

test("运行时间使用固定中文格式并补零", () => {
  assert.equal(formatUptime(0), "00天00小时00分00秒");
  assert.equal(formatUptime(112029), "01天07小时07分09秒");
});

test("运行时间从后端采样值继续按秒递增", () => {
  assert.equal(projectedUptimeSeconds(3661, 1000, 4999), 3664);
  assert.equal(projectedUptimeSeconds(null, 1000, 4999), null);
});

test("只有真实运行状态展示运行时间", () => {
  assert.equal(statusUptimeSeconds({ phase: "running", uptime_seconds: 9 }, 1000, 2000), 10);
  for (const phase of ["starting", "stopped", "error"]) {
    assert.equal(statusUptimeSeconds({ phase, uptime_seconds: 9 }, 1000, 2000), null);
  }
});

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("Linux WebUI 提供极简和专业模式并持久化到服务端", async () => {
  const [app, dashboard, settings] = await Promise.all([
    read("../web/js/app.js"),
    read("../web/js/pages/dashboard.js"),
    read("../web/js/pages/settings.js"),
  ]);

  assert.match(app, /dataset\.experience/);
  assert.match(dashboard, /极简模式/);
  assert.match(dashboard, /专业模式/);
  assert.match(dashboard, /experience_mode: nextMode/);
  assert.match(settings, /data-experience-mode="minimal"/);
  assert.match(settings, /data-experience-mode="professional"/);
});

test("Linux 未连接顶部卡片使用指定说明并支持点击启动", async () => {
  const dashboard = await read("../web/js/pages/dashboard.js");

  assert.match(dashboard, /点击卡片即可链接全部添加的服务器/);
  assert.match(dashboard, /id="connectionCard"/);
  assert.match(dashboard, /post\(running \? "\/stop" : "\/start"\)/);
});

import { compile } from "@vue/compiler-dom";
import { build } from "esbuild";
import {
  copyFile,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const consoleRoot = join(scriptDirectory, "..");
const serverRoot = join(consoleRoot, "..");
const sourcePath = join(consoleRoot, "src", "index.source.html");
const staticRoot = join(serverRoot, "static");
const assetsRoot = join(staticRoot, "assets");
const webfontsRoot = join(staticRoot, "webfonts");
const licensesRoot = join(staticRoot, "licenses");

const source = await readFile(sourcePath, "utf8");
const appOpen = '<div id="app" v-cloak>';
const appStart = source.indexOf(appOpen);
const scriptStart = source.indexOf("<script>", appStart);
const appEnd = source.lastIndexOf("</div>", scriptStart);
const scriptEnd = source.indexOf("</script>", scriptStart);

if ([appStart, scriptStart, appEnd, scriptEnd].some((index) => index < 0)) {
  throw new Error("无法识别 Web 控制台模板边界");
}

const template = source.slice(appStart + appOpen.length, appEnd).trim();
let application = source.slice(scriptStart + "<script>".length, scriptEnd).trim();

if (!application.includes("createApp({") || !application.endsWith("}).mount('#app');")) {
  throw new Error("无法识别 Web 控制台应用入口");
}

application = application.replace("createApp({", "const appOptions = {");
application = application.replace(/\}\)\.mount\('#app'\);$/, "};");

const { code: renderFactory } = compile(template, {
  mode: "function",
  hoistStatic: true,
});
const applicationBundle = `${application}\n\nappOptions.render = (function compileTemplate(Vue) {\n${renderFactory}\n})(Vue);\ncreateApp(appOptions).mount('#app');\n`;

const document = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VNTS 控制中心</title>
  <link rel="stylesheet" href="/assets/app.css">
  <link rel="stylesheet" href="/assets/fontawesome.min.css">
  <script defer src="/assets/vue.runtime.global.prod.js"></script>
  <script defer src="/assets/qrcode.min.js"></script>
  <script defer src="/assets/app.js"></script>
</head>
<body class="bg-gray-100 min-h-screen text-gray-800">
  <div id="app" v-cloak></div>
</body>
</html>
`;

await Promise.all([
  mkdir(assetsRoot, { recursive: true }),
  mkdir(webfontsRoot, { recursive: true }),
  mkdir(licensesRoot, { recursive: true }),
]);

await build({
  entryPoints: [join(consoleRoot, "src", "qrcode-entry.js")],
  outfile: join(assetsRoot, "qrcode.min.js"),
  bundle: true,
  minify: true,
  platform: "browser",
  format: "iife",
  legalComments: "none",
});

await Promise.all([
  writeFile(join(staticRoot, "index.html"), document),
  writeFile(join(assetsRoot, "app.js"), applicationBundle),
  copyFile(
    join(consoleRoot, "node_modules", "vue", "dist", "vue.runtime.global.prod.js"),
    join(assetsRoot, "vue.runtime.global.prod.js"),
  ),
  copyFile(
    join(consoleRoot, "node_modules", "@fortawesome", "fontawesome-free", "css", "all.min.css"),
    join(assetsRoot, "fontawesome.min.css"),
  ),
  copyFile(join(consoleRoot, "node_modules", "vue", "LICENSE"), join(licensesRoot, "vue.txt")),
  copyFile(
    join(consoleRoot, "node_modules", "@fortawesome", "fontawesome-free", "LICENSE.txt"),
    join(licensesRoot, "fontawesome.txt"),
  ),
  copyFile(join(consoleRoot, "node_modules", "qrcode", "license"), join(licensesRoot, "qrcode.txt")),
  copyFile(
    join(consoleRoot, "node_modules", "dijkstrajs", "LICENSE.md"),
    join(licensesRoot, "dijkstrajs.txt"),
  ),
  copyFile(
    join(consoleRoot, "node_modules", "tailwindcss", "LICENSE"),
    join(licensesRoot, "tailwindcss.txt"),
  ),
]);

const fontSource = join(
  consoleRoot,
  "node_modules",
  "@fortawesome",
  "fontawesome-free",
  "webfonts",
);
for (const entry of await readdir(fontSource, { withFileTypes: true })) {
  if (entry.isFile()) {
    await copyFile(join(fontSource, entry.name), join(webfontsRoot, entry.name));
  }
}

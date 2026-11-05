# Windows 双窗口插件最小尺寸失效

## 表现

设置 `windowManager.setMinimumSize` 后，程序配置记录的窗口大小正确，但用户仍能拖到更小，导致仪表盘统计卡片被截断。

## 根因

主窗口同时注册了 `bitsdojo_window` 和 `window_manager`。前者原生子类过程在 `WM_GETMINMAXINFO` 分支直接返回，不再传递消息；后者的最小尺寸处理代码因而没有机会执行。未设置 `bitsdojo.appWindow.minSize` 时，实际窗口下限仍为空。

## 解决

通过 `lib/utils/desktop_window_constraints.dart` 的统一入口设置下限。Windows 上同时设置两套插件，覆盖启动、首次配置后的自适应及模式切换。不要只修改默认窗口大小或在缩小之后反弹调整。

## 验证

运行 `scripts/verify_window_minimum.ps1` 查询安装程序实际响应的原生最小尺寸。脚本只读，不移动业务窗口，并按该窗口 DPI 换算逻辑像素。

2026-11-05 实测：修复前 0×0、当前内容区 428×352；修复后下限 720×540，`Passed: true`。`test/desktop_window_constraints_test.dart` 覆盖启动及两种模式来回切换时的双插件同步；相关测试共 20 项通过。图形工具不可用时，应明确区分原生消息验收与截图/鼠标拖拽验收。

完整本机部署证据见 `测试文档/仪表盘最小窗口尺寸优化.md`。

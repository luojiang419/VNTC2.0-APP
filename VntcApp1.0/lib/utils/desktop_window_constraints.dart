import 'dart:io';
import 'dart:ui';

import 'package:bitsdojo_window/bitsdojo_window.dart' as bitsdojo;
import 'package:window_manager/window_manager.dart';

/// 主窗口同时加载两套窗口插件，必须让它们使用相同的尺寸约束。
class DesktopWindowConstraints {
  const DesktopWindowConstraints._();

  static Future<void> setMinimumSize(Size size) async {
    await windowManager.setMinimumSize(size);
    if (Platform.isWindows) {
      // bitsdojo 的原生子类过程会直接消费 WM_GETMINMAXINFO，
      // window_manager 的消息代理因此收不到它，必须同步实际生效的下限。
      bitsdojo.appWindow.minSize = size;
    }
  }
}

import 'dart:io';

// 使用平台接口替换原生插件，验证两套窗口插件的约束同步。
// ignore: depend_on_referenced_packages
import 'package:bitsdojo_window_platform_interface/bitsdojo_window_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/utils/dashboard_window_sizing.dart';
import 'package:vnt_app/utils/desktop_window_constraints.dart';
import 'package:vnt_app/utils/window_restore_guard.dart';

class _Window extends Fake implements DesktopWindow {
  final minimumSizes = <Size?>[];

  @override
  set minSize(Size? value) => minimumSizes.add(value);
}

class _Platform extends BitsdojoWindowPlatform {
  final window = _Window();

  @override
  DesktopWindow get appWindow => window;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动及来回切换模式时同步真正消费尺寸消息的 bitsdojo 插件', () async {
    final previousPlatform = BitsdojoWindowPlatform.instance;
    final platform = _Platform();
    BitsdojoWindowPlatform.instance = platform;
    final windowManagerSizes = <Size>[];
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setMinimumSize') {
        final args = call.arguments as Map;
        windowManagerSizes.add(Size(args['width'], args['height']));
      }
      return null;
    });
    addTearDown(() {
      BitsdojoWindowPlatform.instance = previousPlatform;
      messenger.setMockMethodCallHandler(channel, null);
    });

    final sizes = [
      WindowRestoreGuard.minimumWindowSize,
      DashboardWindowSizing.regularMinimumSize,
      DashboardWindowSizing.professionalMinimumSize,
      DashboardWindowSizing.regularMinimumSize,
    ];
    for (final size in sizes) {
      await DesktopWindowConstraints.setMinimumSize(size);
    }

    expect(windowManagerSizes, sizes);
    expect(platform.window.minimumSizes, sizes);
  }, skip: !Platform.isWindows);
}

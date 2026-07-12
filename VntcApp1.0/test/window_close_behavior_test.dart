import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/window_close_behavior.dart';

void main() {
  group('WindowCloseBehavior', () {
    test('正确映射持久化值', () {
      expect(
          windowCloseBehaviorFromPersistedValue(null), WindowCloseBehavior.ask);
      expect(
        windowCloseBehaviorFromPersistedValue(false),
        WindowCloseBehavior.minimizeToTray,
      );
      expect(
        windowCloseBehaviorFromPersistedValue(true),
        WindowCloseBehavior.exitApp,
      );
    });

    test('正确输出持久化值与标签', () {
      expect(WindowCloseBehavior.ask.persistedValue, isNull);
      expect(
        WindowCloseBehavior.minimizeToTray.persistedValue,
        isFalse,
      );
      expect(WindowCloseBehavior.exitApp.persistedValue, isTrue);

      expect(WindowCloseBehavior.ask.label, '每次询问');
      expect(WindowCloseBehavior.minimizeToTray.label, '最小化到托盘');
      expect(WindowCloseBehavior.exitApp.label, '关闭程序');
    });

    test('macOS 和 Linux 关闭窗口后需要显式终止进程', () {
      expect(
        requiresExplicitDesktopProcessExit(isMacOS: true, isLinux: false),
        isTrue,
      );
      expect(
        requiresExplicitDesktopProcessExit(isMacOS: false, isLinux: true),
        isTrue,
      );
      expect(
        requiresExplicitDesktopProcessExit(isMacOS: false, isLinux: false),
        isFalse,
      );
    });
  });
}

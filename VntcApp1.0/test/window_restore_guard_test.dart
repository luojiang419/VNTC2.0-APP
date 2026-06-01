import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:vnt_app/data_persistence.dart';
import 'package:vnt_app/utils/window_restore_guard.dart';

void main() {
  group('WindowRestoreGuard', () {
    final display = Display(
      id: 1,
      size: const Size(1920, 1080),
      visiblePosition: Offset.zero,
      visibleSize: const Size(1920, 1040),
    );

    test('无保存坐标时居中', () {
      final result = WindowRestoreGuard.resolve(
        displays: [display],
        defaultSize: const Size(1000, 700),
        minimumSize: const Size(800, 600),
      );

      expect(result.decision, WindowRestoreDecision.centered);
      expect(result.position.dx, 460);
      expect(result.position.dy, 170);
    });

    test('完全越界时回到主屏中央', () {
      final result = WindowRestoreGuard.resolve(
        displays: [display],
        defaultSize: const Size(1000, 700),
        minimumSize: const Size(800, 600),
        savedSize: const Size(1000, 700),
        savedPosition: const Offset(3000, 2000),
      );

      expect(result.decision, WindowRestoreDecision.centered);
      expect(result.position.dx, 460);
      expect(result.position.dy, 170);
    });

    test('部分越界时夹回可视区域', () {
      final result = WindowRestoreGuard.resolve(
        displays: [display],
        defaultSize: const Size(1000, 700),
        minimumSize: const Size(800, 600),
        savedSize: const Size(1000, 700),
        savedPosition: const Offset(1800, 900),
      );

      expect(result.decision, WindowRestoreDecision.clamped);
      expect(result.position.dx, 920);
      expect(result.position.dy, 340);
    });

    test('合法坐标原样恢复', () {
      final result = WindowRestoreGuard.resolve(
        displays: [display],
        defaultSize: const Size(1000, 700),
        minimumSize: const Size(800, 600),
        savedSize: const Size(1000, 700),
        savedPosition: const Offset(100, 100),
      );

      expect(result.decision, WindowRestoreDecision.restored);
      expect(result.position, const Offset(100, 100));
    });
  });

  group('Distribution config', () {
    test('清洗分发配置时移除机器相关字段', () {
      final sanitized = DataPersistence.sanitizeWindowsDistributionConfigMap({
        'window-x': 123,
        'window-y': 456,
        'window-width': 1000,
        'window-height': 700,
        'vnt-unique-id-key': 'device-id',
        'is-auto-start': true,
        'is-always-on-top': true,
        'is-close-app': false,
        'default-key': 'abc',
        'data-key': ['x'],
      });

      expect(sanitized.containsKey('window-x'), isFalse);
      expect(sanitized.containsKey('window-y'), isFalse);
      expect(sanitized.containsKey('window-width'), isFalse);
      expect(sanitized.containsKey('window-height'), isFalse);
      expect(sanitized.containsKey('vnt-unique-id-key'), isFalse);
      expect(sanitized.containsKey('is-auto-start'), isFalse);
      expect(sanitized.containsKey('is-always-on-top'), isFalse);
      expect(sanitized.containsKey('is-close-app'), isFalse);
      expect(sanitized['default-key'], 'abc');
      expect(sanitized['data-key'], ['x']);
    });
  });
}

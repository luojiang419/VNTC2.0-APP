import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/utils/dashboard_window_sizing.dart';

void main() {
  group('DashboardWindowSizing', () {
    test('1080p 和 2K 屏幕使用 610x450', () {
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(1920, 1080),
        ),
        const Size(610, 450),
      );
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(2560, 1440),
        ),
        const Size(610, 450),
      );
    });

    test('按 DPI 还原后的 4K 屏幕使用 760x560', () {
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(2560, 1440),
          scaleFactor: 1.5,
        ),
        const Size(760, 560),
      );
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(3840, 2160),
        ),
        const Size(760, 560),
      );
    });

    test('竖屏 4K 也使用 760x560', () {
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(2160, 3840),
        ),
        const Size(760, 560),
      );
    });

    test('无效缩放比例安全回退为 1', () {
      expect(
        DashboardWindowSizing.regularSizeForDisplay(
          const Size(2560, 1440),
          scaleFactor: 0,
        ),
        const Size(610, 450),
      );
    });
  });
}

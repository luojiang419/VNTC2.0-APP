import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/utils/silent_start_policy.dart';

void main() {
  test('普通启动始终正常显示窗口', () {
    expect(
      resolveSilentStartWindowAction(
        silentStart: false,
        trayInitialized: true,
      ),
      SilentStartWindowAction.showNormally,
    );
  });

  test('静默启动且托盘可用时保持隐藏', () {
    expect(
      resolveSilentStartWindowAction(
        silentStart: true,
        trayInitialized: true,
      ),
      SilentStartWindowAction.keepHidden,
    );
  });

  test('静默启动但托盘失败时显示窗口避免失去入口', () {
    expect(
      resolveSilentStartWindowAction(
        silentStart: true,
        trayInitialized: false,
      ),
      SilentStartWindowAction.showTrayFailureFallback,
    );
  });
}

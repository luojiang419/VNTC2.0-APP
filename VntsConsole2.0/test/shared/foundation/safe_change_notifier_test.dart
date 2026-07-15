import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/shared/foundation/safe_change_notifier.dart';

class _TestNotifier extends SafeChangeNotifier {
  void emit() => notifyListeners();
}

void main() {
  test('异步结果在控制器销毁后不会继续通知监听器', () {
    final notifier = _TestNotifier();
    var notifications = 0;
    notifier.addListener(() => notifications++);

    notifier.emit();
    expect(notifications, 1);

    notifier.dispose();
    expect(notifier.emit, returnsNormally);
    expect(notifications, 1);
  });
}

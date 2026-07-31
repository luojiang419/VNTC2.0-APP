import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnt_app/screenshot/screenshot_shortcut_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('截图快捷键默认使用 F6', () async {
    final preferences = ScreenshotShortcutPreferences();

    expect(await preferences.load(), 'F6');
  });

  test('截图快捷键可以持久化为其他功能键', () async {
    final preferences = ScreenshotShortcutPreferences();

    await preferences.save('F8');

    expect(await preferences.load(), 'F8');
  });

  test('未知截图快捷键安全回退到 F6', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ScreenshotShortcutPreferences.storageKey: 'Ctrl+6',
    });
    final preferences = ScreenshotShortcutPreferences();

    expect(await preferences.load(), 'F6');
  });

  test('拒绝保存不支持的截图快捷键', () async {
    final preferences = ScreenshotShortcutPreferences();

    expect(
      () => preferences.save('Ctrl+6'),
      throwsArgumentError,
    );
  });
}

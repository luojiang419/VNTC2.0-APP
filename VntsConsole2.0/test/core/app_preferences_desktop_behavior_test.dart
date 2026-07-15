import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnts_console/core/platform/desktop_behavior.dart';
import 'package:vnts_console/core/storage/app_preferences.dart';

void main() {
  test('桌面行为使用安全默认值并可持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await AppPreferences.load();

    expect(preferences.closeBehavior, AppCloseBehavior.minimizeToTray);
    expect(preferences.startupBehavior, AppStartupBehavior.disabled);

    await preferences.saveCloseBehavior(AppCloseBehavior.stopServiceAndExit);
    await preferences.saveStartupBehavior(AppStartupBehavior.silentToTray);

    final reloaded = await AppPreferences.load();
    expect(reloaded.closeBehavior, AppCloseBehavior.stopServiceAndExit);
    expect(reloaded.startupBehavior, AppStartupBehavior.silentToTray);
  });
}

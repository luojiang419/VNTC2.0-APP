import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnt_app/update/update_proxy_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认使用自动系统代理', () async {
    final settings = await AppUpdateProxySettings.load();

    expect(settings.mode, AppUpdateProxyMode.automatic);
    expect(settings.customAddress, isEmpty);
  });

  test('保存并恢复自定义代理', () async {
    const settings = AppUpdateProxySettings(
      mode: AppUpdateProxyMode.custom,
      customAddress: ' socks5://127.0.0.1:7890 ',
    );

    await settings.save();
    final restored = await AppUpdateProxySettings.load();

    expect(restored.mode, AppUpdateProxyMode.custom);
    expect(restored.customAddress, 'socks5://127.0.0.1:7890');
  });

  test('未知模式安全回退自动代理', () async {
    SharedPreferences.setMockInitialValues({
      'app_update_proxy_mode': 'removed-mode',
      'app_update_proxy_custom_address': '127.0.0.1:7890',
    });

    final settings = await AppUpdateProxySettings.load();

    expect(settings.mode, AppUpdateProxyMode.automatic);
  });
}

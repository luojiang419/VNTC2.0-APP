import 'package:shared_preferences/shared_preferences.dart';

enum AppUpdateProxyMode { automatic, custom, direct }

class AppUpdateProxySettings {
  const AppUpdateProxySettings({
    this.mode = AppUpdateProxyMode.automatic,
    this.customAddress = '',
  });

  static const _modeKey = 'app_update_proxy_mode';
  static const _customAddressKey = 'app_update_proxy_custom_address';

  final AppUpdateProxyMode mode;
  final String customAddress;

  static Future<AppUpdateProxySettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    final savedMode = preferences.getString(_modeKey);
    final mode = AppUpdateProxyMode.values.firstWhere(
      (item) => item.name == savedMode,
      orElse: () => AppUpdateProxyMode.automatic,
    );
    return AppUpdateProxySettings(
      mode: mode,
      customAddress: preferences.getString(_customAddressKey) ?? '',
    );
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_modeKey, mode.name);
    await preferences.setString(_customAddressKey, customAddress.trim());
  }
}

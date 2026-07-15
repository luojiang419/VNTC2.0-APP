import 'package:shared_preferences/shared_preferences.dart';

enum AppUpdateMode {
  manual('manual'),
  automatic('automatic'),
  disabled('disabled');

  const AppUpdateMode(this.storageValue);

  final String storageValue;

  bool get checksForUpdates => this != AppUpdateMode.disabled;
  bool get installsAutomatically => this == AppUpdateMode.automatic;

  String get label => switch (this) {
        AppUpdateMode.manual => '手动更新',
        AppUpdateMode.automatic => '自动更新',
        AppUpdateMode.disabled => '关闭更新',
      };

  String get description => switch (this) {
        AppUpdateMode.manual => '自动下载安装包，下载完成后弹窗提示',
        AppUpdateMode.automatic => '自动检测、下载并直接进入安装流程',
        AppUpdateMode.disabled => '不检测、不下载更新',
      };

  static AppUpdateMode fromStorage(String? value) {
    for (final mode in AppUpdateMode.values) {
      if (mode.storageValue == value) {
        return mode;
      }
    }
    return AppUpdateMode.manual;
  }
}

class AppUpdatePreferences {
  static const preferenceKey = 'app_update_mode';

  Future<AppUpdateMode> loadMode() async {
    final preferences = await SharedPreferences.getInstance();
    return AppUpdateMode.fromStorage(preferences.getString(preferenceKey));
  }

  Future<void> saveMode(AppUpdateMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(preferenceKey, mode.storageValue);
  }
}

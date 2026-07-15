import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../security/console_lock_shortcut.dart';
import '../platform/desktop_behavior.dart';

class AppPreferences {
  AppPreferences._(this._preferences);

  static const _themeModeKey = 'console.theme_mode';
  static const _dashboardPollSecondsKey = 'console.dashboard_poll_seconds';
  static const _autoLockHoursKey = 'console.auto_lock_hours';
  static const _lockShortcutKey = 'console.lock_shortcut';
  static const _closeBehaviorKey = 'console.close_behavior';
  static const _startupBehaviorKey = 'console.startup_behavior';
  final SharedPreferences _preferences;

  static Future<AppPreferences> load() async {
    return AppPreferences._(await SharedPreferences.getInstance());
  }

  ThemeMode get themeMode {
    final saved = _preferences.getString(_themeModeKey);
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> saveThemeMode(ThemeMode mode) {
    return _preferences.setString(_themeModeKey, mode.name);
  }

  int get dashboardPollSeconds {
    final saved = _preferences.getInt(_dashboardPollSecondsKey);
    return const {1, 2, 5}.contains(saved) ? saved! : 1;
  }

  Future<void> saveDashboardPollSeconds(int seconds) {
    if (!const {1, 2, 5}.contains(seconds)) {
      throw ArgumentError.value(seconds, 'seconds', '只支持 1、2、5 秒');
    }
    return _preferences.setInt(_dashboardPollSecondsKey, seconds);
  }

  int get autoLockHours {
    final saved = _preferences.getInt(_autoLockHoursKey);
    return const {0, 1, 2, 4, 8, 12, 24}.contains(saved) ? saved! : 2;
  }

  Future<void> saveAutoLockHours(int hours) {
    if (!const {0, 1, 2, 4, 8, 12, 24}.contains(hours)) {
      throw ArgumentError.value(hours, 'hours', '自动锁定只支持关闭或 1/2/4/8/12/24 小时');
    }
    return _preferences.setInt(_autoLockHoursKey, hours);
  }

  ConsoleLockShortcut get lockShortcut =>
      ConsoleLockShortcut.fromStorage(_preferences.getString(_lockShortcutKey));

  Future<void> saveLockShortcut(ConsoleLockShortcut shortcut) {
    return _preferences.setString(_lockShortcutKey, shortcut.name);
  }

  AppCloseBehavior get closeBehavior =>
      AppCloseBehavior.fromStorage(_preferences.getString(_closeBehaviorKey));

  Future<void> saveCloseBehavior(AppCloseBehavior behavior) {
    return _preferences.setString(_closeBehaviorKey, behavior.name);
  }

  AppStartupBehavior get startupBehavior => AppStartupBehavior.fromStorage(
    _preferences.getString(_startupBehaviorKey),
  );

  Future<void> saveStartupBehavior(AppStartupBehavior behavior) {
    return _preferences.setString(_startupBehaviorKey, behavior.name);
  }
}

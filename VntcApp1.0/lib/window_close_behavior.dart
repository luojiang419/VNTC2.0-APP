import 'package:vnt_app/l10n/app_i18n.dart';

enum WindowCloseBehavior {
  ask,
  minimizeToTray,
  exitApp,
}

extension WindowCloseBehaviorX on WindowCloseBehavior {
  bool? get persistedValue {
    switch (this) {
      case WindowCloseBehavior.ask:
        return null;
      case WindowCloseBehavior.minimizeToTray:
        return false;
      case WindowCloseBehavior.exitApp:
        return true;
    }
  }

  String get label {
    switch (this) {
      case WindowCloseBehavior.ask:
        return '每次询问'.tr();
      case WindowCloseBehavior.minimizeToTray:
        return '最小化到托盘'.tr();
      case WindowCloseBehavior.exitApp:
        return '关闭程序'.tr();
    }
  }

  String get description {
    switch (this) {
      case WindowCloseBehavior.ask:
        return '点击关闭按钮时弹出确认窗口'.tr();
      case WindowCloseBehavior.minimizeToTray:
        return '点击关闭按钮时隐藏到系统托盘'.tr();
      case WindowCloseBehavior.exitApp:
        return '点击关闭按钮时直接退出应用'.tr();
    }
  }
}

WindowCloseBehavior windowCloseBehaviorFromPersistedValue(bool? value) {
  if (value == null) {
    return WindowCloseBehavior.ask;
  }
  return value
      ? WindowCloseBehavior.exitApp
      : WindowCloseBehavior.minimizeToTray;
}

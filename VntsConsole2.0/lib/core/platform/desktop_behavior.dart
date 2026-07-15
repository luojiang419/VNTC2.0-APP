enum AppCloseBehavior {
  minimizeToTray,
  stopServiceAndExit;

  static AppCloseBehavior fromStorage(String? value) {
    return AppCloseBehavior.values.firstWhere(
      (behavior) => behavior.name == value,
      orElse: () => AppCloseBehavior.minimizeToTray,
    );
  }

  String get label => switch (this) {
    AppCloseBehavior.minimizeToTray => '最小化到托盘',
    AppCloseBehavior.stopServiceAndExit => '关闭服务并退出',
  };
}

enum AppStartupBehavior {
  disabled,
  normal,
  silentToTray;

  static AppStartupBehavior fromStorage(String? value) {
    return AppStartupBehavior.values.firstWhere(
      (behavior) => behavior.name == value,
      orElse: () => AppStartupBehavior.disabled,
    );
  }

  String get label => switch (this) {
    AppStartupBehavior.disabled => '不开机自启',
    AppStartupBehavior.normal => '开机自启（显示主窗口）',
    AppStartupBehavior.silentToTray => '开机静默自启（仅托盘运行）',
  };
}

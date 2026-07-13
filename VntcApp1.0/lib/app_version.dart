class AppVersion {
  AppVersion._();

  static const String baseTitle = String.fromEnvironment(
    'APP_BASE_TITLE',
    defaultValue: 'VNTC APP2.0',
  );
  static const String buildVersion = String.fromEnvironment(
    'APP_BUILD_VERSION',
    defaultValue: '4.8.12',
  );
  static const String explicitDisplayVersion = String.fromEnvironment(
    'APP_DISPLAY_VERSION',
    defaultValue: '',
  );
  static const String explicitProductName = String.fromEnvironment(
    'APP_PRODUCT_NAME',
    defaultValue: '',
  );
  static const String explicitWindowTitle = String.fromEnvironment(
    'APP_WINDOW_TITLE',
    defaultValue: '',
  );

  static String get currentVersion {
    final version = buildVersion.trim();
    return version.isEmpty || version == '0.0' ? '4.8.12' : version;
  }

  static String get displayVersion => explicitDisplayVersion.isEmpty
      ? 'v$currentVersion'
      : explicitDisplayVersion;

  static String get productName =>
      explicitProductName.isEmpty ? baseTitle : explicitProductName;

  static String get windowTitle => explicitWindowTitle.isEmpty
      ? '$productName $displayVersion'
      : explicitWindowTitle;

  static String get trayTooltip => '$windowTitle - Virtual Network Tool';
}

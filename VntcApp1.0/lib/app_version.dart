class AppVersion {
  AppVersion._();

  static const String baseTitle = String.fromEnvironment(
    'APP_BASE_TITLE',
    defaultValue: 'VNT App',
  );
  static const String buildVersion = String.fromEnvironment(
    'APP_BUILD_VERSION',
    defaultValue: '0.0',
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

  static String get displayVersion => explicitDisplayVersion.isEmpty
      ? 'v$buildVersion'
      : explicitDisplayVersion;

  static String get productName => explicitProductName.isEmpty
      ? '$baseTitle $buildVersion'
      : explicitProductName;

  static String get windowTitle =>
      explicitWindowTitle.isEmpty ? productName : explicitWindowTitle;

  static String get trayTooltip => '$windowTitle - Virtual Network Tool';
}

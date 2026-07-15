import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vnt_app/branding/app_branding.dart';

class AppVersion {
  AppVersion._();

  static AppBranding _branding = AppBranding.defaults;

  static void initialize([String? executablePath]) {
    _branding = AppBranding.loadForExecutable(executablePath);
  }

  static Future<void> initializeForCurrentPlatform() async {
    if (!Platform.isAndroid) {
      initialize();
      return;
    }

    try {
      final source = await rootBundle.loadString(AppBranding.androidAssetPath);
      _branding = AppBranding.loadFromJsonText(
        source,
        fallbackUpdateEnabled: false,
      );
    } catch (error) {
      _branding = AppBranding.fallback(
        updateEnabled: false,
        loadError: error.toString(),
      );
    }
  }

  static AppBranding get branding => _branding;

  static const String baseTitle = String.fromEnvironment(
    'APP_BASE_TITLE',
    defaultValue: 'VNTC APP2.0',
  );
  static const String buildVersion = String.fromEnvironment(
    'APP_BUILD_VERSION',
    defaultValue: '4.8.22',
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
    return version.isEmpty || version == '0.0' ? '4.8.22' : version;
  }

  static String get displayVersion => explicitDisplayVersion.isEmpty
      ? 'v$currentVersion'
      : explicitDisplayVersion;

  static String get productName => _branding.isBranded
      ? _branding.productName
      : (explicitProductName.isEmpty ? baseTitle : explicitProductName);

  static String get windowTitle {
    if (_branding.isBranded) {
      return _branding.windowTitle;
    }
    return explicitWindowTitle.isEmpty
        ? '$productName $displayVersion'
        : explicitWindowTitle;
  }

  static String get trayTooltip => _branding.isBranded
      ? _branding.trayTooltip
      : '$windowTitle - Virtual Network Tool';

  static String get executableName => _branding.executableName;

  static String get installerBaseName => _branding.installerBaseName;

  static bool get updateEnabled => _branding.updateEnabled;

  static bool get showAboutPage => !_branding.hideAboutPage;

  static bool get isBranded => _branding.isBranded;
}

class RemoteAssistConstants {
  RemoteAssistConstants._();

  static const int directAccessPort = 49999;
  static const int presencePort = 49998;

  static const String serviceName = 'vntcrustdesk';
  static const String executableName = 'vntcrustdesk.exe';
  static const String managedBy = 'VNT App 2.0';
  static const String macosAppBundleName = 'VNTC RustDesk.app';
  static const String macosBundledAppRelativePath =
      'remote_assist/VNTC RustDesk.app';
  static const String macosManifestRelativePath =
      'remote_assist/vntcrustdesk_manifest.json';

  static const String tcpFirewallRuleName = 'VNTC Remote Assist TCP 49999';
  static const String udpFirewallRuleName =
      'VNTC Remote Assist Presence UDP 49998';

  static const String manifestRelativePath =
      'remote_assist/vntcrustdesk_manifest.json';
  static const String bundledMsiRelativePath =
      'remote_assist/artifacts/vntcrustdesk.msi';
  static const String bootstrapScriptRelativePath =
      'scripts/bootstrap_vntcrustdesk.ps1';
  static const String uninstallScriptRelativePath =
      'scripts/uninstall_vntcrustdesk.ps1';

  static const String capabilityWindows = 'remote_assist_windows';
  static const String capabilityAndroid = 'remote_assist_android';
  static const String capabilityMacos = 'remote_assist_macos';
  static const String capabilityController = 'remote_assist_controller';
  static const String capabilityControlled = 'remote_assist_controlled';

  static const String androidPermissionNotification = 'notification';
  static const String androidPermissionScreenCapture = 'screen_capture';
  static const String androidPermissionAccessibility = 'accessibility';
  static const String androidPermissionOverlay = 'overlay';
  static const String androidPermissionBatteryOptimization =
      'battery_optimization';

  static const String androidSettingsNotifications = 'notifications';
  static const String androidSettingsScreenCapture = 'screen_capture';
  static const String androidSettingsAccessibility = 'accessibility';
  static const String androidSettingsOverlay = 'overlay';
  static const String androidSettingsBatteryOptimization =
      'battery_optimization';

  static const String macosSettingsScreenRecording = 'screen_recording';
  static const String macosSettingsAccessibility = 'accessibility';
  static const String macosSettingsMicrophone = 'microphone';

  static const String presencePacketType = 'vntc_remote_assist_presence';

  static const Duration presenceBroadcastInterval = Duration(seconds: 5);
  static const Duration presenceExpiry = Duration(seconds: 20);
  static const Duration refreshInterval = Duration(seconds: 6);
}

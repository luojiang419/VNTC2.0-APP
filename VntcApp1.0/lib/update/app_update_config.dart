import 'package:vnt_app/app_version.dart';

class AppUpdateConfig {
  AppUpdateConfig._();

  static const appName = 'VNTC APP2.0';
  static const userAgent = 'VNTC-APP-Updater/2.0';
  static const windowsExecutableName = 'vnt_app.exe';
  static const windowsInstallerBaseName = 'VNT_App';
  static const macosBundleIdentifier = 'top.wherewego.vntApp';
  static const macosUpdaterBundleName = 'VNTC Updater.app';
  static const windowsTrustedPublisherName = String.fromEnvironment(
    'APP_UPDATE_WINDOWS_TRUSTED_PUBLISHER',
    defaultValue: '',
  );

  static const latestReleaseApiUrl = String.fromEnvironment(
    'APP_UPDATE_API_URL',
    defaultValue:
        'https://api.github.com/repos/luojiang419/VNTC2.0-APP/releases/latest',
  );

  static const releasePageUrl = String.fromEnvironment(
    'APP_UPDATE_RELEASE_PAGE_URL',
    defaultValue: 'https://github.com/luojiang419/VNTC2.0-APP/releases/latest',
  );

  static const runUpdateSessionArg = 'run-update-session';
  static const updateVersionArg = 'update-version';
  static const updateInstallerArg = 'update-installer';
  static const updateInstallRootArg = 'update-install-root';
  static const updateOldPidArg = 'update-old-pid';
  static const updateStorageRootArg = 'update-storage-root';
  static const updateLaunchPathArg = 'update-launch-path';
  static const updateTokenArg = 'update-token';
  static const updateSha256Arg = 'update-sha256';
  static const updateSessionManifestFileName = 'session.json';

  static String get currentVersion => AppVersion.currentVersion;
  static String get currentVersionTag => 'v$currentVersion';
}

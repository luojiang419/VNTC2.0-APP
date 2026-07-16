import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mainActivity = File(
    'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
  ).readAsStringSync();
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final accessibility = File(
    'android/app/src/main/res/xml/accessibility_service_config.xml',
  ).readAsStringSync();

  test('Android 更新 APK 在启动系统安装器前执行失败关闭校验', () {
    final installMethod = mainActivity.substring(
      mainActivity.indexOf('private void installDownloadedApk('),
      mainActivity.indexOf('private void resumePendingApkInstall()'),
    );

    expect(installMethod, contains('verifyDownloadedApk(filePath)'));
    expect(
      installMethod.indexOf('verifyDownloadedApk(filePath)'),
      lessThan(installMethod.indexOf('canRequestPackageInstalls()')),
    );
    expect(mainActivity, contains('getPackageArchiveInfo('));
    expect(mainActivity, contains('isInsideAppUpdateDirectory('));
    expect(mainActivity,
        contains('getPackageName().equals(archiveInfo.packageName)'));
    expect(
        mainActivity, contains('incomingVersionCode <= installedVersionCode'));
    expect(mainActivity, contains('signatures.length != 1'));
    expect(mainActivity, contains('MessageDigest.getInstance("SHA-256")'));
  });

  test('Android 更新器固定的官方证书与仓库信任配置一致', () {
    final trust = jsonDecode(
      File('config/android_official_signing_trust.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final match = RegExp(
      r'ANDROID_OFFICIAL_CERT_SHA256\s*=\s*"([0-9A-F]{64})"',
    ).firstMatch(mainActivity);

    expect(match, isNotNull);
    expect(match!.group(1), trust['certificateSha256']);
    expect(mainActivity, contains('APK_SIGNER_MISMATCH'));
    expect(mainActivity, contains('APK_PACKAGE_MISMATCH'));
    expect(mainActivity, contains('APK_VERSION_NOT_NEWER'));
  });

  test('Android 无障碍仅保留远程输入所需能力和事件范围', () {
    expect(accessibility, isNot(contains('typeAllMask')));
    expect(accessibility, isNot(contains('flagReportViewIds')));
    expect(accessibility, contains('typeViewFocused'));
    expect(accessibility, contains('typeWindowStateChanged'));
    expect(accessibility, contains('typeWindowsChanged'));
    expect(accessibility, contains('canPerformGestures="true"'));
    expect(accessibility, contains('canRetrieveWindowContent="true"'));

    expect(
      manifest,
      isNot(
        matches(
          RegExp(
            r'<uses-permission[^>]+android\.permission\.BIND_QUICK_SETTINGS_TILE',
            dotAll: true,
          ),
        ),
      ),
    );
    expect(
      manifest,
      contains(
        'android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"',
      ),
    );
  });
}

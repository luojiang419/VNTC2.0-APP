import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/app_version.dart';
import 'package:vnt_app/update/update_dialog.dart';
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/update/update_session.dart';

void main() {
  test('移除升级后服务在解析代理或访问网络前拒绝执行', () async {
    final temp = _initializeBranding(updateEnabled: false);
    var proxyResolverCalled = false;
    addTearDown(() => _resetBranding(temp));

    final service = AppUpdateService(
      proxyResolver: () async {
        proxyResolverCalled = true;
        return null;
      },
    );

    await expectLater(
      service.checkLatest(
        currentVersion: '4.8.19',
        platform: AppUpdatePlatform.windows,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('已移除升级功能'),
        ),
      ),
    );
    expect(proxyResolverCalled, isFalse);
  });

  test('移除升级后六个更新执行路径均在副作用前拒绝', () async {
    final temp = _initializeBranding(updateEnabled: false);
    var proxyResolverCalled = false;
    addTearDown(() => _resetBranding(temp));
    final service = AppUpdateService(
      proxyResolver: () async {
        proxyResolverCalled = true;
        return null;
      },
    );
    final asset = AppUpdateAsset(
      name: 'VNT_App_4.8.19_Windows_Setup.exe',
      downloadUrl: Uri.parse('https://example.com/update.exe'),
      size: 1,
      sha256: List.filled(64, '0').join(),
    );
    final info = AppUpdateInfo(
      currentVersion: '4.8.18',
      latestVersion: '4.8.19',
      tagName: 'v4.8.19',
      releaseName: 'VNTC APP2.0 v4.8.19',
      releaseNotes: '行为阻断测试',
      releasePageUrl: Uri.parse('https://example.com/v4.8.19'),
      hasUpdate: true,
      platform: AppUpdatePlatform.windows,
      asset: asset,
    );
    final result = AppUpdateDownloadResult(
      filePath: '${temp.path}${Platform.pathSeparator}update.exe',
      asset: asset,
      versionTag: 'v4.8.19',
    );
    final session = AppUpdateSession(
      sessionId: 'session_12345678',
      token: List.filled(64, 'a').join(),
      versionTag: 'v4.8.19',
      installerPath: result.filePath,
      installRoot: temp.path,
      oldPid: 1,
      storageRoot: temp.path,
      launchPath: '${temp.path}${Platform.pathSeparator}测试品牌.exe',
    );

    final calls = <Future<void> Function()>[
      () async {
        await service.checkLatest(
          currentVersion: '4.8.19',
          platform: AppUpdatePlatform.windows,
        );
      },
      () async => service.downloadUpdate(info),
      () => service.openDownloadedInstaller(result),
      () => service.openReleasePage(info),
      () async => service.launchWindowsSilentInstaller(result),
      () => service.runUpdaterSession(session),
    ];

    for (final call in calls) {
      await expectLater(
        call(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('已移除升级功能'),
          ),
        ),
      );
    }
    expect(proxyResolverCalled, isFalse);
    expect(File(result.filePath).existsSync(), isFalse);
  });

  testWidgets('移除升级后手动检查和新版弹窗均不显示', (tester) async {
    final temp = _initializeBranding(updateEnabled: false);
    addTearDown(() => _resetBranding(temp));
    late BuildContext pageContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await showUpdateCheckDialog(pageContext);
    await tester.pump();
    expect(find.text('品牌版更新'), findsNothing);

    final shown = await showUpdateAvailableDialog(
      context: pageContext,
      info: _updateInfo(),
      service: AppUpdateService(),
    );
    await tester.pump();

    expect(shown, isFalse);
    expect(find.text('发现新版本'), findsNothing);
  });

  test('升级入口和更新会话均受同一运行时开关保护', () {
    final settings = File('lib/pages/settings_page.dart').readAsStringSync();
    final about = File('lib/pages/about_page.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final service = File('lib/update/update_service.dart').readAsStringSync();

    expect(settings, contains('if (AppVersion.updateEnabled) ...['));
    expect(about, contains('if (AppVersion.updateEnabled) ...['));
    expect(about, contains('onTap: AppVersion.updateEnabled'));
    expect(
      main,
      contains('update session blocked because update feature is removed'),
    );
    expect(
      RegExp(
        r"'update session blocked because update feature is removed'\);"
        r'\s+exit\(0\);',
      ).hasMatch(main),
      isTrue,
    );
    expect(
      RegExp(r'_ensureUpdateEnabled\(\);').allMatches(service).length,
      6,
    );
  });
}

Directory _initializeBranding({required bool updateEnabled}) {
  final temp = Directory.systemTemp.createTempSync('vnt_update_feature_');
  final executable = File(
    '${temp.path}${Platform.pathSeparator}测试品牌.exe',
  );
  File('${temp.path}${Platform.pathSeparator}branding.json')
      .writeAsStringSync(jsonEncode({
    'schemaVersion': 1,
    'brandId': 'brand_12345678',
    'productName': '测试品牌',
    'windowTitle': '测试品牌',
    'trayTooltip': '测试品牌',
    'executableName': '测试品牌.exe',
    'installerBaseName': '测试品牌',
    'updateEnabled': updateEnabled,
    'hideAboutPage': false,
  }));
  AppVersion.initialize(executable.path);
  return temp;
}

void _resetBranding(Directory temp) {
  AppVersion.initialize(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'vnt_official_reset${Platform.pathSeparator}vnt_app.exe',
  );
  if (temp.existsSync()) {
    temp.deleteSync(recursive: true);
  }
}

AppUpdateInfo _updateInfo() {
  return AppUpdateInfo(
    currentVersion: '4.8.18',
    latestVersion: '4.8.19',
    tagName: 'v4.8.19',
    releaseName: 'VNTC APP2.0 v4.8.19',
    releaseNotes: '移除升级功能测试',
    releasePageUrl: Uri.parse('https://example.com/v4.8.19'),
    hasUpdate: true,
    platform: AppUpdatePlatform.windows,
    asset: null,
  );
}

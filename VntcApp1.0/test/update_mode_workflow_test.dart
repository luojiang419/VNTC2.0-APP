import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnt_app/update/app_update_preferences.dart';
import 'package:vnt_app/update/update_dialog.dart';
import 'package:vnt_app/update/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('手动模式自动下载完成后才显示安装提示', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppUpdatePreferences.preferenceKey: AppUpdateMode.manual.storageValue,
    });
    final service = _FakeUpdateService();
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

    final workflow = showUpdateCheckDialog(pageContext, service: service);
    await tester.pumpAndSettle();

    expect(service.checkCalls, 1);
    expect(service.downloadCalls, 1);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('立即安装'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    await workflow;
  });

  testWidgets('自动模式下载完成后直接调用安装流程', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppUpdatePreferences.preferenceKey: AppUpdateMode.automatic.storageValue,
    });
    final service = _FakeUpdateService();
    var installCalls = 0;
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

    await showUpdateCheckDialog(
      pageContext,
      service: service,
      installer: (context, result, service) async {
        installCalls += 1;
      },
    );
    await tester.pumpAndSettle();

    expect(service.checkCalls, 1);
    expect(service.downloadCalls, 1);
    expect(installCalls, 1);
    expect(find.text('发现新版本'), findsNothing);
  });

  testWidgets('关闭模式不会调用检测和下载服务', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppUpdatePreferences.preferenceKey: AppUpdateMode.disabled.storageValue,
    });
    final service = _FakeUpdateService();
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

    await showUpdateCheckDialog(pageContext, service: service);
    await tester.pump();

    expect(service.checkCalls, 0);
    expect(service.downloadCalls, 0);
    expect(find.textContaining('更新检测已关闭'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}

class _FakeUpdateService extends AppUpdateService {
  int checkCalls = 0;
  int downloadCalls = 0;

  @override
  Future<AppUpdateInfo> checkLatest({
    String? currentVersion,
    AppUpdatePlatform? platform,
  }) async {
    checkCalls += 1;
    return _info;
  }

  @override
  Future<AppUpdateDownloadResult> downloadUpdate(
    AppUpdateInfo info, {
    AppUpdateProgress? onProgress,
  }) async {
    downloadCalls += 1;
    onProgress?.call(1, 1);
    return AppUpdateDownloadResult(
      filePath: r'C:\updates\VNT_App_4.6_Windows_Setup.exe',
      asset: _asset,
      versionTag: info.tagName,
    );
  }
}

final _asset = AppUpdateAsset(
  name: 'VNT_App_4.6_Windows_Setup.exe',
  downloadUrl: Uri.parse('https://example.com/update.exe'),
  size: 1,
  sha256: List.filled(64, '0').join(),
);

final _info = AppUpdateInfo(
  currentVersion: '4.5',
  latestVersion: '4.6',
  tagName: 'v4.6',
  releaseName: 'VNTC APP2.0 v4.6',
  releaseNotes: '更新模式工作流测试',
  releasePageUrl: Uri.parse('https://example.com/v4.6'),
  hasUpdate: true,
  platform: AppUpdatePlatform.windows,
  asset: _asset,
);

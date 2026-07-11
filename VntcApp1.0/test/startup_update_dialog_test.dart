import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/update/update_dialog.dart';
import 'package:vnt_app/update/update_service.dart';

void main() {
  testWidgets('启动检查发现新版后显示更新弹窗', (tester) async {
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

    final dialogFuture = showUpdateAvailableDialog(
      context: pageContext,
      info: AppUpdateInfo(
        currentVersion: '4.5',
        latestVersion: '4.6',
        tagName: 'v4.6',
        releaseName: 'VNTC APP2.0 v4.6',
        releaseNotes: '启动自动检查更新',
        releasePageUrl: Uri.parse('https://example.com/v4.6'),
        hasUpdate: true,
        platform: AppUpdatePlatform.windows,
        asset: null,
      ),
      service: AppUpdateService(),
    );

    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('当前版本：v4.5'), findsOneWidget);
    expect(find.text('最新版本：v4.6'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(await dialogFuture, isTrue);
  });
}

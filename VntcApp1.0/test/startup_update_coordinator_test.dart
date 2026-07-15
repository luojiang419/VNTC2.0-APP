import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/update/app_update_preferences.dart';
import 'package:vnt_app/update/startup_update_coordinator.dart';
import 'package:vnt_app/update/update_service.dart';

void main() {
  test('启动自动更新检查支持 Windows 和 Android', () {
    expect(supportsStartupUpdateCheck(AppUpdatePlatform.windows), isTrue);
    expect(supportsStartupUpdateCheck(AppUpdatePlatform.android), isTrue);
    expect(supportsStartupUpdateCheck(AppUpdatePlatform.macos), isFalse);
    expect(supportsStartupUpdateCheck(AppUpdatePlatform.linux), isFalse);
    expect(supportsStartupUpdateCheck(AppUpdatePlatform.ios), isFalse);
  });

  test('手动模式在单次运行中只检测并下载一次', () async {
    var checkCalls = 0;
    var downloadCalls = 0;
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async {
        checkCalls += 1;
        return _updateInfo(hasUpdate: true);
      },
      downloadUpdate: (info) async {
        downloadCalls += 1;
        return _downloadResult(info);
      },
    );

    final first = await coordinator.prepareOnce(AppUpdateMode.manual);
    final second = await coordinator.prepareOnce(AppUpdateMode.manual);

    expect(checkCalls, 1);
    expect(downloadCalls, 1);
    expect(first?.info.latestVersion, '4.6');
    expect(first?.isReadyToInstall, isTrue);
    expect(first?.shouldInstallAutomatically, isFalse);
    expect(second, same(first));
    expect(coordinator.hasPendingUpdate, isTrue);
  });

  test('自动模式准备完成后要求直接安装', () async {
    final coordinator = _coordinator(hasUpdate: true);

    final prepared = await coordinator.prepareOnce(AppUpdateMode.automatic);

    expect(prepared?.isReadyToInstall, isTrue);
    expect(prepared?.shouldInstallAutomatically, isTrue);
  });

  test('发现新版后只消费一次已下载更新', () async {
    final coordinator = _coordinator(hasUpdate: true);

    await coordinator.prepareOnce(AppUpdateMode.manual);

    expect(coordinator.takePendingUpdate(), isNotNull);
    expect(coordinator.takePendingUpdate(), isNull);
    expect(coordinator.hasPendingUpdate, isFalse);
  });

  test('没有新版时不下载也不产生待提示更新', () async {
    var downloadCalls = 0;
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async => _updateInfo(hasUpdate: false),
      downloadUpdate: (info) async {
        downloadCalls += 1;
        return _downloadResult(info);
      },
    );

    expect(
      await coordinator.prepareOnce(AppUpdateMode.manual),
      isNull,
    );
    expect(downloadCalls, 0);
    expect(coordinator.hasPendingUpdate, isFalse);
  });

  test('关闭更新模式在网络检测和下载前结束', () async {
    var checkCalls = 0;
    var downloadCalls = 0;
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async {
        checkCalls += 1;
        return _updateInfo(hasUpdate: true);
      },
      downloadUpdate: (info) async {
        downloadCalls += 1;
        return _downloadResult(info);
      },
    );

    expect(
      await coordinator.prepareOnce(AppUpdateMode.disabled),
      isNull,
    );
    expect(checkCalls, 0);
    expect(downloadCalls, 0);
  });
}

StartupUpdateCoordinator _coordinator({required bool hasUpdate}) {
  return StartupUpdateCoordinator(
    checkLatest: () async => _updateInfo(hasUpdate: hasUpdate),
    downloadUpdate: (info) async => _downloadResult(info),
  );
}

AppUpdateInfo _updateInfo({required bool hasUpdate}) {
  return AppUpdateInfo(
    currentVersion: hasUpdate ? '4.5' : '4.6',
    latestVersion: '4.6',
    tagName: 'v4.6',
    releaseName: 'VNTC APP2.0 v4.6',
    releaseNotes: '自动更新测试',
    releasePageUrl: Uri.parse('https://example.com/v4.6'),
    hasUpdate: hasUpdate,
    platform: AppUpdatePlatform.windows,
    asset: _asset,
  );
}

AppUpdateDownloadResult _downloadResult(AppUpdateInfo info) {
  return AppUpdateDownloadResult(
    filePath: r'C:\updates\VNT_App_4.6_Windows_Setup.exe',
    asset: info.asset!,
    versionTag: info.tagName,
  );
}

final _asset = AppUpdateAsset(
  name: 'VNT_App_4.6_Windows_Setup.exe',
  downloadUrl: Uri.parse('https://example.com/update.exe'),
  size: 1,
  sha256: List.filled(64, '0').join(),
);

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/update/startup_update_coordinator.dart';
import 'package:vnt_app/update/update_service.dart';

void main() {
  test('启动自动更新检查在单次运行中只请求一次', () async {
    var calls = 0;
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async {
        calls += 1;
        return _updateInfo(hasUpdate: true);
      },
    );

    final first = await coordinator.checkOnce();
    final second = await coordinator.checkOnce();

    expect(calls, 1);
    expect(first?.latestVersion, '4.6');
    expect(second, same(first));
    expect(coordinator.hasPendingUpdate, isTrue);
  });

  test('发现新版后只消费一次待提示更新', () async {
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async => _updateInfo(hasUpdate: true),
    );

    await coordinator.checkOnce();

    expect(coordinator.takePendingUpdate(), isNotNull);
    expect(coordinator.takePendingUpdate(), isNull);
    expect(coordinator.hasPendingUpdate, isFalse);
  });

  test('没有新版时不产生待提示更新', () async {
    final coordinator = StartupUpdateCoordinator(
      checkLatest: () async => _updateInfo(hasUpdate: false),
    );

    expect(await coordinator.checkOnce(), isNull);
    expect(coordinator.hasPendingUpdate, isFalse);
  });
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
    asset: null,
  );
}

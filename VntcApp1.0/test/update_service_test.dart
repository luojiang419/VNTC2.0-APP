import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/update/update_service.dart';

void main() {
  group('AppUpdateService version parsing', () {
    test('normalizes tag names and compares semantic versions', () {
      expect(normalizeVersionString('refs/tags/v2.0.1+12'), '2.0.1');
      expect(compareVersionStrings('v2.0.1', '2.0.0'), greaterThan(0));
      expect(compareVersionStrings('2.0.0', '2.0.0'), 0);
      expect(compareVersionStrings('2.0.0-test.1', '2.0.0'), lessThan(0));
    });
  });

  group('AppUpdateService asset selection', () {
    test('selects platform specific installer assets', () {
      final assets = [
        _asset('VNT_App_2.0.1_Windows_Setup.exe'),
        _asset('vntApp-android.apk'),
        _asset('VNT_App_2.0.1_macOS.dmg'),
        _asset('vntApp-linux-x86_64.AppImage'),
      ];

      expect(
        selectBestUpdateAsset(assets, AppUpdatePlatform.android)?.name,
        'vntApp-android.apk',
      );
      expect(
        selectBestUpdateAsset(assets, AppUpdatePlatform.windows)?.name,
        'VNT_App_2.0.1_Windows_Setup.exe',
      );
      expect(
        selectBestUpdateAsset(assets, AppUpdatePlatform.macos)?.name,
        'VNT_App_2.0.1_macOS.dmg',
      );
      expect(
        selectBestUpdateAsset(assets, AppUpdatePlatform.linux)?.name,
        'vntApp-linux-x86_64.AppImage',
      );
      expect(selectBestUpdateAsset(assets, AppUpdatePlatform.ios), isNull);
    });

    test('parses GitHub release and marks update availability', () {
      final info = parseGitHubRelease(
        {
          'tag_name': 'v2.0.1-test.1',
          'name': 'VNTC APP v2.0.1-test.1',
          'body': '测试更新',
          'html_url':
              'https://github.com/luojiang419/VNTC2.0-APP/releases/tag/v2.0.1-test.1',
          'assets': [
            {
              'name': 'vntApp-android.apk',
              'browser_download_url':
                  'https://github.com/example/repo/releases/download/v2.0.1-test.1/vntApp-android.apk',
              'size': 10,
            },
          ],
        },
        currentVersion: '2.0.0',
        platform: AppUpdatePlatform.android,
        proxyLabel: '本机代理 127.0.0.1:7890',
      );

      expect(info.hasUpdate, isTrue);
      expect(info.latestVersion, '2.0.1-test.1');
      expect(info.asset?.name, 'vntApp-android.apk');
      expect(info.proxyLabel, '本机代理 127.0.0.1:7890');
    });
  });

  group('AppUpdateProxyResolver', () {
    test('parses common proxy formats', () {
      expect(
        AppUpdateProxyResolver.parseProxyValue(
          'http=127.0.0.1:7890;https=192.168.1.2:7890',
          'Windows 系统代理',
        )?.config,
        'PROXY 192.168.1.2:7890',
      );
      expect(
        AppUpdateProxyResolver.parseProxyValue(
          'socks5://127.0.0.1:7890',
          '环境代理',
        )?.config,
        'SOCKS 127.0.0.1:7890',
      );
      expect(
        AppUpdateProxyResolver.parseProxyValue('DIRECT', '环境代理'),
        isNull,
      );
    });
  });
}

AppUpdateAsset _asset(String name) {
  return AppUpdateAsset(
    name: name,
    downloadUrl: Uri.parse('https://example.com/$name'),
    size: 1,
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/update/app_update_config.dart';
import 'package:vnt_app/update/update_service.dart';

Map<String, dynamic> manifest(String version) => {
      'schema_version': 1,
      'product': 'vntc-app',
      'channel': 'stable',
      'tag_name': 'v$version',
      'name': 'VNT Client v$version',
      'html_url':
          'https://modelscope.cn/models/${AppUpdateConfig.modelScopeRepository}',
      'assets': [
        for (final name in [
          'VNT_App_${version}_Windows_Setup.exe',
          'VNT_App_${version}_macOS.dmg',
          'VNT_App_${version}_Android_arm64.apk',
          'VNTC_Linux_WebUI_${version}_ubuntu24.04_x86_64.tar.gz'
        ])
          {
            'name': name,
            'size': 123,
            'sha256': 'a' * 64,
            'browser_download_url':
                'https://modelscope.cn/models/${AppUpdateConfig.modelScopeRepository}/resolve/master/releases/v$version/$name'
          },
      ],
    };
void main() {
  test('默认仅使用魔搭更新源', () {
    expect(AppUpdateConfig.latestReleaseApiUrl,
        'https://modelscope.cn/models/jiangjiang419/vntc-app-updates/resolve/master/latest.json');
  });
  test('过渡版后四平台均从魔搭选取下一版本并校验摘要', () {
    for (final platform in [
      AppUpdatePlatform.windows,
      AppUpdatePlatform.macos,
      AppUpdatePlatform.android,
      AppUpdatePlatform.linux
    ]) {
      final info = parseModelScopeRelease(manifest('4.8.43'),
          currentVersion: '4.8.42', platform: platform);
      expect(info.hasUpdate, isTrue);
      expect(info.asset, isNotNull);
      expect(info.asset!.sha256, 'a' * 64);
      expect(info.asset!.downloadUrl.host, 'modelscope.cn');
    }
    expect(
        parseModelScopeRelease(manifest('4.8.42'),
                currentVersion: '4.8.42', platform: AppUpdatePlatform.windows)
            .hasUpdate,
        isFalse);
  });
  test('拒绝以旧版本安装包代替新版本', () {
    final data = manifest('4.8.42');
    final assets = data['assets'] as List;
    assets.first['name'] = 'VNT_App_4.8.41_Windows_Setup.exe';
    assets.first['browser_download_url'] =
        'https://modelscope.cn/models/${AppUpdateConfig.modelScopeRepository}/resolve/master/releases/v4.8.42/VNT_App_4.8.41_Windows_Setup.exe';
    expect(
        () => parseModelScopeRelease(data,
            currentVersion: '4.8.40', platform: AppUpdatePlatform.windows),
        throwsFormatException);
  });

  test('拒绝错误产品、渠道、重复资产、缺失摘要和跨仓库地址', () {
    void reject(Map<String, dynamic> data) => expect(
        () => parseModelScopeRelease(data,
            currentVersion: '4.8.41', platform: AppUpdatePlatform.windows),
        throwsFormatException);
    reject(manifest('4.8.42')..['product'] = 'other');
    reject(manifest('4.8.42')..['channel'] = 'beta');
    reject(manifest('4.8.42')..['tag_name'] = 'v4.8.42-beta');
    final duplicate = manifest('4.8.42');
    (duplicate['assets'] as List).add((duplicate['assets'] as List).first);
    reject(duplicate);
    for (final change in [
      {'sha256': ''},
      {'size': 0},
      {'browser_download_url': 'https://example.com/installer.exe'},
      {
        'browser_download_url':
            'https://modelscope.cn/models/another/repo/resolve/master/installer.exe'
      },
    ]) {
      final data = manifest('4.8.42');
      (data['assets'] as List).first.addAll(change);
      reject(data);
    }
  });
}

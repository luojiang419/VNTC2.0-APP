import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/update/update_session.dart';

void main() {
  group('AppUpdateService version parsing', () {
    test('normalizes tag names and compares semantic versions', () {
      expect(normalizeVersionString('refs/tags/v2.0.1+12'), '2.0.1');
      expect(compareVersionStrings('v2.0.1', '2.0.0'), greaterThan(0));
      expect(compareVersionStrings('2.0.0', '2.0.0'), 0);
      expect(compareVersionStrings('3.2.0', 'v3.2'), 0);
      expect(compareVersionStrings('2.0.0-test.1', '2.0.0'), lessThan(0));
      expect(compareVersionStrings('2.0.0-test.2', '2.0.0-test.1'),
          greaterThan(0));
      expect(compareVersionStrings('2.0.0-beta.1', '2.0.0-alpha.9'),
          greaterThan(0));
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

    test('prefers exact Windows setup asset for release version', () {
      final assets = [
        _asset('VNT_App_2.0.0_Windows_Setup.exe'),
        _asset('VNT_App_2.0.1_Windows_Portable.zip'),
        _asset('VNT_App_2.0.1_Windows_Setup.exe'),
      ];

      expect(
        selectBestUpdateAsset(
          assets,
          AppUpdatePlatform.windows,
          version: 'v2.0.1',
        )?.name,
        'VNT_App_2.0.1_Windows_Setup.exe',
      );
    });

    test('does not select MSI or ZIP for Windows silent update', () {
      final assets = [
        _asset('VNT_App_2.0.1_Windows_Portable.zip'),
        _asset('VNT_App_2.0.1_Windows.msi'),
      ];

      expect(
        selectBestUpdateAsset(
          assets,
          AppUpdatePlatform.windows,
          version: 'v2.0.1',
        ),
        isNull,
      );
    });

    test('attaches checksum asset to matching installer asset', () {
      final installer = _asset('VNT_App_2.0.1_Windows_Setup.exe');
      final checksum = _asset('VNT_App_2.0.1_Windows_Setup.sha256');

      final attached = attachChecksumAssets([installer, checksum]);
      final selected = selectBestUpdateAsset(
        attached,
        AppUpdatePlatform.windows,
        version: 'v2.0.1',
      );

      expect(selected?.name, installer.name);
      expect(selected?.checksumUrl, checksum.downloadUrl);
    });

    test('parses sha256 checksum files and validates filename', () {
      const hash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      expect(
        normalizeSha256Value('sha256:$hash'),
        hash,
      );
      expect(
        parseSha256ChecksumText(
          '${hash.toUpperCase()} *VNT_App_2.0.1_Windows_Setup.exe',
          expectedFileName: 'VNT_App_2.0.1_Windows_Setup.exe',
        ),
        hash,
      );
      expect(
        parseSha256ChecksumText(
          '$hash *other.exe',
          expectedFileName: 'VNT_App_2.0.1_Windows_Setup.exe',
        ),
        isNull,
      );
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

  group('AppUpdateService Windows installer trust', () {
    test('accepts valid signature and optional trusted publisher', () {
      expect(
        isTrustedWindowsSignature(
          status: 'Valid',
          subject: 'CN=VNTC Publisher, O=Example',
          trustedPublisher: '',
        ),
        isTrue,
      );
      expect(
        isTrustedWindowsSignature(
          status: 'Valid',
          subject: 'CN=VNTC Publisher, O=Example',
          trustedPublisher: 'VNTC Publisher',
        ),
        isTrue,
      );
    });

    test('rejects invalid signature or unexpected publisher', () {
      expect(
        isTrustedWindowsSignature(
          status: 'NotSigned',
          subject: '',
          trustedPublisher: '',
        ),
        isFalse,
      );
      expect(
        isTrustedWindowsSignature(
          status: 'Valid',
          subject: 'CN=Someone Else',
          trustedPublisher: 'VNTC Publisher',
        ),
        isFalse,
      );
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
        AppUpdateProxyResolver.parseProxyValue(
          'socks5://127.0.0.1:7890',
          '环境代理',
        )?.curlProxyUrl,
        'socks5h://127.0.0.1:7890',
      );
      expect(
        AppUpdateProxyResolver.parseProxyValue(
          '127.0.0.1:7890',
          '手动代理',
        )?.curlProxyUrl,
        'http://127.0.0.1:7890',
      );
      expect(
        AppUpdateProxyResolver.parseProxyValue('DIRECT', '环境代理'),
        isNull,
      );
    });
  });

  group('AppUpdateSession', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vnt_update_session_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('round trips updater process arguments with manifest token', () async {
      final installRoot = path.join(tempDir.path, 'install');
      final storageRoot = path.join(tempDir.path, 'updates', 'windows');
      final session = AppUpdateSession.create(
        versionTag: 'v2.0.1',
        installerPath:
            path.join(storageRoot, 'VNT_App_2.0.1_Windows_Setup.exe'),
        installRoot: installRoot,
        storageRoot: storageRoot,
        launchPath: path.join(installRoot, 'vnt_app.exe'),
      );
      await session.writeManifest();

      final parsed = AppUpdateSession.tryParse(session.toProcessArguments());

      expect(parsed, isNotNull);
      expect(parsed!.sessionId, session.sessionId);
      expect(parsed.token, session.token);
      expect(parsed.versionTag, 'v2.0.1');
      expect(parsed.installerPath, session.installerPath);
      expect(parsed.installRoot, session.installRoot);
      expect(parsed.storageRoot, session.storageRoot);
      expect(parsed.launchPath, session.launchPath);
      expect(parsed.oldPid, session.oldPid);
    });

    test('rejects incomplete updater arguments', () {
      expect(
        AppUpdateSession.tryParse(['--run-update-session=abc']),
        isNull,
      );
    });

    test('rejects updater arguments without matching manifest token', () {
      final installRoot = path.join(tempDir.path, 'install');
      final storageRoot = path.join(tempDir.path, 'updates', 'windows');
      final session = AppUpdateSession.create(
        versionTag: 'v2.0.1',
        installerPath:
            path.join(storageRoot, 'VNT_App_2.0.1_Windows_Setup.exe'),
        installRoot: installRoot,
        storageRoot: storageRoot,
        launchPath: path.join(installRoot, 'vnt_app.exe'),
      );

      expect(AppUpdateSession.tryParse(session.toProcessArguments()), isNull);
    });

    test('rejects updater arguments whose installer escapes storage root',
        () async {
      final installRoot = path.join(tempDir.path, 'install');
      final storageRoot = path.join(tempDir.path, 'updates', 'windows');
      final session = AppUpdateSession.create(
        versionTag: 'v2.0.1',
        installerPath: path.join(storageRoot, '..', 'evil.exe'),
        installRoot: installRoot,
        storageRoot: storageRoot,
        launchPath: path.join(installRoot, 'vnt_app.exe'),
      );
      await session.writeManifest();

      expect(AppUpdateSession.tryParse(session.toProcessArguments()), isNull);
    });
  });
}

AppUpdateAsset _asset(String name, {String? sha256}) {
  return AppUpdateAsset(
    name: name,
    downloadUrl: Uri.parse('https://example.com/$name'),
    size: 1,
    sha256: sha256,
  );
}

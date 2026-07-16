import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 母版声明完整品牌能力', () {
    final manifest = jsonDecode(
      File('assets/android_brand_package_manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final capabilities = (manifest['capabilities'] as List).cast<String>();

    expect(manifest['platform'], 'android');
    expect(manifest['brandReady'], isTrue);
    expect(manifest['brandId'], 'official');
    expect(manifest['version'], '4.8.22');
    expect(manifest['versionCode'], 40822);
    expect(capabilities, contains('androidRuntimeBrandingV1'));
    expect(capabilities, contains('hideAboutPage'));
    expect(capabilities, contains('removeUpdateFeature'));
    expect(capabilities, contains('launcherIconV1'));
    expect(capabilities, contains('applicationIdRewriteV1'));
  });

  test('Android 启动时从 APK 资产异步初始化品牌', () {
    final appVersion = File('lib/app_version.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(appVersion, contains('rootBundle.loadString'));
    expect(appVersion, contains('AppBranding.androidAssetPath'));
    expect(appVersion, contains('fallbackUpdateEnabled: false'));
    expect(main, contains('await AppVersion.initializeForCurrentPlatform()'));
  });

  test('Android Manifest 的品牌展示名全部使用资源', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(manifest, contains('android:label="@string/app_name"'));
    expect(
      manifest,
      contains('android:label="@string/remote_assist_input_service_name"'),
    );
    expect(
      manifest,
      contains('android:label="@string/widget_small_description"'),
    );
    expect(
      manifest,
      contains('android:label="@string/widget_large_description"'),
    );
    expect(manifest, isNot(contains('android:label="VNT')));
  });

  test('Android 官方母版启动器名称与运行时品牌名称一致', () {
    final branding = jsonDecode(
      File('assets/android_branding.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final strings = File(
      'android/app/src/main/res/values/strings.xml',
    ).readAsStringSync();

    expect(
      strings,
      contains('<string name="app_name">${branding['productName']}</string>'),
    );
  });

  test('Android 原生服务不再硬编码品牌展示名', () {
    final tile = File(
      'android/app/src/main/java/top/wherewego/vnt_app/MyTileService.java',
    ).readAsStringSync();
    final vpn = File(
      'android/app/src/main/java/top/wherewego/vnt_app/vpn/MyVpnService.java',
    ).readAsStringSync();
    final notification = File(
      'android/app/src/main/java/top/wherewego/vnt_app/VntNotificationService.java',
    ).readAsStringSync();
    final remote = File(
      'android/app/src/main/java/top/wherewego/vnt_app/RemoteAssistControlledService.java',
    ).readAsStringSync();

    expect(tile, contains('getString(R.string.app_name)'));
    expect(tile, isNot(contains('setLabel("VNT")')));
    expect(vpn, contains('R.string.app_name'));
    expect(vpn, isNot(contains('setSession("VNT")')));
    expect(notification, contains('R.string.notification_channel_name'));
    expect(notification, contains('R.string.notification_title_format'));
    expect(remote, contains('R.string.remote_assist_channel_name'));
    expect(remote, contains('R.string.remote_assist_running_description'));
  });

  test('Android 品牌母版导出会验证协议、签名和 16KB 对齐', () {
    final exporter = File(
      'scripts/export_android_brand_package.ps1',
    ).readAsStringSync();

    expect(exporter, contains('android_brand_package_manifest.json'));
    expect(exporter, contains("brandId -cne 'official'"));
    expect(exporter, contains('zipalign.exe'));
    expect(exporter, contains('-P 16'));
    expect(exporter, contains('apksigner.jar'));
    expect(exporter, contains("native-code: 'arm64-v8a'"));
  });

  test('Android RustDesk 原生库由云端重建并验证 ELF 16KB 对齐', () {
    final ndkBuild = File(
      'vntcrustdesk-src/flutter/ndk_arm64.sh',
    ).readAsStringSync();
    final appGradle = File('android/app/build.gradle').readAsStringSync();
    final verifier = File(
      'scripts/verify_android_16kb_alignment.py',
    ).readAsStringSync();
    final workflow = File(
      '../.github/workflows/build.yml',
    ).readAsStringSync();
    final rustdeskFlutterLock = File(
      'vntcrustdesk-src/flutter/pubspec.lock',
    ).readAsStringSync();

    expect(ndkBuild, contains('max-page-size=16384'));
    expect(ndkBuild, contains('common-page-size=16384'));
    expect(appGradle, contains('ndkVersion = "28.2.13676358"'));
    expect(verifier, contains('PT_LOAD = 1'));
    expect(verifier, contains('DEFAULT_MINIMUM_ALIGNMENT = 16 * 1024'));
    expect(workflow, contains('build-rustdesk-android-arm64:'));
    expect(workflow, contains('rustdesk-android-arm64-native'));
    expect(workflow, contains('RUSTDESK_FRB_CODEGEN_VERSION: 1.80.1'));
    expect(workflow, contains('rustup component add rustfmt'));
    expect(workflow, contains('flutter_rust_bridge_codegen'));
    expect(workflow, contains('flutter pub get --enforce-lockfile'));
    expect(workflow, contains('--dart-output flutter/lib/generated_bridge.dart'));
    expect(rustdeskFlutterLock, contains('version: "1.18.0"'));
    expect(
      rustdeskFlutterLock,
      contains(
        '1741988757a65eb6b36abe716829688cf01910bbf91c34354ff7ec1c3de2b349',
      ),
    );
    expect(workflow, contains('test -s src/bridge_generated.rs'));
    expect(workflow, contains('test -s src/bridge_generated.io.rs'));
    expect(workflow, contains('CargoKit 会在此步骤重编主业务'));
    expect(workflow,
        contains('RUSTFLAGS: -C link-arg=-Wl,-z,max-page-size=16384'));
    expect(workflow, contains('verify_android_16kb_alignment.py'));
  });

  test('Android 正式母版使用独立官方签名且公开信任配置不含私密信息', () {
    final gradle = File('android/app/build.gradle').readAsStringSync();
    final signing = File(
      'scripts/android_official_signing.ps1',
    ).readAsStringSync();
    final exporter = File(
      'scripts/export_android_brand_package.ps1',
    ).readAsStringSync();
    final trust = jsonDecode(
      File('config/android_official_signing_trust.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    expect(gradle, isNot(contains('signingConfig = signingConfigs.debug')));
    expect(signing, contains('RandomNumberGenerator'));
    expect(signing, contains('New-Object byte[] 48'));
    expect(signing, contains('DataProtectionScope]::CurrentUser'));
    expect(signing, contains('VNT_ANDROID_OFFICIAL_KEYSTORE_BASE64'));
    expect(
      signing,
      contains('VNT_ANDROID_OFFICIAL_KEYSTORE_PASSWORD_PLAIN'),
    );
    expect(signing, contains('RSA'));
    expect(signing, contains("'-keysize', '3072'"));
    expect(exporter, contains("'build-tools\\36.0.0'"));
    expect(exporter, contains('--v2-signing-enabled true'));
    expect(exporter, contains('--v3-signing-enabled true'));
    expect(exporter, contains('Number of signers: 1'));
    expect(exporter, contains('Publish-ApkAndHashAtomically'));

    expect(trust['schemaVersion'], 1);
    expect(trust['keyId'], 'vnt-official-android-release-v1');
    expect(trust['brandId'], 'official');
    expect(trust['applicationId'], 'top.wherewego.vnt_app');
    expect(trust['alias'], 'vnt_official_android_release_v1');
    expect(trust['certificateSha256'],
        anyOf('PENDING_BOOTSTRAP', matches(RegExp(r'^[0-9A-F]{64}$'))));
    expect(trust.keys, isNot(contains('passwordProtectedBase64')));
    expect(trust.keys, isNot(contains('keystorePath')));
  });
}

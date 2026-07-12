import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readProjectFile(String relativePath) {
  return File('${Directory.current.path}/$relativePath').readAsStringSync();
}

void main() {
  test('analyzer excludes generated build outputs', () {
    final options = _readProjectFile('analysis_options.yaml');

    expect(options, contains('- build/**'));
    expect(options, contains('- dist/**'));
    expect(options, contains('- output/**'));
  });

  test('Android FileProvider paths stay app scoped', () {
    final paths = _readProjectFile(
      'android/app/src/main/res/xml/file_paths.xml',
    );

    expect(paths, isNot(contains('<root-path')));
    expect(paths, isNot(contains('<external-path')));
    expect(paths, contains('<files-path'));
    expect(paths, contains('<cache-path'));
    expect(paths, contains('<external-files-path'));
    expect(paths, contains('<external-cache-path'));
  });

  test('MSI preprocess uses stable component GUIDs', () {
    final preprocess = _readProjectFile(
      'vntcrustdesk-src/res/msi/preprocess.py',
    );

    expect(preprocess, contains('def stable_component_guid'));
    expect(preprocess, contains('component_guid = stable_component_guid'));
    expect(preprocess, isNot(contains('<Component Guid="{uuid.uuid4()}"')));
    expect(preprocess, isNot(contains('Guid="{uuid.uuid4()}"')));
  });

  test('Windows package scripts share build version utilities', () {
    final versionUtils = _readProjectFile('scripts/build_version_utils.ps1');
    final portableScript = _readProjectFile(
      'scripts/export_portable_package.ps1',
    );
    final installerScript = _readProjectFile(
      'scripts/export_installer_package.ps1',
    );

    expect(versionUtils, contains('function Get-VntBuildVersion'));
    expect(versionUtils, contains('function Get-NextVntBuildVersion'));
    expect(portableScript, contains('build_version_utils.ps1'));
    expect(installerScript, contains('build_version_utils.ps1'));
    expect(portableScript, contains('Get-VntBuildVersion -VersionFile'));
    expect(installerScript, contains('Get-VntBuildVersion -VersionFile'));
  });

  test('Windows installer preserves user configuration during upgrades', () {
    final installerScript = _readProjectFile(
      'scripts/export_installer_package.ps1',
    );

    expect(installerScript, contains('Excludes: "config\\*"'));
  });

  test(
    'macOS remote assist keeps an isolated app identity and package path',
    () {
      final appInfo = _readProjectFile(
        'vntcrustdesk-src/flutter/macos/Runner/Configs/AppInfo.xcconfig',
      );
      final infoPlist = _readProjectFile(
        'vntcrustdesk-src/flutter/macos/Runner/Info.plist',
      );
      final buildScript = _readProjectFile(
        'scripts/build_macos_remote_assist.sh',
      );
      final upstreamBuild = _readProjectFile('vntcrustdesk-src/build.py');

      expect(appInfo, contains('PRODUCT_NAME = VNTC RustDesk'));
      expect(
        appInfo,
        contains('PRODUCT_BUNDLE_IDENTIFIER = top.wherewego.vntcRustDesk'),
      );
      expect(infoPlist, contains('<string>vntcrustdesk</string>'));
      expect(buildScript, contains('Release/VNTC RustDesk.app'));
      expect(
        upstreamBuild,
        contains('Release/VNTC RustDesk.app/Contents/MacOS/'),
      );
    },
  );

  test('desktop remote peer info requests initial display capture', () {
    final model = _readProjectFile(
      'vntcrustdesk-src/flutter/lib/models/model.dart',
    );

    expect(model, contains('_requestInitialDisplayCapture(sessionId);'));
    expect(model, contains('void _requestInitialDisplayCapture'));
    expect(model, contains('bind.sessionSwitchDisplay('));
    expect(model, contains('Int32List.fromList(displaysToCapture)'));
  });

  test('macOS main window keeps native minimize and zoom controls', () {
    final main = _readProjectFile('lib/main.dart');
    final mainWindow = _readProjectFile('macos/Runner/MainFlutterWindow.swift');

    expect(main, contains('windowManager.setMinimizable(true)'));
    expect(main, contains('windowManager.setMaximizable(true)'));
    expect(main, isNot(contains('由于 macOS 安全限制，应用无法最小化')));
    expect(mainWindow, contains('.miniaturizable'));
    expect(
      mainWindow,
      isNot(contains('standardWindowButton(.miniaturizeButton)?.isHidden')),
    );
    expect(
      mainWindow,
      isNot(contains('standardWindowButton(.zoomButton)?.isHidden')),
    );
  });

  test('macOS package script emits a filename-matched DMG SHA256 sidecar', () {
    final buildScript = _readProjectFile('scripts/export_macos_package.sh');

    expect(buildScript, contains('APP_VERSION="\$(awk'));
    expect(buildScript, contains('VNT_App_\${APP_VERSION}_macOS.dmg'));
    expect(buildScript, contains('DMG_SHA256_PATH="\$DMG_PATH.sha256"'));
    expect(buildScript, contains('shasum -a 256'));
    expect(buildScript, contains('basename "\$DMG_PATH"'));
    expect(buildScript, contains('basename "\$DMG_SHA256_PATH"'));
  });
}

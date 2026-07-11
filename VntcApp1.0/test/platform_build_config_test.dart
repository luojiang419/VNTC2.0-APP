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
}

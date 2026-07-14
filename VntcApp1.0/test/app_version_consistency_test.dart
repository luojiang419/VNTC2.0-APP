import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/app_version.dart';

void main() {
  const expectedVersion = '4.8.15';
  const expectedBuildNumber = '40815';

  test('应用默认版本与 Flutter 包版本保持一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final buildVersion = File(
      'scripts/build_version.txt',
    ).readAsStringSync().trim();

    expect(AppVersion.currentVersion, expectedVersion);
    expect(AppVersion.displayVersion, 'v$expectedVersion');
    expect(pubspec, contains('version: $expectedVersion+$expectedBuildNumber'));
    expect(buildVersion, expectedVersion);
  });

  test('macOS 安装包文件名使用当前版本', () {
    final packageScript = File(
      'scripts/export_macos_package.sh',
    ).readAsStringSync();

    expect(packageScript, contains('VNT_App_${expectedVersion}_macOS.dmg'));
    expect(packageScript, isNot(contains('VNT_App_2.0.0_macOS.dmg')));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_macos_runtime.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vnt_macos_runtime_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('locates bundled macOS runtime from main app resources', () async {
    final mainExecutable = path.join(
      tempDir.path,
      'vnt_app.app',
      'Contents',
      'MacOS',
      'vnt_app',
    );
    await File(mainExecutable).create(recursive: true);
    final runtimeApp = path.join(
      tempDir.path,
      'vnt_app.app',
      'Contents',
      'Resources',
      RemoteAssistConstants.macosBundledAppRelativePath,
    );
    final runtimeExecutable = await _createFakeApp(
      runtimeApp,
      executableName: 'vntcrustdesk',
      version: '2.0.0',
    );

    final locator = RemoteAssistMacosRuntimeLocator(
      environment: const <String, String>{},
      resolvedExecutable: mainExecutable,
      applicationsDirectory: path.join(tempDir.path, 'Applications'),
    );
    final runtime = await locator.locate();

    expect(runtime, isNotNull);
    expect(runtime!.managedInstall, isTrue);
    expect(runtime.appBundlePath, path.normalize(runtimeApp));
    expect(runtime.executablePath, path.normalize(runtimeExecutable));
    expect(runtime.version, '2.0.0');
  });

  test('environment app path takes precedence over bundled runtime', () async {
    final envApp = path.join(tempDir.path, 'Env RustDesk.app');
    final envExecutable = await _createFakeApp(
      envApp,
      executableName: 'RustDesk',
      version: '1.0.0',
    );
    final mainExecutable = path.join(
      tempDir.path,
      'vnt_app.app',
      'Contents',
      'MacOS',
      'vnt_app',
    );
    await File(mainExecutable).create(recursive: true);
    await _createFakeApp(
      path.join(
        tempDir.path,
        'vnt_app.app',
        'Contents',
        'Resources',
        RemoteAssistConstants.macosBundledAppRelativePath,
      ),
      executableName: 'vntcrustdesk',
      version: '2.0.0',
    );

    final locator = RemoteAssistMacosRuntimeLocator(
      environment: {'VNTC_RUSTDESK_APP': envApp},
      resolvedExecutable: mainExecutable,
      applicationsDirectory: path.join(tempDir.path, 'Applications'),
    );
    final runtime = await locator.locate();

    expect(runtime, isNotNull);
    expect(runtime!.managedInstall, isFalse);
    expect(runtime.appBundlePath, path.normalize(envApp));
    expect(runtime.executablePath, envExecutable);
    expect(runtime.version, '1.0.0');
  });

  test('falls back to Applications runtime and executable candidate names',
      () async {
    final applicationsDir = path.join(tempDir.path, 'Applications');
    final runtimeApp = path.join(
      applicationsDir,
      RemoteAssistConstants.macosAppBundleName,
    );
    final runtimeExecutable = await _createFakeApp(
      runtimeApp,
      executableName: 'RustDesk',
      version: '1.4.6',
      includeExecutableInPlist: false,
    );

    final locator = RemoteAssistMacosRuntimeLocator(
      environment: const <String, String>{},
      resolvedExecutable: path.join(tempDir.path, 'plain_executable'),
      applicationsDirectory: applicationsDir,
    );
    final runtime = await locator.locate();

    expect(runtime, isNotNull);
    expect(runtime!.managedInstall, isFalse);
    expect(runtime.appBundlePath, path.normalize(runtimeApp));
    expect(runtime.executablePath, runtimeExecutable);
    expect(runtime.version, '1.4.6');
  });
}

Future<String> _createFakeApp(
  String appBundlePath, {
  required String executableName,
  required String version,
  bool includeExecutableInPlist = true,
}) async {
  final contentsPath = path.join(appBundlePath, 'Contents');
  final macosPath = path.join(contentsPath, 'MacOS');
  await Directory(macosPath).create(recursive: true);
  final executablePath = path.join(macosPath, executableName);
  await File(executablePath).writeAsString('#!/bin/sh\n');
  final executableKey = includeExecutableInPlist
      ? '<key>CFBundleExecutable</key><string>$executableName</string>'
      : '';
  await File(path.join(contentsPath, 'Info.plist')).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
$executableKey
<key>CFBundleShortVersionString</key><string>$version</string>
</dict>
</plist>
''');
  return executablePath;
}

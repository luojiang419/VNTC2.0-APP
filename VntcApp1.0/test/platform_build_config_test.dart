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

  test('Android chat attachments open through FileProvider', () {
    final manifest =
        _readProjectFile('android/app/src/main/AndroidManifest.xml');
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );
    final chatPage = _readProjectFile('lib/pages/chat_page.dart');

    expect(manifest, contains(r'${applicationId}.fileprovider'));
    expect(activity, contains('call.method.equals("openAttachment")'));
    expect(activity, contains('FileProvider.getUriForFile('));
    expect(activity, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(activity, contains('openIntent.setDataAndType('));
    expect(chatPage, contains('ChatAttachmentOpener.openAndroidAttachment('));
    expect(
        chatPage, isNot(contains('launchUrl(\n          Uri.file(filePath)')));
  });

  test('Android chat attachments save through the SAF streaming channel', () {
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );
    final chatPage = _readProjectFile('lib/pages/chat_page.dart');

    expect(chatPage, contains("import 'package:vnt_app/file_saver.dart';"));
    expect(
      RegExp(
        r'if \(Platform\.isAndroid\) \{[\s\S]*?FileSaver\.copyFile\([\s\S]*?mimeType: attachment\.mimeType,[\s\S]*?return;[\s\S]*?\}\s+final savePath = await FilePicker\.platform\.saveFile',
      ).hasMatch(chatPage),
      isTrue,
    );
    expect(chatPage, isNot(contains('bytes: await sourceFile.readAsBytes()')));
    expect(activity, contains('Intent.ACTION_CREATE_DOCUMENT'));
    expect(activity, contains('copyFileToUri(pendingFilePath, uri)'));
    expect(
      activity,
      contains('while ((length = inputStream.read(buffer)) > 0)'),
    );
    expect(activity, contains('outputStream.write(buffer, 0, length)'));
  });

  test('Windows chat attachments stay on the shared streaming fast path', () {
    final manager = _readProjectFile('lib/chat/chat_manager.dart');
    final transport = _readProjectFile(
      'lib/chat/chat_transport_service.dart',
    );
    final chatPage = _readProjectFile('lib/pages/chat_page.dart');

    expect(manager, contains('isWindows: Platform.isWindows'));
    expect(
      manager,
      contains(
          'sourceFactory: (startOffset) => sourceFile.openRead(startOffset)'),
    );
    expect(transport, contains('await socket.addStream(source)'));
    expect(manager, contains('_sink!.add(bytes)'));
    expect(manager, isNot(contains('_sink!.flush()')));
    expect(chatPage, contains('withData: false'));
    expect(chatPage, contains('await sourceFile.copy(savePath)'));
    expect(chatPage, isNot(contains('await sourceFile.readAsBytes()')));
  });

  test('Android dataSync foreground service declares its scoped permission',
      () {
    final manifest =
        _readProjectFile('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
    );
    expect(manifest, contains('android:foregroundServiceType="dataSync"'));
  });

  test('Android updater resumes APK install after unknown-source approval', () {
    final manifest =
        _readProjectFile('android/app/src/main/AndroidManifest.xml');
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );

    expect(
      manifest,
      contains('android.permission.REQUEST_INSTALL_PACKAGES'),
    );
    expect(activity, contains('APK_INSTALL_PERMISSION_REQUEST_CODE'));
    expect(activity, contains('ACTION_MANAGE_UNKNOWN_APP_SOURCES'));
    expect(activity, contains('startActivityForResult(settingsIntent'));
    expect(activity, contains('pendingInstallApkPath'));
    expect(activity, contains('pendingInstallResult'));
    expect(activity, contains('protected void onResume()'));
    expect(activity, contains('resumePendingApkInstall();'));
    expect(activity, contains('canRequestPackageInstalls()'));
    expect(activity, contains('INSTALL_PERMISSION_DENIED'));
  });

  test('Android release wires the complete RustDesk controlled host', () {
    final manifest =
        _readProjectFile('android/app/src/main/AndroidManifest.xml');
    final buildConfig = _readProjectFile('android/app/build.gradle');
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );

    expect(manifest, contains('com.carriez.flutter_hbb.MainApplication'));
    expect(manifest, contains('com.carriez.flutter_hbb.MainService'));
    expect(manifest, contains('com.carriez.flutter_hbb.InputService'));
    expect(
      manifest,
      contains('com.carriez.flutter_hbb.PermissionRequestTransparentActivity'),
    );
    expect(
      buildConfig,
      contains('vntcrustdesk-src/flutter/android/app/src/main/kotlin'),
    );
    expect(buildConfig, contains('abiFilters "arm64-v8a"'));
    expect(buildConfig, contains("'lib/armeabi-v7a/**'"));
    expect(buildConfig, contains("'lib/x86_64/**'"));
    expect(activity,
        contains('new RemoteAssistAndroidBridge(this, flutterEngine)'));
    final remoteBridge = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/RemoteAssistAndroidBridge.java',
    );
    expect(remoteBridge, contains('new ZipFile(apkPath)'));
    expect(remoteBridge, contains('splitSourceDirs'));
    expect(remoteBridge, contains('"/librustdesk.so"'));
  });

  test('Android input service state is synchronized from the live service', () {
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );
    final remoteBridge = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/RemoteAssistAndroidBridge.java',
    );
    final adapter = _readProjectFile(
      'lib/remote_assist/remote_assist_android_adapter.dart',
    );
    final runtime = _readProjectFile(
      'lib/remote_assist/remote_assist_android_runtime.dart',
    );

    expect(
      activity,
      contains('notifyRustdeskStateChange("input", isRustdeskInputEnabled())'),
    );
    expect(
      RegExp(
        r'private boolean isRustdeskInputEnabled\(\) \{\s*return com\.carriez\.flutter_hbb\.InputService\.Companion\.isOpen\(\);\s*\}',
      ).hasMatch(activity),
      isTrue,
    );
    expect(
      RegExp(
        r'protected void onResume\(\) \{\s*super\.onResume\(\);\s*notifyRustdeskServiceState\(\);',
      ).hasMatch(activity),
      isTrue,
    );
    expect(remoteBridge, contains('activity.refreshRustdeskServiceState();'));
    expect(
      RegExp(
        r'private boolean isAccessibilityConnected\(\) \{\s*return com\.carriez\.flutter_hbb\.InputService\.Companion\.isOpen\(\);\s*\}',
      ).hasMatch(remoteBridge),
      isTrue,
    );
    expect(remoteBridge, contains('status.put("accessibilitySettingEnabled",'));
    expect(adapter, contains('await _runtime.refreshState();'));
    expect(
      runtime,
      contains("await hbb_common.gFFI.invokeMethod('check_service');"),
    );
  });

  test('Android chat declares and requests local network permission', () {
    final manifest =
        _readProjectFile('android/app/src/main/AndroidManifest.xml');
    final activity = _readProjectFile(
      'android/app/src/main/java/top/wherewego/vnt_app/MainActivity.java',
    );

    expect(manifest, contains('android.permission.NEARBY_WIFI_DEVICES'));
    expect(manifest, contains('android.permission.ACCESS_LOCAL_NETWORK'));
    expect(activity, contains('top.wherewego.vnt/chat_android'));
    expect(activity, contains('requestLocalNetworkPermission'));
    expect(activity, contains('CHAT_LOCAL_NETWORK_PERMISSION_REQUEST_CODE'));
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
    expect(versionUtils, contains("-match '^(\\d+)\\.(\\d+)\\.(\\d+)\$'"));
    expect(portableScript, contains('build_version_utils.ps1'));
    expect(installerScript, contains('build_version_utils.ps1'));
    expect(portableScript, contains('Get-VntBuildVersion -VersionFile'));
    expect(installerScript, contains('Get-VntBuildVersion -VersionFile'));
    final windowsBuildScript = _readProjectFile('scripts/build_windows.bat');
    expect(windowsBuildScript, contains('tokens=1-4 delims=.'));
  });

  test('Windows installer preserves user configuration during upgrades', () {
    final installerScript = _readProjectFile(
      'scripts/export_installer_package.ps1',
    );

    expect(installerScript, contains('Excludes: "config\\*"'));
  });
}

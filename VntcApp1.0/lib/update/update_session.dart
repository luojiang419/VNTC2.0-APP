import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:vnt_app/update/app_update_config.dart';

class AppUpdateSession {
  const AppUpdateSession({
    required this.sessionId,
    required this.token,
    required this.versionTag,
    required this.installerPath,
    required this.installRoot,
    required this.oldPid,
    required this.storageRoot,
    required this.launchPath,
  });

  final String sessionId;
  final String token;
  final String versionTag;
  final String installerPath;
  final String installRoot;
  final int oldPid;
  final String storageRoot;
  final String launchPath;

  static AppUpdateSession? tryParse(List<String> args) {
    final values = <String, String>{};
    for (final arg in args) {
      if (!arg.startsWith('--')) {
        continue;
      }
      final withoutPrefix = arg.substring(2);
      final separator = withoutPrefix.indexOf('=');
      if (separator <= 0) {
        values[withoutPrefix] = '';
        continue;
      }
      values[withoutPrefix.substring(0, separator)] =
          withoutPrefix.substring(separator + 1);
    }

    final sessionId = values[AppUpdateConfig.runUpdateSessionArg];
    final token = values[AppUpdateConfig.updateTokenArg];
    final versionTag = values[AppUpdateConfig.updateVersionArg];
    final installerPath = values[AppUpdateConfig.updateInstallerArg];
    final installRoot = values[AppUpdateConfig.updateInstallRootArg];
    final storageRoot = values[AppUpdateConfig.updateStorageRootArg];
    final launchPath = values[AppUpdateConfig.updateLaunchPathArg];
    final oldPid = int.tryParse(values[AppUpdateConfig.updateOldPidArg] ?? '');

    if (sessionId == null ||
        sessionId.isEmpty ||
        token == null ||
        token.isEmpty ||
        versionTag == null ||
        versionTag.isEmpty ||
        installerPath == null ||
        installerPath.isEmpty ||
        installRoot == null ||
        installRoot.isEmpty ||
        storageRoot == null ||
        storageRoot.isEmpty ||
        launchPath == null ||
        launchPath.isEmpty ||
        oldPid == null) {
      return null;
    }

    final session = AppUpdateSession(
      sessionId: sessionId,
      token: token,
      versionTag: versionTag,
      installerPath: installerPath,
      installRoot: installRoot,
      oldPid: oldPid,
      storageRoot: storageRoot,
      launchPath: launchPath,
    );
    if (!session._isValidForLaunch()) {
      return null;
    }
    return session;
  }

  factory AppUpdateSession.create({
    required String versionTag,
    required String installerPath,
    required String installRoot,
    required String storageRoot,
    required String launchPath,
  }) {
    final now = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .padRight(17, '0')
        .substring(0, 17);
    return AppUpdateSession(
      sessionId: now,
      token: _createToken(),
      versionTag: versionTag,
      installerPath: installerPath,
      installRoot: installRoot,
      oldPid: pid,
      storageRoot: storageRoot,
      launchPath: launchPath,
    );
  }

  List<String> toProcessArguments() {
    return [
      '--${AppUpdateConfig.runUpdateSessionArg}=$sessionId',
      '--${AppUpdateConfig.updateTokenArg}=$token',
      '--${AppUpdateConfig.updateVersionArg}=$versionTag',
      '--${AppUpdateConfig.updateInstallerArg}=$installerPath',
      '--${AppUpdateConfig.updateInstallRootArg}=$installRoot',
      '--${AppUpdateConfig.updateOldPidArg}=$oldPid',
      '--${AppUpdateConfig.updateStorageRootArg}=$storageRoot',
      '--${AppUpdateConfig.updateLaunchPathArg}=$launchPath',
    ];
  }

  Future<void> writeManifest() async {
    final file = _manifestFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'sessionId': sessionId,
        'token': token,
        'versionTag': versionTag,
        'installerPath': installerPath,
        'installRoot': installRoot,
        'oldPid': oldPid,
        'storageRoot': storageRoot,
        'launchPath': launchPath,
      }),
      flush: true,
    );
  }

  bool _isValidForLaunch() {
    if (!_isSafeId(sessionId) || !_isSafeToken(token) || oldPid < 0) {
      return false;
    }
    if (!_isAbsolutePath(installerPath) ||
        !_isAbsolutePath(installRoot) ||
        !_isAbsolutePath(storageRoot) ||
        !_isAbsolutePath(launchPath)) {
      return false;
    }
    if (!_isPathInsideOrSame(installerPath, storageRoot) ||
        !_isPathInsideOrSame(launchPath, installRoot)) {
      return false;
    }

    final manifestFile = _manifestFile();
    if (!manifestFile.existsSync() ||
        !_isPathInsideOrSame(manifestFile.path, storageRoot)) {
      return false;
    }
    try {
      final decoded = jsonDecode(manifestFile.readAsStringSync());
      if (decoded is! Map) {
        return false;
      }
      return decoded['sessionId'] == sessionId &&
          decoded['token'] == token &&
          decoded['versionTag'] == versionTag &&
          _samePath(
              decoded['installerPath']?.toString() ?? '', installerPath) &&
          _samePath(decoded['installRoot']?.toString() ?? '', installRoot) &&
          _samePath(decoded['storageRoot']?.toString() ?? '', storageRoot) &&
          _samePath(decoded['launchPath']?.toString() ?? '', launchPath) &&
          int.tryParse('${decoded['oldPid']}') == oldPid;
    } catch (_) {
      return false;
    }
  }

  File _manifestFile() {
    return File(
      path.join(
        storageRoot,
        'sessions',
        sessionId,
        AppUpdateConfig.updateSessionManifestFileName,
      ),
    );
  }

  static bool _isSafeId(String value) {
    return RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(value);
  }

  static bool _isSafeToken(String value) {
    return RegExp(r'^[A-Fa-f0-9]{32,128}$').hasMatch(value);
  }

  static bool _isAbsolutePath(String value) {
    final trimmed = value.trim();
    return trimmed.isNotEmpty &&
        (path.isAbsolute(trimmed) ||
            path.windows.isAbsolute(trimmed) ||
            path.posix.isAbsolute(trimmed));
  }

  static bool _isPathInsideOrSame(String child, String parent) {
    final childPath = _normalizePath(child);
    final parentPath = _normalizePath(parent);
    return childPath == parentPath || path.isWithin(parentPath, childPath);
  }

  static bool _samePath(String left, String right) {
    return _normalizePath(left) == _normalizePath(right);
  }

  static String _normalizePath(String value) {
    return path.canonicalize(path.absolute(value));
  }

  static String _createToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

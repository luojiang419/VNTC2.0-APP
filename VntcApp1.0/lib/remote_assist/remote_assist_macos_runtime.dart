import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

class RemoteAssistMacosRuntimeInfo {
  const RemoteAssistMacosRuntimeInfo({
    required this.appBundlePath,
    required this.executablePath,
    required this.version,
    required this.managedInstall,
  });

  final String appBundlePath;
  final String executablePath;
  final String version;
  final bool managedInstall;
}

class RemoteAssistMacosRuntimeLocator {
  const RemoteAssistMacosRuntimeLocator({
    Map<String, String>? environment,
    String? resolvedExecutable,
    String applicationsDirectory = '/Applications',
  })  : _environment = environment,
        _resolvedExecutable = resolvedExecutable,
        _applicationsDirectory = applicationsDirectory;

  final Map<String, String>? _environment;
  final String? _resolvedExecutable;
  final String _applicationsDirectory;

  Future<RemoteAssistMacosRuntimeInfo?> locate() async {
    for (final candidate in _candidateAppBundles()) {
      final info = await _resolveCandidate(candidate);
      if (info != null) {
        return info;
      }
    }
    return null;
  }

  List<_MacosRuntimeCandidate> _candidateAppBundles() {
    final environment = _environment ?? Platform.environment;
    final result = <_MacosRuntimeCandidate>[];

    final envApp = environment['VNTC_RUSTDESK_APP']?.trim();
    if (envApp != null && envApp.isNotEmpty) {
      result.add(
        _MacosRuntimeCandidate(
          appBundlePath: envApp,
          managedInstall: false,
        ),
      );
    }

    final executablePath = _resolvedExecutable ?? Platform.resolvedExecutable;
    result.add(
      _MacosRuntimeCandidate(
        appBundlePath: RuntimeStoragePaths.resolveBundledPathForExecutable(
          executablePath: executablePath,
          relativePath: RemoteAssistConstants.macosBundledAppRelativePath,
          isMacOS: true,
        ),
        managedInstall: true,
      ),
    );

    result.add(
      _MacosRuntimeCandidate(
        appBundlePath: path.join(
          _applicationsDirectory,
          RemoteAssistConstants.macosAppBundleName,
        ),
        managedInstall: false,
      ),
    );

    final seen = <String>{};
    return result.where((candidate) {
      final normalized = path.normalize(candidate.appBundlePath);
      if (seen.contains(normalized)) {
        return false;
      }
      seen.add(normalized);
      return true;
    }).toList(growable: false);
  }

  Future<RemoteAssistMacosRuntimeInfo?> _resolveCandidate(
    _MacosRuntimeCandidate candidate,
  ) async {
    final appBundlePath = path.normalize(candidate.appBundlePath);
    final appBundle = Directory(appBundlePath);
    if (!await appBundle.exists()) {
      return null;
    }

    final executablePath = await _resolveExecutablePath(appBundlePath);
    if (executablePath == null) {
      return null;
    }

    return RemoteAssistMacosRuntimeInfo(
      appBundlePath: appBundlePath,
      executablePath: executablePath,
      version: await _resolveVersion(appBundlePath),
      managedInstall: candidate.managedInstall,
    );
  }

  Future<String?> _resolveExecutablePath(String appBundlePath) async {
    final contentsPath = path.join(appBundlePath, 'Contents');
    final macosPath = path.join(contentsPath, 'MacOS');
    final infoPlistPath = path.join(contentsPath, 'Info.plist');
    final plistExecutableName = await _readPlistString(
      infoPlistPath,
      'CFBundleExecutable',
    );
    final executableNames = <String>[
      if (plistExecutableName != null && plistExecutableName.trim().isNotEmpty)
        plistExecutableName.trim(),
      'vntcrustdesk',
      'rustdesk',
      'RustDesk',
    ];
    final existingExecutableNames = <String>{};
    final macosDirectory = Directory(macosPath);
    if (await macosDirectory.exists()) {
      await for (final entity in macosDirectory.list(followLinks: false)) {
        if (entity is File) {
          existingExecutableNames.add(path.basename(entity.path));
        }
      }
    }

    for (final executableName in executableNames.toSet()) {
      if (!existingExecutableNames.contains(executableName)) {
        continue;
      }
      final candidate = path.join(macosPath, executableName);
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  Future<String> _resolveVersion(String appBundlePath) async {
    final version = await _readPlistString(
      path.join(appBundlePath, 'Contents', 'Info.plist'),
      'CFBundleShortVersionString',
    );
    return version?.trim() ?? '';
  }

  Future<String?> _readPlistString(String plistPath, String key) async {
    final file = File(plistPath);
    if (!await file.exists()) {
      return null;
    }

    final content = await file.readAsString();
    final match = RegExp(
      '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]*)</string>',
      multiLine: true,
    ).firstMatch(content);
    final value = match?.group(1);
    if (value == null) {
      return null;
    }
    return _decodeXmlEntities(value);
  }

  String _decodeXmlEntities(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }
}

class _MacosRuntimeCandidate {
  const _MacosRuntimeCandidate({
    required this.appBundlePath,
    required this.managedInstall,
  });

  final String appBundlePath;
  final bool managedInstall;
}

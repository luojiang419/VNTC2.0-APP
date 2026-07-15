import 'dart:io';

import 'package:vnt_app/app_version.dart';

typedef StartupProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class WindowsStartupManager {
  WindowsStartupManager({StartupProcessRunner? processRunner})
      : _processRunner = processRunner ?? _runProcess;

  static const String registryPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static String get registryValueName => AppVersion.productName;
  static const String legacyTaskName = 'VNTAppStartup';

  final StartupProcessRunner _processRunner;

  Future<bool> isEnabled(String executablePath) async {
    final result = await _processRunner(
      'reg.exe',
      <String>['query', registryPath, '/v', registryValueName],
    );
    if (result.exitCode != 0) {
      return false;
    }
    return result.stdout
        .toString()
        .toLowerCase()
        .contains(executablePath.toLowerCase());
  }

  Future<void> setEnabled({
    required bool enabled,
    required String executablePath,
    required bool silentStart,
  }) async {
    await _removeLegacyScheduledTask();
    final result = enabled
        ? await _processRunner(
            'reg.exe',
            <String>[
              'add',
              registryPath,
              '/v',
              registryValueName,
              '/t',
              'REG_SZ',
              '/d',
              '"$executablePath"${silentStart ? ' --silent' : ''}',
              '/f',
            ],
          )
        : await _processRunner(
            'reg.exe',
            <String>[
              'delete',
              registryPath,
              '/v',
              registryValueName,
              '/f',
            ],
          );
    if (result.exitCode != 0 && (enabled || result.exitCode != 1)) {
      final error = result.stderr.toString().trim();
      throw StateError(error.isEmpty ? '开机自启设置失败' : error);
    }
  }

  Future<void> _removeLegacyScheduledTask() async {
    await _processRunner(
      'schtasks.exe',
      <String>['/Delete', '/TN', legacyTaskName, '/F'],
    );
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments, runInShell: false);
  }
}

import 'dart:io';

import 'desktop_behavior.dart';

class StartupProcessResult {
  const StartupProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef StartupProcessRunner =
    Future<StartupProcessResult> Function(List<String> arguments);

class WindowsStartupException implements Exception {
  const WindowsStartupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WindowsStartupManager {
  WindowsStartupManager({String? executablePath, StartupProcessRunner? runner})
    : executablePath = executablePath ?? Platform.resolvedExecutable,
      _runner = runner ?? _runSchtasks;

  static const taskName = 'VNTS2-Console-Autostart';

  final String executablePath;
  final StartupProcessRunner _runner;

  Future<void> apply(AppStartupBehavior behavior) async {
    if (behavior == AppStartupBehavior.disabled) {
      final query = await _runner(queryArguments());
      if (query.exitCode == 0) {
        final result = await _runner(deleteArguments());
        _requireSuccess(result, '删除开机自启计划任务');
      }
      return;
    }

    final result = await _runner(createArguments(behavior, executablePath));
    _requireSuccess(result, '保存开机自启计划任务');
  }

  static List<String> queryArguments() => const ['/Query', '/TN', taskName];

  static List<String> deleteArguments() => const [
    '/Delete',
    '/TN',
    taskName,
    '/F',
  ];

  static List<String> createArguments(
    AppStartupBehavior behavior,
    String executablePath,
  ) {
    if (behavior == AppStartupBehavior.disabled) {
      throw ArgumentError.value(behavior, 'behavior', '关闭自启不应创建计划任务');
    }
    return [
      '/Create',
      '/TN',
      taskName,
      '/SC',
      'ONLOGON',
      '/RL',
      'HIGHEST',
      '/F',
      '/TR',
      taskCommand(behavior, executablePath),
    ];
  }

  static String taskCommand(
    AppStartupBehavior behavior,
    String executablePath,
  ) {
    final executable = File(executablePath).absolute.path;
    final suffix = behavior == AppStartupBehavior.silentToTray
        ? ' --silent'
        : '';
    return '"$executable"$suffix';
  }

  static void _requireSuccess(StartupProcessResult result, String operation) {
    if (result.exitCode == 0) return;
    final details = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim();
    throw WindowsStartupException(
      '$operation失败（退出码 ${result.exitCode}）'
      '${details.isEmpty ? '' : '：${_limit(details)}'}',
    );
  }

  static String _limit(String value) =>
      value.length <= 1000 ? value : '${value.substring(0, 1000)}…';

  static Future<StartupProcessResult> _runSchtasks(
    List<String> arguments,
  ) async {
    if (!Platform.isWindows) {
      throw const WindowsStartupException('开机自启设置仅支持 Windows');
    }
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || systemRoot.isEmpty) {
      throw const WindowsStartupException('无法定位 Windows 系统目录');
    }
    final executable =
        '$systemRoot${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}schtasks.exe';
    final result = await Process.run(
      executable,
      arguments,
      runInShell: false,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    return StartupProcessResult(
      exitCode: result.exitCode,
      stdout: _asText(result.stdout),
      stderr: _asText(result.stderr),
    );
  }

  static String _asText(Object? value) {
    if (value is String) return value;
    if (value is List<int>) return systemEncoding.decode(value);
    return value?.toString() ?? '';
  }
}

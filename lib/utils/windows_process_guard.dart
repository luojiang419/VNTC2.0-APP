import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class WindowsProcessInfo {
  const WindowsProcessInfo({
    required this.pid,
    required this.executablePath,
  });

  final int pid;
  final String executablePath;
}

class WindowsProcessGuardResult {
  const WindowsProcessGuardResult({
    this.scannedProcesses = const [],
    this.terminatedPids = const [],
    this.failedPids = const [],
    this.errorMessage,
  });

  final List<WindowsProcessInfo> scannedProcesses;
  final List<int> terminatedPids;
  final List<int> failedPids;
  final String? errorMessage;
}

List<WindowsProcessInfo> parseWindowsProcessList(String rawJson) {
  final trimmed = rawJson.trim();
  if (trimmed.isEmpty) {
    return const [];
  }

  final decoded = jsonDecode(trimmed);
  if (decoded is List) {
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_processFromJson)
        .whereType<WindowsProcessInfo>()
        .toList();
  }

  if (decoded is Map<String, dynamic>) {
    final process = _processFromJson(decoded);
    return process == null ? const [] : [process];
  }

  return const [];
}

List<WindowsProcessInfo> selectOldWindowsProcesses(
  Iterable<WindowsProcessInfo> processes, {
  required int currentPid,
}) {
  return processes.where((process) => process.pid != currentPid).toList();
}

Future<WindowsProcessGuardResult> terminateOldWindowsProcesses() async {
  if (!Platform.isWindows) {
    return const WindowsProcessGuardResult();
  }

  final executableName = path.windows.basename(Platform.resolvedExecutable);
  final command =
      'Get-CimInstance Win32_Process -Filter "Name=\'$executableName\'" '
      '| Select-Object ProcessId, ExecutablePath '
      '| ConvertTo-Json -Compress';

  final listResult = await Process.run(
    'powershell',
    ['-NoProfile', '-Command', command],
    runInShell: true,
  );

  if (listResult.exitCode != 0) {
    return WindowsProcessGuardResult(
      errorMessage: listResult.stderr.toString().trim(),
    );
  }

  final scannedProcesses =
      parseWindowsProcessList(listResult.stdout.toString());
  final targets = selectOldWindowsProcesses(
    scannedProcesses,
    currentPid: pid,
  );

  if (targets.isEmpty) {
    return WindowsProcessGuardResult(scannedProcesses: scannedProcesses);
  }

  final terminatedPids = <int>[];
  final failedPids = <int>[];

  for (final target in targets) {
    final killResult = await Process.run(
      'taskkill',
      ['/PID', '${target.pid}', '/T', '/F'],
      runInShell: true,
    );
    if (killResult.exitCode == 0) {
      terminatedPids.add(target.pid);
    } else {
      failedPids.add(target.pid);
    }
  }

  if (terminatedPids.isNotEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  return WindowsProcessGuardResult(
    scannedProcesses: scannedProcesses,
    terminatedPids: terminatedPids,
    failedPids: failedPids,
  );
}

WindowsProcessInfo? _processFromJson(Map<String, dynamic> json) {
  final rawPid = json['ProcessId'];
  final parsedPid = int.tryParse('$rawPid');
  if (parsedPid == null) {
    return null;
  }

  return WindowsProcessInfo(
    pid: parsedPid,
    executablePath: (json['ExecutablePath'] ?? '').toString(),
  );
}

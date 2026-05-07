import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class RustDeskHostNotReadyException implements Exception {
  const RustDeskHostNotReadyException({
    required this.listenPort,
    required this.executablePath,
    required this.attempts,
    this.companionExecutablePath,
    this.managedRootPath,
    this.managedConfigPath,
    this.managedLogPath,
    this.mirroredLogPath,
    this.lastExitCode,
    this.lastStdout,
    this.lastStderr,
  });

  final int listenPort;
  final String? executablePath;
  final String? companionExecutablePath;
  final List<String> attempts;
  final String? managedRootPath;
  final String? managedConfigPath;
  final String? managedLogPath;
  final String? mirroredLogPath;
  final int? lastExitCode;
  final String? lastStdout;
  final String? lastStderr;

  @override
  String toString() {
    final parts = <String>[
      'RustDesk host 未就绪',
      'listenPort=$listenPort',
      'bundledRuntime=${executablePath ?? '<missing>'}',
      'attempts=${attempts.isEmpty ? '<none>' : attempts.join(', ')}',
      if (companionExecutablePath != null)
        'companionRuntime=$companionExecutablePath',
      if (managedRootPath != null) 'managedRoot=$managedRootPath',
      if (managedConfigPath != null) 'managedConfig=$managedConfigPath',
      if (managedLogPath != null) 'managedLog=$managedLogPath',
      if (mirroredLogPath != null) 'mirroredLog=$mirroredLogPath',
      if (lastExitCode != null) 'lastExitCode=$lastExitCode',
      if (lastStdout != null && lastStdout!.trim().isNotEmpty)
        'lastStdout=${_singleLineSnippet(lastStdout!)}',
      if (lastStderr != null && lastStderr!.trim().isNotEmpty)
        'lastStderr=${_singleLineSnippet(lastStderr!)}',
    ];
    return parts.join(' | ');
  }
}

String _singleLineSnippet(String value, {int maxLength = 240}) {
  final compact = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.length <= maxLength) {
    return compact;
  }
  return '${compact.substring(0, maxLength)}...';
}

bool matchesWindowsListeningPort(String output, int port) {
  final portPattern = RegExp(
    '^\\s*TCP\\s+\\S+:$port\\s+\\S+\\s+LISTENING\\s+\\d+\\s*\$',
    multiLine: true,
  );
  return portPattern.hasMatch(output);
}

String upsertRustDeskOption(String content, String key, String value) {
  final lines = content.isEmpty ? <String>[] : content.split(RegExp(r'\r?\n'));
  final normalizedLine = "$key = '$value'";

  var optionsIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == '[options]') {
      optionsIndex = i;
      break;
    }
  }

  if (optionsIndex == -1) {
    if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
      lines.add('');
    }
    lines.add('[options]');
    lines.add(normalizedLine);
    return lines.join('\r\n');
  }

  var nextSectionIndex = lines.length;
  for (var i = optionsIndex + 1; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      nextSectionIndex = i;
      break;
    }
  }

  for (var i = optionsIndex + 1; i < nextSectionIndex; i++) {
    if (lines[i].trimLeft().startsWith('$key ')) {
      lines[i] = normalizedLine;
      return lines.join('\r\n');
    }
  }

  lines.insert(nextSectionIndex, normalizedLine);
  return lines.join('\r\n');
}

String removeRustDeskOption(String content, String key) {
  if (content.isEmpty) {
    return content;
  }
  final lines = content.split(RegExp(r'\r?\n'));
  var optionsIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == '[options]') {
      optionsIndex = i;
      break;
    }
  }
  if (optionsIndex == -1) {
    return content;
  }

  var nextSectionIndex = lines.length;
  for (var i = optionsIndex + 1; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      nextSectionIndex = i;
      break;
    }
  }

  final updated = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > optionsIndex &&
        i < nextSectionIndex &&
        lines[i].trimLeft().startsWith('$key ')) {
      continue;
    }
    updated.add(lines[i]);
  }
  return updated.join('\r\n');
}

class RustDeskRuntime {
  RustDeskRuntime._();

  static final RustDeskRuntime instance = RustDeskRuntime._();

  static const String runtimeDirectoryName = 'rustdesk_runtime';
  static const String executableName = 'rustdesk.exe';
  static const String companionExecutableName = 'rustdesk_qs.exe';
  static const String runtimeVersionFileName = 'runtime-version.txt';
  static const String managedRootDirectoryName = 'VntcApp1.0';
  static const String managedRuntimeDirectoryName = 'rustdesk-managed';
  static const String managedHostPidFileName = 'host.pid';
  static const String legacyManagedCompanionPidFileName = 'companion.pid';
  static const Duration _hostAttemptTimeout = Duration(seconds: 5);
  static const Duration _hostProbeInterval = Duration(milliseconds: 500);
  static const List<List<String>> _hostStartArgSets = [
    ['--server'],
    ['--tray'],
  ];

  @visibleForTesting
  Future<String?> Function()? debugLocateExecutablePath;

  @visibleForTesting
  Future<String?> Function()? debugLocateInstalledExecutablePath;

  @visibleForTesting
  Future<void> Function(
    String executablePath,
    List<String> arguments,
    String workingDirectory,
  )? debugStartProcess;

  @visibleForTesting
  Future<ProcessResult> Function(
    String executablePath,
    List<String> arguments,
    String workingDirectory,
  )? debugRunProcess;

  @visibleForTesting
  Future<bool> Function(int port)? debugIsLocalPortListening;

  @visibleForTesting
  Future<void> Function(Duration duration)? debugSleep;

  @visibleForTesting
  Future<void> Function(int listenPort)? debugEnsureDirectAccessConfig;

  @visibleForTesting
  Future<String> Function()? debugManagedRootPath;

  @visibleForTesting
  Future<Map<String, String>> Function()? debugManagedEnvironment;

  Process? _managedHostProcess;
  String? _lastHostLaunchCommand;
  String? _lastHostLaunchMode;
  String? _lastHostLogPath;
  String? _lastHostMirrorLogPath;
  int? _lastHostExitCode;
  String? _lastHostStdoutSnippet;
  String? _lastHostStderrSnippet;

  String? get lastHostLaunchCommand => _lastHostLaunchCommand;
  String? get lastHostLaunchMode => _lastHostLaunchMode;
  String? get lastHostLogPath => _lastHostLogPath;
  String? get lastHostMirrorLogPath => _lastHostMirrorLogPath;
  int? get lastHostExitCode => _lastHostExitCode;
  String? get lastHostStdoutSnippet => _lastHostStdoutSnippet;
  String? get lastHostStderrSnippet => _lastHostStderrSnippet;

  String? get lastCompanionLaunchCommand => _lastHostLaunchCommand;
  String? get lastCompanionLaunchMode => _lastHostLaunchMode;
  String? get lastCompanionLogPath => _lastHostLogPath;
  String? get lastCompanionMirrorLogPath => _lastHostMirrorLogPath;
  int? get lastCompanionExitCode => _lastHostExitCode;
  String? get lastCompanionStdoutSnippet => _lastHostStdoutSnippet;
  String? get lastCompanionStderrSnippet => _lastHostStderrSnippet;

  String? get lastHostCommand => _lastHostLaunchCommand;

  Future<String?> locateExecutablePath() async {
    if (debugLocateExecutablePath != null) {
      return debugLocateExecutablePath!();
    }
    final candidates = <String>[];
    final executableDir = path.dirname(Platform.resolvedExecutable);
    candidates.add(
      path.join(executableDir, runtimeDirectoryName, executableName),
    );
    candidates.add(
      path.join(
        Directory.current.path,
        'third_party',
        'rustdesk',
        'windows',
        'runtime',
        executableName,
      ),
    );
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  Future<String?> locateCompanionExecutablePath() async {
    final bundledExecutablePath = await _resolveBundledExecutablePath();
    if (bundledExecutablePath == null) {
      return null;
    }
    final companionPath = path.join(
      path.dirname(bundledExecutablePath),
      companionExecutableName,
    );
    if (debugLocateExecutablePath != null) {
      return companionPath;
    }
    await _ensureCompanionExecutablePrepared(
      bundledExecutablePath: bundledExecutablePath,
      companionExecutablePath: companionPath,
    );
    return await File(companionPath).exists() ? companionPath : null;
  }

  Future<String?> locateInstalledExecutablePath() async {
    if (debugLocateInstalledExecutablePath != null) {
      return debugLocateInstalledExecutablePath!();
    }
    final candidates = <String>[
      r'C:\Program Files\RustDesk\RustDesk.exe',
      r'C:\Program Files\RustDesk\rustdesk.exe',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  Future<bool> isAvailable() async {
    return (await locateExecutablePath()) != null;
  }

  Future<String> managedRuntimeHomePath() async {
    if (debugManagedRootPath != null) {
      return debugManagedRootPath!();
    }
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final directory = Directory(
      path.join(base, managedRootDirectoryName, managedRuntimeDirectoryName),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> managedConfigDirectoryPath() async {
    final directory = Directory(
      path.join(
        await managedRuntimeHomePath(),
        'appdata',
        'RustDesk',
        'config',
      ),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> managedLocalAppDataDirectoryPath() async {
    final directory = Directory(
      path.join(await managedRuntimeHomePath(), 'localappdata'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> managedTempDirectoryPath() async {
    final directory = Directory(
      path.join(await managedRuntimeHomePath(), 'temp'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> managedRustDeskInternalLogsDirectoryPath() async {
    final directory = Directory(
      path.join(await managedRuntimeHomePath(), 'appdata', 'RustDesk', 'log'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<void> syncManagedLogsToMirror() async {
    await _syncRustDeskInternalLogsToMirror();
  }

  Future<String> managedSupervisorLogsDirectoryPath() async {
    final directory = Directory(
      path.join(await managedRuntimeHomePath(), 'logs'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> mirroredCompanionLogsDirectoryPath() async {
    final executableDir = path.dirname(Platform.resolvedExecutable);
    final directory =
        Directory(path.join(executableDir, 'logs', 'rustdesk_host'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  @visibleForTesting
  Future<Map<String, String>> debugResolveManagedEnvironmentForTest() async {
    return _managedEnvironment();
  }

  Future<bool> isLocalPortListening(int port) async {
    if (debugIsLocalPortListening != null) {
      return debugIsLocalPortListening!(port);
    }
    if (Platform.isWindows) {
      final result = await Process.run(
        'cmd',
        ['/c', 'netstat -ano -p tcp'],
        runInShell: true,
      );
      final output = '${result.stdout}\n${result.stderr}';
      return matchesWindowsListeningPort(output, port);
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureTrayProcess() async {
    final bundledExecutablePath = await _resolveBundledExecutablePath();
    if (bundledExecutablePath == null) {
      throw StateError('内置 RustDesk 运行时未找到');
    }
    await _startDetachedProcess(
      executablePath: bundledExecutablePath,
      arguments: const ['--tray'],
      workingDirectory: path.dirname(bundledExecutablePath),
    );
  }

  Future<void> ensureCompanionReady({
    required int listenPort,
    String? sessionToken,
  }) async {
    if (sessionToken == null || sessionToken.trim().isEmpty) {
      await cleanupManagedSessionState(listenPort: listenPort);
      return;
    }
    await ensureHostReady(
      listenPort: listenPort,
      sessionToken: sessionToken,
    );
  }

  Future<void> ensureHostReady({
    required int listenPort,
    required String sessionToken,
  }) async {
    final bundledExecutablePath = await _resolveBundledExecutablePath();
    final companionExecutablePath = await locateCompanionExecutablePath();
    if (bundledExecutablePath == null) {
      throw RustDeskHostNotReadyException(
        listenPort: listenPort,
        executablePath: bundledExecutablePath,
        companionExecutablePath: companionExecutablePath,
        attempts: const ['missing-bundled-runtime'],
        managedRootPath: await managedRuntimeHomePath(),
        managedConfigPath: await managedConfigDirectoryPath(),
        managedLogPath: await managedSupervisorLogsDirectoryPath(),
        mirroredLogPath: await mirroredCompanionLogsDirectoryPath(),
      );
    }

    await _ensureCompanionExecutablePrepared(
      bundledExecutablePath: bundledExecutablePath,
      companionExecutablePath: path.join(
        path.dirname(bundledExecutablePath),
        companionExecutableName,
      ),
    );
    await _reconcileManagedRuntimeVersion(bundledExecutablePath);
    await _stopManagedHost();
    if (await isLocalPortListening(listenPort)) {
      throw RustDeskHostNotReadyException(
        listenPort: listenPort,
        executablePath: bundledExecutablePath,
        companionExecutablePath: companionExecutablePath,
        attempts: const ['listen-port-occupied-by-external-process'],
        managedRootPath: await managedRuntimeHomePath(),
        managedConfigPath: await managedConfigDirectoryPath(),
        managedLogPath: await managedSupervisorLogsDirectoryPath(),
        mirroredLogPath: await mirroredCompanionLogsDirectoryPath(),
      );
    }

    await _prepareControlledSessionConfig(listenPort: listenPort);
    await _applySessionPassword(
      bundledExecutablePath: bundledExecutablePath,
      sessionToken: sessionToken,
    );

    if (debugStartProcess != null) {
      await _ensureHostReadyWithDebugHooks(
        bundledExecutablePath: bundledExecutablePath,
        listenPort: listenPort,
      );
      return;
    }

    final attemptedCommands = <String>[];
    for (final args in _hostStartArgSets) {
      attemptedCommands.add('bundled:$executableName ${args.join(' ')}');
      final ready = await _startHostAttempt(
        bundledExecutablePath: bundledExecutablePath,
        arguments: args,
        listenPort: listenPort,
      );
      if (ready) {
        return;
      }
    }

    throw RustDeskHostNotReadyException(
      listenPort: listenPort,
      executablePath: bundledExecutablePath,
      companionExecutablePath: companionExecutablePath,
      attempts: attemptedCommands,
      managedRootPath: await managedRuntimeHomePath(),
      managedConfigPath: await managedConfigDirectoryPath(),
      managedLogPath:
          _lastHostLogPath ?? await managedSupervisorLogsDirectoryPath(),
      mirroredLogPath:
          _lastHostMirrorLogPath ?? await mirroredCompanionLogsDirectoryPath(),
      lastExitCode: _lastHostExitCode,
      lastStdout: _lastHostStdoutSnippet,
      lastStderr: _lastHostStderrSnippet,
    );
  }

  Future<void> openRemoteDesktop({
    required String targetAddress,
    required String sessionToken,
  }) async {
    final bundledExecutablePath = await _resolveBundledExecutablePath();
    if (bundledExecutablePath == null) {
      throw StateError('内置 RustDesk 运行时未找到');
    }
    await _prepareControllerConfig(
      listenPort: _listenPortFromTargetAddress(targetAddress),
      sessionToken: sessionToken,
    );
    await _startDetachedProcess(
      executablePath: bundledExecutablePath,
      arguments: ['--connect', targetAddress],
      workingDirectory: path.dirname(bundledExecutablePath),
    );
  }

  Future<void> cleanupManagedSessionState({
    int listenPort = 21118,
  }) async {
    await _stopManagedHost();
    await _resetManagedSessionOptions(listenPort: listenPort);
    await _syncRustDeskInternalLogsToMirror();
  }

  Future<void> _ensureHostReadyWithDebugHooks({
    required String bundledExecutablePath,
    required int listenPort,
  }) async {
    if (await isLocalPortListening(listenPort)) {
      throw RustDeskHostNotReadyException(
        listenPort: listenPort,
        executablePath: bundledExecutablePath,
        companionExecutablePath: await locateCompanionExecutablePath(),
        attempts: const ['listen-port-occupied-by-external-process'],
        managedRootPath: await managedRuntimeHomePath(),
        managedConfigPath: await managedConfigDirectoryPath(),
        managedLogPath: await managedSupervisorLogsDirectoryPath(),
        mirroredLogPath: await mirroredCompanionLogsDirectoryPath(),
      );
    }

    final attemptedCommands = <String>[];
    for (final args in _hostStartArgSets) {
      attemptedCommands.add('bundled:$executableName ${args.join(' ')}');
      await debugStartProcess!(
        bundledExecutablePath,
        args,
        path.dirname(bundledExecutablePath),
      );
      _lastHostLaunchCommand = '$bundledExecutablePath ${args.join(' ')}';
      _lastHostLaunchMode = args.join(' ');
      final ready = await _waitForPortListening(
        port: listenPort,
        timeout: _hostAttemptTimeout,
      );
      if (ready) {
        await _writeManagedHostPid(0);
        await _writeManagedRuntimeVersion(bundledExecutablePath);
        return;
      }
    }
    throw RustDeskHostNotReadyException(
      listenPort: listenPort,
      executablePath: bundledExecutablePath,
      companionExecutablePath: await locateCompanionExecutablePath(),
      attempts: attemptedCommands,
      managedRootPath: await managedRuntimeHomePath(),
      managedConfigPath: await managedConfigDirectoryPath(),
      managedLogPath: await managedSupervisorLogsDirectoryPath(),
      mirroredLogPath: await mirroredCompanionLogsDirectoryPath(),
    );
  }

  Future<bool> _startHostAttempt({
    required String bundledExecutablePath,
    required List<String> arguments,
    required int listenPort,
  }) async {
    final workingDirectory = path.dirname(bundledExecutablePath);
    final environment = await _managedEnvironment();
    final managedLogPath = await _nextManagedHostLogPath(arguments);
    final mirrorLogPath = await _nextMirroredHostLogPath(arguments);
    final managedLogFile = File(managedLogPath);
    final mirrorLogFile = File(mirrorLogPath);
    await managedLogFile.parent.create(recursive: true);
    await mirrorLogFile.parent.create(recursive: true);
    final managedSink =
        managedLogFile.openWrite(mode: FileMode.writeOnlyAppend);
    final mirrorSink = mirrorLogFile.openWrite(mode: FileMode.writeOnlyAppend);
    final process = await Process.start(
      bundledExecutablePath,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: true,
      mode: ProcessStartMode.normal,
    );
    _managedHostProcess = process;
    _lastHostLaunchCommand = '$bundledExecutablePath ${arguments.join(' ')}';
    _lastHostLaunchMode = arguments.join(' ');
    _lastHostLogPath = managedLogPath;
    _lastHostMirrorLogPath = mirrorLogPath;
    _lastHostExitCode = null;
    _lastHostStdoutSnippet = null;
    _lastHostStderrSnippet = null;

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutSubscription = process.stdout.transform(utf8.decoder).listen(
      (chunk) {
        stdoutBuffer.write(chunk);
        managedSink.write('[stdout] $chunk');
        mirrorSink.write('[stdout] $chunk');
      },
    );
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen(
      (chunk) {
        stderrBuffer.write(chunk);
        managedSink.write('[stderr] $chunk');
        mirrorSink.write('[stderr] $chunk');
      },
    );

    final ready = await _waitForPortListeningOrProcessExit(
      port: listenPort,
      timeout: _hostAttemptTimeout,
      exitCode: process.exitCode.then((code) => code),
    );

    _lastHostStdoutSnippet = _singleLineSnippet(stdoutBuffer.toString());
    _lastHostStderrSnippet = _singleLineSnippet(stderrBuffer.toString());

    if (ready) {
      await _writeManagedHostPid(process.pid);
      await _writeManagedRuntimeVersion(bundledExecutablePath);
      unawaited(
        process.exitCode.then((code) async {
          _lastHostExitCode = code;
          if (identical(_managedHostProcess, process)) {
            _managedHostProcess = null;
          }
          await _clearManagedHostPidIfMatches(process.pid);
        }),
      );
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      await managedSink.flush();
      await mirrorSink.flush();
      await managedSink.close();
      await mirrorSink.close();
      await _syncRustDeskInternalLogsToMirror();
      return true;
    }

    if (process.kill()) {
      try {
        _lastHostExitCode = await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      } catch (_) {
        _lastHostExitCode = -1;
      }
    } else {
      _lastHostExitCode = -1;
    }
    _managedHostProcess = null;
    await _clearManagedHostPidIfMatches(process.pid);
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    await managedSink.flush();
    await mirrorSink.flush();
    await managedSink.close();
    await mirrorSink.close();
    await _syncRustDeskInternalLogsToMirror();
    return false;
  }

  Future<void> _startDetachedProcess({
    required String executablePath,
    required List<String> arguments,
    required String workingDirectory,
  }) async {
    if (debugStartProcess != null) {
      await debugStartProcess!(executablePath, arguments, workingDirectory);
      return;
    }
    await Process.start(
      executablePath,
      arguments,
      workingDirectory: workingDirectory,
      environment: await _managedEnvironment(),
      includeParentEnvironment: true,
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> _ensureCompanionExecutablePrepared({
    required String bundledExecutablePath,
    required String companionExecutablePath,
  }) async {
    if (debugLocateExecutablePath != null) {
      return;
    }
    final bundledFile = File(bundledExecutablePath);
    final companionFile = File(companionExecutablePath);
    if (!await bundledFile.exists()) {
      return;
    }
    if (!await companionFile.exists()) {
      await bundledFile.copy(companionExecutablePath);
      return;
    }
    final bundledStat = await bundledFile.stat();
    final companionStat = await companionFile.stat();
    if (bundledStat.size != companionStat.size ||
        bundledStat.modified.isAfter(companionStat.modified)) {
      await bundledFile.copy(companionExecutablePath);
    }
  }

  Future<void> _reconcileManagedRuntimeVersion(
    String bundledExecutablePath,
  ) async {
    final bundledVersion =
        await _readBundledRuntimeVersion(bundledExecutablePath);
    final managedVersion = await _readManagedRuntimeVersion();
    if (bundledVersion == null || managedVersion == bundledVersion) {
      return;
    }
    await _stopManagedHost();
  }

  Future<void> _stopManagedHost() async {
    final managedPids = await _readManagedHostPids();
    for (final pid in managedPids) {
      if (pid > 0) {
        Process.killPid(pid);
      }
    }
    if (managedPids.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (_managedHostProcess != null) {
      _managedHostProcess!.kill();
      _managedHostProcess = null;
    }
    await _deleteManagedHostPidFiles();
  }

  Future<void> _writeManagedHostPid(int pid) async {
    final file = File(await _managedHostPidFilePath());
    await file.parent.create(recursive: true);
    await file.writeAsString('$pid');
  }

  Future<Set<int>> _readManagedHostPids() async {
    final pids = <int>{};
    for (final filePath in [
      await _managedHostPidFilePath(),
      await _legacyManagedCompanionPidFilePath(),
    ]) {
      final file = File(filePath);
      if (!await file.exists()) {
        continue;
      }
      final text = (await file.readAsString()).trim();
      final pid = int.tryParse(text);
      if (pid != null) {
        pids.add(pid);
      }
    }
    return pids;
  }

  Future<void> _clearManagedHostPidIfMatches(int pid) async {
    for (final filePath in [
      await _managedHostPidFilePath(),
      await _legacyManagedCompanionPidFilePath(),
    ]) {
      final file = File(filePath);
      if (!await file.exists()) {
        continue;
      }
      final current = int.tryParse((await file.readAsString()).trim());
      if (current == pid) {
        await file.delete();
      }
    }
  }

  Future<void> _deleteManagedHostPidFiles() async {
    for (final filePath in [
      await _managedHostPidFilePath(),
      await _legacyManagedCompanionPidFilePath(),
    ]) {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<String> _managedHostPidFilePath() async {
    return path.join(await managedRuntimeHomePath(), managedHostPidFileName);
  }

  Future<String> _legacyManagedCompanionPidFilePath() async {
    return path.join(
      await managedRuntimeHomePath(),
      legacyManagedCompanionPidFileName,
    );
  }

  Future<void> _writeManagedRuntimeVersion(String bundledExecutablePath) async {
    final version = await _readBundledRuntimeVersion(bundledExecutablePath);
    if (version == null || version.isEmpty) {
      return;
    }
    final file = File(await _managedRuntimeVersionFilePath());
    await file.parent.create(recursive: true);
    await file.writeAsString(version);
  }

  Future<String?> _readManagedRuntimeVersion() async {
    final file = File(await _managedRuntimeVersionFilePath());
    if (!await file.exists()) {
      return null;
    }
    return (await file.readAsString()).trim();
  }

  Future<String> _managedRuntimeVersionFilePath() async {
    return path.join(await managedRuntimeHomePath(), runtimeVersionFileName);
  }

  Future<String?> _readBundledRuntimeVersion(
    String bundledExecutablePath,
  ) async {
    final versionFile = File(
      path.join(path.dirname(bundledExecutablePath), runtimeVersionFileName),
    );
    if (!await versionFile.exists()) {
      return null;
    }
    return (await versionFile.readAsString()).trim();
  }

  Future<bool> _waitForPortListening({
    required int port,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isLocalPortListening(port)) {
        return true;
      }
      if (debugSleep != null) {
        await debugSleep!(_hostProbeInterval);
      } else {
        await Future<void>.delayed(_hostProbeInterval);
      }
    }
    return await isLocalPortListening(port);
  }

  Future<bool> _waitForPortListeningOrProcessExit({
    required int port,
    required Duration timeout,
    required Future<int> exitCode,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isLocalPortListening(port)) {
        return true;
      }
      final completed = await Future.any<bool>([
        exitCode.then((_) => true),
        Future<void>.delayed(_hostProbeInterval).then((_) => false),
      ]);
      if (completed) {
        break;
      }
    }
    return await isLocalPortListening(port);
  }

  Future<void> _prepareControlledSessionConfig({
    required int listenPort,
  }) async {
    if (debugEnsureDirectAccessConfig != null) {
      await debugEnsureDirectAccessConfig!(listenPort);
      return;
    }
    await _updateManagedConfigFiles(
      listenPort: listenPort,
      transform: (original) {
        var next = upsertRustDeskOption(original, 'direct-server', 'Y');
        next = upsertRustDeskOption(next, 'direct-access-port', '$listenPort');
        next = upsertRustDeskOption(next, 'approve-mode', 'password');
        next = upsertRustDeskOption(
          next,
          'verification-method',
          'use-permanent-password',
        );
        next = removeRustDeskOption(next, 'default-connect-password');
        return next;
      },
    );
  }

  Future<void> _prepareControllerConfig({
    required int listenPort,
    required String sessionToken,
  }) async {
    if (debugEnsureDirectAccessConfig != null) {
      await debugEnsureDirectAccessConfig!(listenPort);
      return;
    }
    await _updateManagedConfigFiles(
      listenPort: listenPort,
      transform: (original) {
        var next = upsertRustDeskOption(original, 'direct-server', 'Y');
        next = upsertRustDeskOption(next, 'direct-access-port', '$listenPort');
        next = upsertRustDeskOption(
          next,
          'default-connect-password',
          sessionToken,
        );
        return next;
      },
    );
  }

  Future<void> _resetManagedSessionOptions({
    required int listenPort,
  }) async {
    if (debugEnsureDirectAccessConfig != null) {
      await debugEnsureDirectAccessConfig!(listenPort);
      return;
    }
    await _updateManagedConfigFiles(
      listenPort: listenPort,
      transform: (original) {
        var next = upsertRustDeskOption(original, 'direct-server', 'Y');
        next = upsertRustDeskOption(next, 'direct-access-port', '$listenPort');
        next = upsertRustDeskOption(next, 'approve-mode', 'click');
        next = upsertRustDeskOption(
          next,
          'verification-method',
          'use-temporary-password',
        );
        next = removeRustDeskOption(next, 'default-connect-password');
        return next;
      },
    );
  }

  Future<void> _updateManagedConfigFiles({
    required int listenPort,
    required String Function(String original) transform,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    final configDir = Directory(await managedConfigDirectoryPath());
    if (!await configDir.exists()) {
      await configDir.create(recursive: true);
    }
    final files = [
      File(path.join(configDir.path, 'RustDesk.toml')),
      File(path.join(configDir.path, 'RustDesk2.toml')),
    ];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      if (index > 0 && !await file.exists()) {
        continue;
      }
      final original = await file.exists() ? await file.readAsString() : '';
      final next = transform(original);
      if (next != original || !await file.exists()) {
        await file.writeAsString(next);
      }
    }
  }

  Future<void> _applySessionPassword({
    required String bundledExecutablePath,
    required String sessionToken,
  }) async {
    if (sessionToken.trim().isEmpty) {
      throw StateError('远程协助会话密码为空');
    }
    await _runManagedCommand(
      executablePath: bundledExecutablePath,
      arguments: ['--password', sessionToken],
      workingDirectory: path.dirname(bundledExecutablePath),
    );
  }

  Future<ProcessResult> _runManagedCommand({
    required String executablePath,
    required List<String> arguments,
    required String workingDirectory,
  }) async {
    final result = debugRunProcess != null
        ? await debugRunProcess!(executablePath, arguments, workingDirectory)
        : await Process.run(
            executablePath,
            arguments,
            workingDirectory: workingDirectory,
            environment: await _managedEnvironment(),
            includeParentEnvironment: true,
            runInShell: false,
          );
    if (result.exitCode == 0) {
      return result;
    }
    final command = _redactedCommand(arguments);
    throw StateError(
      '内置 RustDesk 命令执行失败: $command | exitCode=${result.exitCode}'
      '${_buildProcessSnippet('stdout', result.stdout)}'
      '${_buildProcessSnippet('stderr', result.stderr)}',
    );
  }

  String _redactedCommand(List<String> arguments) {
    final safeArgs = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (i > 0 && arguments[i - 1] == '--password') {
        safeArgs.add('***');
        continue;
      }
      safeArgs.add(arg);
    }
    return safeArgs.join(' ');
  }

  String _buildProcessSnippet(String label, Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      return '';
    }
    return ' | $label=${_singleLineSnippet(text)}';
  }

  Future<String?> _resolveBundledExecutablePath() async {
    final bundled = await locateExecutablePath();
    if (bundled == null || bundled.isEmpty) {
      return null;
    }
    return bundled;
  }

  Future<Map<String, String>> _managedEnvironment() async {
    if (debugManagedEnvironment != null) {
      return debugManagedEnvironment!();
    }
    final appData = Directory(
      path.join(await managedRuntimeHomePath(), 'appdata'),
    );
    final localAppData = Directory(await managedLocalAppDataDirectoryPath());
    final tempDir = Directory(await managedTempDirectoryPath());
    final directories = [appData, localAppData, tempDir];
    for (final directory in directories) {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    }
    final base = Map<String, String>.from(Platform.environment);
    base['APPDATA'] = appData.path;
    base['LOCALAPPDATA'] = localAppData.path;
    base['TEMP'] = tempDir.path;
    base['TMP'] = tempDir.path;
    base.remove('HOME');
    return base;
  }

  Future<void> _syncRustDeskInternalLogsToMirror() async {
    final sourceDir =
        Directory(await managedRustDeskInternalLogsDirectoryPath());
    if (!await sourceDir.exists()) {
      return;
    }
    final mirrorDir = Directory(await mirroredCompanionLogsDirectoryPath());
    if (!await mirrorDir.exists()) {
      await mirrorDir.create(recursive: true);
    }
    await for (final entity in sourceDir.list()) {
      if (entity is! File) {
        continue;
      }
      final destination =
          File(path.join(mirrorDir.path, path.basename(entity.path)));
      await entity.copy(destination.path);
    }
  }

  Future<String> _nextManagedHostLogPath(List<String> arguments) async {
    final logsDir = await managedSupervisorLogsDirectoryPath();
    final suffix =
        arguments.join('_').replaceAll('--', '').replaceAll(' ', '_');
    return path.join(
      logsDir,
      'host_${DateTime.now().millisecondsSinceEpoch}_$suffix.log',
    );
  }

  Future<String> _nextMirroredHostLogPath(List<String> arguments) async {
    final logsDir = await mirroredCompanionLogsDirectoryPath();
    final suffix =
        arguments.join('_').replaceAll('--', '').replaceAll(' ', '_');
    return path.join(
      logsDir,
      'host_${DateTime.now().millisecondsSinceEpoch}_$suffix.log',
    );
  }

  int _listenPortFromTargetAddress(String targetAddress) {
    final separator = targetAddress.lastIndexOf(':');
    if (separator == -1) {
      return 21118;
    }
    return int.tryParse(targetAddress.substring(separator + 1)) ?? 21118;
  }
}

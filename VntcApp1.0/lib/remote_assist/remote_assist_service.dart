import 'dart:io';

import 'rustdesk_runtime.dart';

class RemoteAssistService {
  RemoteAssistService._();

  static final RemoteAssistService instance = RemoteAssistService._();

  static const int listenPort = 21118;
  static const String capabilityWindows = 'remote_assist_windows';
  static const String capabilityController = 'remote_assist_controller';
  static const String capabilityControlled = 'remote_assist_controlled';

  Future<List<String>> localCapabilities() async {
    if (!Platform.isWindows) {
      return const [];
    }
    if (!await RustDeskRuntime.instance.isAvailable()) {
      return const [];
    }
    return const [
      capabilityWindows,
      capabilityController,
      capabilityControlled,
    ];
  }

  Future<bool> isAvailable() async {
    if (!Platform.isWindows) {
      return false;
    }
    return RustDeskRuntime.instance.isAvailable();
  }

  Future<void> ensureHostReady({
    required int listenPort,
  }) async {
    await RustDeskRuntime.instance.ensureHostReady(listenPort: listenPort);
  }

  Future<void> ensureCompanionReady({
    required int listenPort,
  }) async {
    await RustDeskRuntime.instance.ensureCompanionReady(listenPort: listenPort);
  }

  Future<void> launchController(String virtualIp) async {
    await RustDeskRuntime.instance.openRemoteDesktop(
      targetAddress: '$virtualIp:$listenPort',
    );
  }

  Future<void> cleanupManagedSessionState({
    int listenPort = RemoteAssistService.listenPort,
  }) async {
    await RustDeskRuntime.instance.cleanupManagedSessionState(
      listenPort: listenPort,
    );
  }

  Future<String?> bundledRuntimePath() async {
    return RustDeskRuntime.instance.locateExecutablePath();
  }

  Future<String?> installedRuntimePath() async {
    return RustDeskRuntime.instance.locateInstalledExecutablePath();
  }

  Future<String> managedRuntimeHomePath() async {
    return RustDeskRuntime.instance.managedRuntimeHomePath();
  }

  Future<String> managedConfigDirectoryPath() async {
    return RustDeskRuntime.instance.managedConfigDirectoryPath();
  }

  Future<String> managedLogsDirectoryPath() async {
    return RustDeskRuntime.instance.managedSupervisorLogsDirectoryPath();
  }

  Future<String> managedRustDeskInternalLogsDirectoryPath() async {
    return RustDeskRuntime.instance.managedRustDeskInternalLogsDirectoryPath();
  }

  Future<String> managedRustDeskCurrentLogPath() async {
    return RustDeskRuntime.instance.managedRustDeskCurrentLogPath();
  }

  Future<String?> bundledRuntimeMetadataPath() async {
    return RustDeskRuntime.instance.bundledRuntimeMetadataPath();
  }

  Future<String> mirroredCompanionLogsDirectoryPath() async {
    return RustDeskRuntime.instance.mirroredCompanionLogsDirectoryPath();
  }

  Future<void> syncManagedLogsToMirror() async {
    await RustDeskRuntime.instance.syncManagedLogsToMirror();
  }

  Future<String?> companionExecutablePath() async {
    return RustDeskRuntime.instance.locateCompanionExecutablePath();
  }

  String? get lastCompanionLaunchCommand =>
      RustDeskRuntime.instance.lastCompanionLaunchCommand;

  String? get lastCompanionLaunchMode =>
      RustDeskRuntime.instance.lastCompanionLaunchMode;

  String? get lastCompanionLogPath =>
      RustDeskRuntime.instance.lastCompanionLogPath;

  String? get lastCompanionMirrorLogPath =>
      RustDeskRuntime.instance.lastCompanionMirrorLogPath;

  int? get lastCompanionExitCode =>
      RustDeskRuntime.instance.lastCompanionExitCode;

  String? get lastCompanionStdoutSnippet =>
      RustDeskRuntime.instance.lastCompanionStdoutSnippet;

  String? get lastCompanionStderrSnippet =>
      RustDeskRuntime.instance.lastCompanionStderrSnippet;

  String? get lastHostCommand => RustDeskRuntime.instance.lastHostCommand;

  String? get lastHostLaunchMode => RustDeskRuntime.instance.lastHostLaunchMode;

  String? get lastHostLogPath => RustDeskRuntime.instance.lastHostLogPath;

  String? get lastHostOfficialLogPath =>
      RustDeskRuntime.instance.lastHostOfficialLogPath;

  String? get lastHostOfficialLogSnippet =>
      RustDeskRuntime.instance.lastHostOfficialLogSnippet;

  int? get lastHostExitCode => RustDeskRuntime.instance.lastHostExitCode;

  String? get lastHostStdoutSnippet =>
      RustDeskRuntime.instance.lastHostStdoutSnippet;

  String? get lastHostStderrSnippet =>
      RustDeskRuntime.instance.lastHostStderrSnippet;

  Future<String> unavailableReason() async {
    if (!Platform.isWindows) {
      return '当前平台暂不支持远程协助';
    }
    if (!await RustDeskRuntime.instance.isAvailable()) {
      return '内置 RustDesk 运行时缺失，请重新构建或检查运行包';
    }
    return '';
  }
}

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vnt_app/remote_assist/remote_assist_command_security.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_health_service.dart';
import 'package:vnt_app/remote_assist/remote_assist_log.dart';
import 'package:vnt_app/remote_assist/remote_assist_macos_runtime.dart';
import 'package:vnt_app/remote_assist/remote_assist_models.dart';
import 'package:vnt_app/remote_assist/remote_assist_platform_adapter.dart';

class RemoteAssistMacosAdapter extends RemoteAssistPlatformAdapter {
  RemoteAssistMacosAdapter({
    RemoteAssistMacosRuntimeLocator? runtimeLocator,
  }) : _runtimeLocator =
            runtimeLocator ?? const RemoteAssistMacosRuntimeLocator();

  final RemoteAssistMacosRuntimeLocator _runtimeLocator;

  @override
  RemoteAssistPlatform get platform => RemoteAssistPlatform.macos;

  @override
  List<String> get supportedRoles => const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  List<String> get presenceCapabilities => const <String>[
        RemoteAssistConstants.capabilityMacos,
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  Future<void> stop() async {
    await stopControlledService();
  }

  @override
  Future<String> resolveVersion() async {
    return (await _runtimeLocator.locate())?.version ?? '';
  }

  @override
  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
  }) async {
    final runtime = await _runtimeLocator.locate();
    final executablePath = runtime?.executablePath ?? '';
    final serverRunning = runtime == null
        ? false
        : await _isServerProcessRunning(runtime.executablePath);
    final portListening = runtime == null
        ? false
        : await _isPortListening(RemoteAssistConstants.directAccessPort);
    final runtimeReady = isRemoteAssistRuntimeReady(
      serviceRunning: serverRunning,
      hasServiceProcess: false,
      hasServerProcess: serverRunning,
      portListening: portListening,
    );
    final issues = <String>[];

    if (!vntConnected) {
      issues.add('当前未连接任何虚拟网络');
    }
    if (runtime == null) {
      issues.add('未检测到 macOS 远控组件，请使用包含内置 VNTC RustDesk 的 macOS 包');
    } else {
      if (!runtimeReady) {
        issues.add('macOS 受控服务未启动，可点击“启动受控服务”');
      }
      if (runtimeReady && !portListening) {
        issues.add('49999 端口未监听，请重新启动受控服务');
      }
      issues.add('首次被控前，请在系统设置中允许 VNTC RustDesk 的屏幕录制、辅助功能和麦克风权限');
    }

    return RemoteAssistHealthStatus(
      supported: true,
      platform: platform,
      supportedRoles: supportedRoles,
      vntConnected: vntConnected,
      runtimeAvailable: runtime != null,
      serviceInstalled: runtime != null,
      serviceRunning: runtimeReady,
      portListening: portListening,
      firewallTcpRulePresent: true,
      firewallUdpRulePresent: true,
      firewallSyncSucceeded: true,
      presenceRunning: presenceRunning,
      hasAdminPrivileges: false,
      managedInstall: runtime?.managedInstall ?? false,
      bundledInstallerAvailable: runtime?.managedInstall ?? false,
      bundledBootstrapAvailable: runtime?.managedInstall ?? false,
      localVirtualIps: localVirtualIps,
      networkCidrs: networkCidrs,
      executablePath: executablePath,
      runtimeVersion: runtime?.version ?? '',
      controllerAvailable: runtime != null,
      controlledServiceRunning: runtimeReady,
      notificationPermissionGranted: true,
      screenCapturePermissionGranted: false,
      accessibilityPermissionGranted: false,
      overlayPermissionGranted: true,
      batteryOptimizationIgnored: true,
      issues: issues,
    );
  }

  @override
  Future<void> launchController(
    String virtualIp, {
    String? password,
  }) async {
    final runtime = await _requireRuntime();
    final targetAddress =
        '$virtualIp:${RemoteAssistConstants.directAccessPort}';
    final secretFile =
        await RemoteAssistCommandSecurity.createSecretFile(password);
    final arguments = RemoteAssistCommandSecurity.connectArguments(
      targetAddress: targetAddress,
      passwordFilePath: secretFile?.path,
    );
    await RemoteAssistLog.write('macOS 发起远程协助连接: $targetAddress');
    try {
      await Process.start(
        runtime.executablePath,
        arguments,
        workingDirectory: path.dirname(runtime.executablePath),
        mode: ProcessStartMode.detached,
      );
      secretFile?.scheduleDelete();
    } catch (_) {
      await secretFile?.delete();
      rethrow;
    }
  }

  @override
  Future<void> configureAccessPassword(String password) async {
    final runtime = await _requireRuntime();
    final secretFile =
        await RemoteAssistCommandSecurity.createSecretFile(password);
    final arguments = RemoteAssistCommandSecurity.configurePasswordArguments(
      password: password,
      passwordFilePath: secretFile?.path,
    );
    final ProcessResult result;
    try {
      result = await Process.run(
        runtime.executablePath,
        arguments,
        workingDirectory: path.dirname(runtime.executablePath),
      );
    } finally {
      await secretFile?.delete();
    }
    if (result.exitCode == 0) {
      await RemoteAssistLog.write('macOS 远程协助访问密码配置完成');
      return;
    }

    final message = [
      result.stdout.toString().trim(),
      result.stderr.toString().trim(),
    ]
        .where((item) => item.isNotEmpty)
        .map(
          (item) => RemoteAssistCommandSecurity.redactText(
            item,
            secret: password,
          ),
        )
        .join(' | ');
    throw StateError(
      message.isEmpty ? 'macOS 远程密码配置失败' : 'macOS 远程密码配置失败：$message',
    );
  }

  @override
  Future<void> repair({
    required List<String> remoteCidrs,
  }) async {
    await _requireRuntime();
  }

  @override
  Future<void> requestPermission(String permission) async {
    await openSystemSettings(permission);
  }

  @override
  Future<void> openSystemSettings(String section) async {
    final url = switch (section) {
      RemoteAssistConstants.macosSettingsScreenRecording =>
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
      RemoteAssistConstants.macosSettingsAccessibility =>
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
      RemoteAssistConstants.macosSettingsMicrophone =>
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
      _ => 'x-apple.systempreferences:com.apple.preference.security',
    };
    await Process.start('open', [url], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> startControlledService() async {
    final runtime = await _requireRuntime();
    if (await _isServerProcessRunning(runtime.executablePath)) {
      return;
    }
    await RemoteAssistLog.write('启动 macOS VNTC RustDesk 受控服务');
    await Process.start(
      runtime.executablePath,
      const ['--server'],
      workingDirectory: path.dirname(runtime.executablePath),
      mode: ProcessStartMode.detached,
    );
  }

  @override
  Future<void> stopControlledService() async {
    final runtime = await _runtimeLocator.locate();
    if (runtime == null) {
      return;
    }
    final processIds = await _serverProcessIds(runtime.executablePath);
    if (processIds.isEmpty) {
      return;
    }
    await RemoteAssistLog.write(
      '停止 macOS VNTC RustDesk 受控服务 pid=${processIds.join(",")}',
    );
    for (final processId in processIds) {
      await Process.run('kill', ['-TERM', '$processId']);
    }
  }

  Future<RemoteAssistMacosRuntimeInfo> _requireRuntime() async {
    final runtime = await _runtimeLocator.locate();
    if (runtime == null) {
      throw StateError('未找到 macOS VNTC RustDesk 远控组件');
    }
    return runtime;
  }

  Future<bool> _isServerProcessRunning(String executablePath) async {
    return (await _serverProcessIds(executablePath)).isNotEmpty;
  }

  Future<List<int>> _serverProcessIds(String executablePath) async {
    final result = await Process.run('ps', const ['-axo', 'pid=,command=']);
    if (result.exitCode != 0) {
      return const <int>[];
    }

    final normalizedExecutablePath = path.normalize(executablePath);
    final currentPid = pid;
    final ids = <int>[];
    for (final line in result.stdout.toString().split('\n')) {
      final match = RegExp(r'^\s*(\d+)\s+(.*)$').firstMatch(line);
      if (match == null) {
        continue;
      }
      final processId = int.tryParse(match.group(1) ?? '');
      final command = match.group(2) ?? '';
      if (processId == null || processId == currentPid) {
        continue;
      }
      if (!command.contains('--server')) {
        continue;
      }
      if (!command.contains(normalizedExecutablePath)) {
        continue;
      }
      ids.add(processId);
    }
    return ids;
  }

  Future<bool> _isPortListening(int port) async {
    final result = await Process.run(
      'lsof',
      ['-nP', '-iTCP:$port', '-sTCP:LISTEN'],
    );
    return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
  }
}

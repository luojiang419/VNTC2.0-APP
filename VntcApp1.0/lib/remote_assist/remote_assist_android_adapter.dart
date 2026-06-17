import 'controller_mobile/embedded_remote_assist_launcher.dart';
import 'remote_assist_android_bridge.dart';
import 'remote_assist_constants.dart';
import 'remote_assist_android_runtime.dart';
import 'remote_assist_models.dart';
import 'remote_assist_platform_adapter.dart';

class RemoteAssistAndroidAdapter extends RemoteAssistPlatformAdapter {
  RemoteAssistAndroidAdapter({
    RemoteAssistAndroidBridge? bridge,
    RemoteAssistAndroidRuntime? runtime,
  })  : _bridge = bridge ?? RemoteAssistAndroidBridge.instance,
        _runtime = runtime ?? RemoteAssistAndroidRuntime.instance;

  final RemoteAssistAndroidBridge _bridge;
  final RemoteAssistAndroidRuntime _runtime;

  @override
  RemoteAssistPlatform get platform => RemoteAssistPlatform.android;

  @override
  List<String> get supportedRoles => const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  List<String> get presenceCapabilities => const <String>[
        RemoteAssistConstants.capabilityAndroid,
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  Future<void> refreshState() async {
    await _bridge.refreshState();
  }

  @override
  Future<String> resolveVersion() async {
    return (await _bridge.getStatus()).runtimeVersion;
  }

  @override
  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
  }) async {
    final status = await _bridge.getStatus();
    final issues = <String>[];

    if (!vntConnected) {
      issues.add('当前未连接任何虚拟网络');
    }
    if (!status.notificationPermissionGranted) {
      issues.add('未授予通知权限，受控服务前台通知可能无法正常展示');
    }
    if (!status.controllerAvailable) {
      issues.add('当前安装包未包含适用于本机架构的内置控制端，无法在本机直接发起远程协助');
    }
    if (!status.screenCapturePermissionGranted) {
      issues.add('未完成屏幕录制授权，无法让其他设备查看和控制本机屏幕');
    }
    if (!status.accessibilityPermissionGranted) {
      issues.add('未开启无障碍控制服务，远程输入无法作用到本机');
    }
    if (!status.overlayPermissionGranted) {
      issues.add('未授予悬浮窗权限，远控运行态浮窗和前台驻留能力不完整');
    }
    if (!status.batteryOptimizationIgnored) {
      issues.add('建议关闭电池优化，避免受控服务在后台被系统回收');
    }
    if (!status.controlledServiceRunning) {
      issues.add('受控服务未启动，当前设备尚不能被其他设备控制');
    }

    return RemoteAssistHealthStatus(
      supported: true,
      platform: platform,
      supportedRoles: supportedRoles,
      vntConnected: vntConnected,
      runtimeAvailable: status.runtimeAvailable,
      serviceInstalled: status.serviceInstalled,
      serviceRunning: status.controlledServiceRunning,
      portListening: status.listenerReady,
      firewallTcpRulePresent: true,
      firewallUdpRulePresent: true,
      firewallSyncSucceeded: true,
      presenceRunning: presenceRunning,
      hasAdminPrivileges: false,
      managedInstall: true,
      bundledInstallerAvailable: false,
      bundledBootstrapAvailable: false,
      localVirtualIps: localVirtualIps,
      networkCidrs: networkCidrs,
      executablePath: 'Android 内置远控组件',
      runtimeVersion: status.runtimeVersion,
      controllerAvailable: status.controllerAvailable,
      controlledServiceRunning: status.controlledServiceRunning,
      notificationPermissionGranted: status.notificationPermissionGranted,
      screenCapturePermissionGranted: status.screenCapturePermissionGranted,
      accessibilityPermissionGranted: status.accessibilityPermissionGranted,
      overlayPermissionGranted: status.overlayPermissionGranted,
      batteryOptimizationIgnored: status.batteryOptimizationIgnored,
      issues: issues,
    );
  }

  @override
  Future<void> launchController(
    String virtualIp, {
    String? password,
  }) async {
    final status = await _bridge.getStatus();
    if (!status.controllerAvailable) {
      throw StateError('当前设备架构未包含内置远控控制端，请改用已包含 arm64 控制端的安装包');
    }
    await EmbeddedRemoteAssistLauncher.launch(
      virtualIp: virtualIp,
      password: password,
    );
  }

  @override
  Future<void> configureAccessPassword(String password) async {
    await _runtime.configureAccessPassword(password);
  }

  @override
  Future<void> repair({
    required List<String> remoteCidrs,
  }) async {
    await _bridge.refreshState();
  }

  @override
  Future<void> requestPermission(String permission) async {
    await _bridge.requestPermission(permission);
  }

  @override
  Future<void> openSystemSettings(String section) async {
    await _bridge.openSystemSettings(section);
  }

  @override
  Future<void> startControlledService() async {
    await _runtime.startControlledService();
  }

  @override
  Future<void> stopControlledService() async {
    await _runtime.stopControlledService();
  }
}

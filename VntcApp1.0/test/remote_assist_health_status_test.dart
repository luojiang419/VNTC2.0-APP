import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_health_service.dart';
import 'package:vnt_app/remote_assist/remote_assist_models.dart';

void main() {
  RemoteAssistHealthStatus buildStatus({
    RemoteAssistPlatform platform = RemoteAssistPlatform.windows,
    bool runtimeAvailable = false,
    bool serviceInstalled = false,
    bool managedInstall = false,
    bool bundledInstallerAvailable = false,
    bool bundledBootstrapAvailable = false,
    bool controllerAvailable = false,
    bool controlledServiceRunning = false,
    bool portListening = false,
    bool vntConnected = true,
    bool notificationPermissionGranted = false,
    bool screenCapturePermissionGranted = false,
    bool accessibilityPermissionGranted = false,
    bool overlayPermissionGranted = false,
    bool batteryOptimizationIgnored = false,
  }) {
    return RemoteAssistHealthStatus(
      supported: true,
      platform: platform,
      supportedRoles: const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ],
      vntConnected: vntConnected,
      runtimeAvailable: runtimeAvailable,
      serviceInstalled: serviceInstalled,
      serviceRunning: false,
      portListening: portListening,
      firewallTcpRulePresent: false,
      firewallUdpRulePresent: false,
      firewallSyncSucceeded: false,
      presenceRunning: false,
      hasAdminPrivileges: false,
      managedInstall: managedInstall,
      bundledInstallerAvailable: bundledInstallerAvailable,
      bundledBootstrapAvailable: bundledBootstrapAvailable,
      localVirtualIps: const <String>[],
      networkCidrs: const <String>[],
      executablePath: '',
      runtimeVersion: '',
      controllerAvailable: controllerAvailable,
      controlledServiceRunning: controlledServiceRunning,
      notificationPermissionGranted: notificationPermissionGranted,
      screenCapturePermissionGranted: screenCapturePermissionGranted,
      accessibilityPermissionGranted: accessibilityPermissionGranted,
      overlayPermissionGranted: overlayPermissionGranted,
      batteryOptimizationIgnored: batteryOptimizationIgnored,
      issues: const <String>[],
    );
  }

  test('installationModeDescription reflects managed install state', () {
    final status = buildStatus(
      runtimeAvailable: true,
      managedInstall: true,
    );

    expect(status.installationModeDescription, '受当前安装器管理');
  });

  test('installationModeDescription reflects standalone runtime', () {
    final status = buildStatus(runtimeAvailable: true);

    expect(status.installationModeDescription, '已检测到独立安装（未绑定当前应用）');
  });

  test('installationModeDescription reflects bundled repair assets', () {
    final status = buildStatus(
      bundledInstallerAvailable: true,
      bundledBootstrapAvailable: true,
    );

    expect(status.bundledRepairAvailable, isTrue);
    expect(status.installationModeDescription, '当前目录已携带远程协助安装组件');
    expect(status.canAttemptRepair, isTrue);
  });

  test('canAttemptRepair stays true for existing service without bundle', () {
    final status = buildStatus(serviceInstalled: true);

    expect(status.bundledRepairAvailable, isFalse);
    expect(status.canAttemptRepair, isTrue);
  });

  test('android status exposes embedded installation and permission guidance',
      () {
    final status = buildStatus(
      platform: RemoteAssistPlatform.android,
      runtimeAvailable: true,
      controlledServiceRunning: true,
      notificationPermissionGranted: true,
      screenCapturePermissionGranted: false,
      accessibilityPermissionGranted: true,
      overlayPermissionGranted: true,
      batteryOptimizationIgnored: true,
    );

    expect(status.installationModeDescription, '当前应用内置 Android 远控组件');
    expect(status.primaryActionLabel, '同步状态');
    expect(status.needsAndroidPermissionGuidance, isTrue);
    expect(status.canAttemptRepair, isTrue);
  });

  test('Android 通知、悬浮窗和电池白名单是建议项，不阻断核心远控', () {
    final status = buildStatus(
      platform: RemoteAssistPlatform.android,
      controlledServiceRunning: true,
      portListening: true,
      screenCapturePermissionGranted: true,
      accessibilityPermissionGranted: true,
      notificationPermissionGranted: false,
      overlayPermissionGranted: false,
      batteryOptimizationIgnored: false,
    );

    expect(status.permissionsReady, isTrue);
    expect(status.controlledViewReady, isTrue);
    expect(status.controlledReady, isTrue);
    expect(status.hasAndroidRecommendations, isTrue);
  });

  test('Android 无障碍未连接时允许观看但不宣称可完整控制', () {
    final status = buildStatus(
      platform: RemoteAssistPlatform.android,
      controlledServiceRunning: true,
      portListening: true,
      screenCapturePermissionGranted: true,
      accessibilityPermissionGranted: false,
    );

    expect(status.controlledViewReady, isTrue);
    expect(status.controlledReady, isFalse);
    expect(status.needsAndroidPermissionGuidance, isTrue);
  });

  test('macOS status exposes bundled runtime and controlled readiness', () {
    final status = buildStatus(
      platform: RemoteAssistPlatform.macos,
      runtimeAvailable: true,
      managedInstall: true,
      controllerAvailable: true,
      controlledServiceRunning: true,
      portListening: true,
    );

    expect(status.isMacOS, isTrue);
    expect(status.installationModeDescription, '当前应用已内置 macOS 远控组件');
    expect(status.primaryActionLabel, '同步状态');
    expect(status.controllerReady, isTrue);
    expect(status.controlledReady, isTrue);
  });

  test('macOS controlled readiness requires VNT connection', () {
    final status = buildStatus(
      platform: RemoteAssistPlatform.macos,
      runtimeAvailable: true,
      controllerAvailable: true,
      controlledServiceRunning: true,
      portListening: true,
      vntConnected: false,
    );

    expect(status.controllerReady, isFalse);
    expect(status.controlledReady, isFalse);
  });

  test('runtime ready requires listener port, not just service process', () {
    expect(
      isRemoteAssistRuntimeReady(
        serviceRunning: true,
        hasServiceProcess: true,
        hasServerProcess: true,
        portListening: false,
      ),
      isFalse,
    );
    expect(
      isRemoteAssistRuntimeReady(
        serviceRunning: false,
        hasServiceProcess: false,
        hasServerProcess: false,
        portListening: true,
      ),
      isTrue,
    );
  });

  test('Android remote assist is enabled after native host wiring', () {
    expect(RemoteAssistConstants.androidRemoteAssistEnabled, isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
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
      vntConnected: true,
      runtimeAvailable: runtimeAvailable,
      serviceInstalled: serviceInstalled,
      serviceRunning: false,
      portListening: false,
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
}

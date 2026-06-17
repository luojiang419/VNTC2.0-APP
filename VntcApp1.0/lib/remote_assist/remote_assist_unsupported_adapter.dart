import 'remote_assist_models.dart';
import 'remote_assist_platform_adapter.dart';

class RemoteAssistUnsupportedAdapter extends RemoteAssistPlatformAdapter {
  const RemoteAssistUnsupportedAdapter();

  @override
  RemoteAssistPlatform get platform => RemoteAssistPlatform.unsupported;

  @override
  List<String> get supportedRoles => const <String>[];

  @override
  List<String> get presenceCapabilities => const <String>[];

  @override
  Future<String> resolveVersion() async => '';

  @override
  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
  }) async {
    return RemoteAssistHealthStatus(
      supported: false,
      platform: platform,
      supportedRoles: supportedRoles,
      vntConnected: false,
      runtimeAvailable: false,
      serviceInstalled: false,
      serviceRunning: false,
      portListening: false,
      firewallTcpRulePresent: false,
      firewallUdpRulePresent: false,
      firewallSyncSucceeded: false,
      presenceRunning: false,
      hasAdminPrivileges: false,
      managedInstall: false,
      bundledInstallerAvailable: false,
      bundledBootstrapAvailable: false,
      localVirtualIps: const <String>[],
      networkCidrs: const <String>[],
      executablePath: '',
      runtimeVersion: '',
      controllerAvailable: false,
      controlledServiceRunning: false,
      notificationPermissionGranted: false,
      screenCapturePermissionGranted: false,
      accessibilityPermissionGranted: false,
      overlayPermissionGranted: false,
      batteryOptimizationIgnored: false,
      issues: const <String>['当前平台暂不支持远程协助'],
    );
  }

  @override
  Future<void> launchController(
    String virtualIp, {
    String? password,
  }) async {
    throw UnsupportedError('当前平台暂不支持远程协助');
  }

  @override
  Future<void> configureAccessPassword(String password) async {
    throw UnsupportedError('当前平台暂不支持远程协助');
  }

  @override
  Future<void> repair({
    required List<String> remoteCidrs,
  }) async {
    throw UnsupportedError('当前平台暂不支持远程协助');
  }
}

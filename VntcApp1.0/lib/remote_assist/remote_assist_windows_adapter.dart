import 'remote_assist_constants.dart';
import 'remote_assist_health_service.dart';
import 'remote_assist_launcher.dart';
import 'remote_assist_models.dart';
import 'remote_assist_platform_adapter.dart';

class RemoteAssistWindowsAdapter extends RemoteAssistPlatformAdapter {
  RemoteAssistWindowsAdapter({
    RemoteAssistLauncher? launcher,
    RemoteAssistHealthService? healthService,
  })  : _launcher = launcher ?? RemoteAssistLauncher.instance,
        _healthService = healthService ?? RemoteAssistHealthService();

  final RemoteAssistLauncher _launcher;
  final RemoteAssistHealthService _healthService;

  @override
  RemoteAssistPlatform get platform => RemoteAssistPlatform.windows;

  @override
  List<String> get supportedRoles => const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  List<String> get presenceCapabilities => const <String>[
        RemoteAssistConstants.capabilityWindows,
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ];

  @override
  Future<void> stop() async {
    await _healthService.shutdownBackgroundSilently();
  }

  @override
  Future<void> refreshState() async {
    await _healthService.warmUpBackgroundSilently();
  }

  @override
  Future<String> resolveVersion() async {
    return _launcher.resolveVersion();
  }

  @override
  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
  }) async {
    await _healthService.warmUpBackgroundSilently();
    final firewallSyncSucceeded = await _healthService.syncFirewallRules(
      enabled: vntConnected,
      remoteCidrs: networkCidrs,
    );
    return _healthService.collectStatus(
      vntConnected: vntConnected,
      localVirtualIps: localVirtualIps,
      networkCidrs: networkCidrs,
      presenceRunning: presenceRunning,
      firewallSyncSucceeded: firewallSyncSucceeded,
    );
  }

  @override
  Future<void> launchController(
    String virtualIp, {
    String? password,
  }) async {
    await _healthService.ensureBackgroundReady();
    await _launcher.openRemoteDesktop(
      targetAddress: '$virtualIp:${RemoteAssistConstants.directAccessPort}',
      password: password,
    );
  }

  @override
  Future<void> configureAccessPassword(String password) async {
    await _healthService.ensureBackgroundReady();
    await _launcher.configureAccessPassword(password);
  }

  @override
  Future<void> repair({
    required List<String> remoteCidrs,
  }) async {
    await _healthService.repair(remoteCidrs: remoteCidrs);
  }
}

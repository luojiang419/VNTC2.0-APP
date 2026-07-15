import 'remote_assist_models.dart';

abstract class RemoteAssistPlatformAdapter {
  const RemoteAssistPlatformAdapter();

  RemoteAssistPlatform get platform;

  List<String> get supportedRoles;

  List<String> get presenceCapabilities;

  bool get supportsAccessPasswordRead => false;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> refreshState() async {}

  Future<String> resolveVersion();

  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
  });

  Future<void> launchController(
    String virtualIp, {
    String? password,
  });

  Future<void> configureAccessPassword(String password);

  Future<String> loadAccessPassword() async => '';

  Future<void> repair({
    required List<String> remoteCidrs,
  });

  Future<void> requestPermission(String permission) async {
    throw UnsupportedError('当前平台不支持远程协助权限请求');
  }

  Future<void> openSystemSettings(String section) async {
    throw UnsupportedError('当前平台不支持打开远程协助系统设置');
  }

  Future<void> startControlledService() async {
    throw UnsupportedError('当前平台不支持启动受控服务');
  }

  Future<void> stopControlledService() async {
    throw UnsupportedError('当前平台不支持停止受控服务');
  }
}

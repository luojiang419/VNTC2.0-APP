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

  Future<void> ensureHostReady() async {
    await RustDeskRuntime.instance.ensureTrayProcess();
  }

  Future<void> launchController(String virtualIp) async {
    await RustDeskRuntime.instance.openRemoteDesktop(
      targetAddress: '$virtualIp:$listenPort',
    );
  }

  Future<String> unavailableReason() async {
    if (!Platform.isWindows) {
      return '当前平台暂不支持远程协助';
    }
    if (!await RustDeskRuntime.instance.isAvailable()) {
      return 'RustDesk 运行时缺失，请重新构建或检查运行包';
    }
    return '';
  }
}

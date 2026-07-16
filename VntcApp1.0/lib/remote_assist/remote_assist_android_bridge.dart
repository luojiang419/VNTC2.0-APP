import 'package:flutter/services.dart';

class RemoteAssistAndroidBridge {
  RemoteAssistAndroidBridge._();

  static final RemoteAssistAndroidBridge instance =
      RemoteAssistAndroidBridge._();

  static const MethodChannel _channel =
      MethodChannel('top.wherewego.vnt/remote_assist_android');

  Future<RemoteAssistAndroidStatus> getStatus() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return RemoteAssistAndroidStatus.fromMap(
        result ?? const <String, dynamic>{});
  }

  Future<void> refreshState() async {
    await _channel.invokeMethod<void>('refreshState');
  }

  Future<void> requestPermission(String permission) async {
    await _channel.invokeMethod<void>(
      'requestPermission',
      <String, dynamic>{'permission': permission},
    );
  }

  Future<void> openSystemSettings(String section) async {
    await _channel.invokeMethod<void>(
      'openSystemSettings',
      <String, dynamic>{'section': section},
    );
  }

  Future<void> startControlledService() async {
    await _channel.invokeMethod<void>('startControlledService');
  }

  Future<void> stopControlledService() async {
    await _channel.invokeMethod<void>('stopControlledService');
  }

  Future<void> connectByVirtualIp(
    String virtualIp, {
    String? password,
  }) async {
    await _channel.invokeMethod<void>(
      'connectByVirtualIp',
      <String, dynamic>{
        'virtualIp': virtualIp,
        'password': password,
      },
    );
  }

  Future<void> setAccessPassword(String password) async {
    await _channel.invokeMethod<void>(
      'setAccessPassword',
      <String, dynamic>{'password': password},
    );
  }
}

class RemoteAssistAndroidStatus {
  const RemoteAssistAndroidStatus({
    required this.notificationPermissionGranted,
    required this.screenCapturePermissionGranted,
    required this.screenCaptureActive,
    required this.screenCaptureState,
    required this.screenCaptureError,
    required this.screenCaptureRequestPending,
    required this.accessibilityPermissionGranted,
    required this.accessibilitySettingEnabled,
    required this.inputDispatchState,
    required this.lastInputDispatchAtEpochMs,
    required this.inputDispatchError,
    required this.overlayPermissionGranted,
    required this.batteryOptimizationIgnored,
    required this.controllerAvailable,
    required this.controlledRoleSupported,
    required this.controlledRuntimeReady,
    required this.controlledServiceRunning,
    required this.permissionsReady,
    required this.listenerReady,
    required this.runtimeVersion,
    required this.runtimeAvailable,
    required this.serviceInstalled,
    required this.serviceRunning,
    required this.portListening,
  });

  final bool notificationPermissionGranted;
  final bool screenCapturePermissionGranted;
  final bool screenCaptureActive;
  final String screenCaptureState;
  final String screenCaptureError;
  final bool screenCaptureRequestPending;
  final bool accessibilityPermissionGranted;
  final bool accessibilitySettingEnabled;
  final String inputDispatchState;
  final int lastInputDispatchAtEpochMs;
  final String inputDispatchError;
  final bool overlayPermissionGranted;
  final bool batteryOptimizationIgnored;
  final bool controllerAvailable;
  final bool controlledRoleSupported;
  final bool controlledRuntimeReady;
  final bool controlledServiceRunning;
  final bool permissionsReady;
  final bool listenerReady;
  final String runtimeVersion;
  final bool runtimeAvailable;
  final bool serviceInstalled;
  final bool serviceRunning;
  final bool portListening;

  factory RemoteAssistAndroidStatus.fromMap(Map<String, dynamic> map) {
    bool readBool(String key, [bool fallback = false]) {
      final value = map[key];
      if (value is bool) {
        return value;
      }
      if (value is num) {
        return value != 0;
      }
      final normalized = value?.toString().trim().toLowerCase();
      if (normalized == 'true') {
        return true;
      }
      if (normalized == 'false') {
        return false;
      }
      return fallback;
    }

    int readInt(String key) {
      final value = map[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return RemoteAssistAndroidStatus(
      notificationPermissionGranted: readBool('notificationPermissionGranted'),
      screenCapturePermissionGranted:
          readBool('screenCapturePermissionGranted'),
      screenCaptureActive: readBool('screenCaptureActive'),
      screenCaptureState: (map['screenCaptureState'] ?? 'idle').toString(),
      screenCaptureError: (map['screenCaptureError'] ?? '').toString(),
      screenCaptureRequestPending: readBool('screenCaptureRequestPending'),
      accessibilityPermissionGranted:
          readBool('accessibilityPermissionGranted'),
      accessibilitySettingEnabled: readBool('accessibilitySettingEnabled'),
      inputDispatchState: (map['inputDispatchState'] ?? 'idle').toString(),
      lastInputDispatchAtEpochMs: readInt('lastInputDispatchAtEpochMs'),
      inputDispatchError: (map['inputDispatchError'] ?? '').toString(),
      overlayPermissionGranted: readBool('overlayPermissionGranted'),
      batteryOptimizationIgnored: readBool('batteryOptimizationIgnored'),
      controllerAvailable: readBool('controllerAvailable'),
      controlledRoleSupported: readBool('controlledRoleSupported'),
      controlledRuntimeReady: readBool('controlledRuntimeReady'),
      controlledServiceRunning: readBool('controlledServiceRunning'),
      permissionsReady: readBool('permissionsReady'),
      listenerReady: readBool('listenerReady'),
      runtimeVersion: (map['runtimeVersion'] ?? '').toString(),
      runtimeAvailable: readBool('runtimeAvailable', true),
      serviceInstalled: readBool('serviceInstalled', true),
      serviceRunning: readBool('serviceRunning'),
      portListening: readBool('portListening'),
    );
  }
}

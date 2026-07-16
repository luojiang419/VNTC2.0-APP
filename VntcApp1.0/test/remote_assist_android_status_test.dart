import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_android_bridge.dart';

void main() {
  test('Android 受控服务运行不等于远控端口已监听', () {
    final status = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'controlledServiceRunning': true,
        'controlledRuntimeReady': false,
        'listenerReady': false,
        'serviceRunning': true,
        'portListening': false,
      },
    );

    expect(status.controlledServiceRunning, isTrue);
    expect(status.serviceRunning, isTrue);
    expect(status.controlledRuntimeReady, isFalse);
    expect(status.listenerReady, isFalse);
    expect(status.portListening, isFalse);
  });

  test('Android 远控端口真实监听后运行时才就绪', () {
    final status = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'controlledServiceRunning': true,
        'controlledRuntimeReady': true,
        'listenerReady': true,
        'serviceRunning': true,
        'portListening': true,
      },
    );

    expect(status.controlledRuntimeReady, isTrue);
    expect(status.listenerReady, isTrue);
    expect(status.portListening, isTrue);
  });

  test('Android 无障碍设置已勾选不等于输入服务已连接', () {
    final status = RemoteAssistAndroidStatus.fromMap(const <String, dynamic>{
      'accessibilityPermissionGranted': false,
      'accessibilitySettingEnabled': true,
      'permissionsReady': false,
    });

    expect(status.accessibilitySettingEnabled, isTrue);
    expect(status.accessibilityPermissionGranted, isFalse);
    expect(status.permissionsReady, isFalse);
  });

  test('Android 录屏授权请求状态与可用状态分开解析', () {
    final requesting = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'screenCapturePermissionGranted': false,
        'screenCaptureState': 'requesting',
        'screenCaptureRequestPending': true,
      },
    );
    final ready = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'screenCapturePermissionGranted': true,
        'screenCaptureState': 'ready',
        'screenCaptureRequestPending': false,
      },
    );

    expect(requesting.screenCapturePermissionGranted, isFalse);
    expect(requesting.screenCaptureRequestPending, isTrue);
    expect(requesting.screenCaptureState, 'requesting');
    expect(ready.screenCapturePermissionGranted, isTrue);
    expect(ready.screenCaptureRequestPending, isFalse);
    expect(ready.screenCaptureState, 'ready');
  });

  test('Android 录屏失败原因会保留给界面诊断', () {
    final status = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'screenCaptureState': 'error',
        'screenCaptureError': 'projection_init_failed',
      },
    );

    expect(status.screenCaptureState, 'error');
    expect(status.screenCaptureError, 'projection_init_failed');
  });

  test('Android 远程输入回执会区分服务连接与手势执行结果', () {
    final status = RemoteAssistAndroidStatus.fromMap(
      const <String, dynamic>{
        'accessibilityPermissionGranted': true,
        'inputDispatchState': 'failed',
        'lastInputDispatchAtEpochMs': 123456,
        'inputDispatchError': '系统拒绝分发远程手势',
      },
    );

    expect(status.accessibilityPermissionGranted, isTrue);
    expect(status.inputDispatchState, 'failed');
    expect(status.lastInputDispatchAtEpochMs, 123456);
    expect(status.inputDispatchError, '系统拒绝分发远程手势');
  });

  test('Android 受控启动会串行等待录屏与 49999 监听真正就绪', () {
    final runtime = File(
      'lib/remote_assist/remote_assist_android_runtime.dart',
    ).readAsStringSync();
    final nativeService = File(
      'vntcrustdesk-src/flutter/android/app/src/main/kotlin/'
      'com/carriez/flutter_hbb/MainService.kt',
    ).readAsStringSync();

    expect(runtime, contains('_controlledStartCompleter'));
    expect(runtime, contains('if (!hbb_common.gFFI.serverModel.isStart)'));
    expect(runtime, contains('await _waitForControlledRuntime()'));
    expect(runtime, contains('status.listenerReady'));
    expect(
        nativeService, contains('Intent(this, VntMainActivity::class.java)'));
  });

  test('Android 原生生命周期不越权写输入服务且拒绝空录屏会话', () {
    final mainActivity = File(
      'vntcrustdesk-src/flutter/android/app/src/main/kotlin/'
      'com/carriez/flutter_hbb/MainActivity.kt',
    ).readAsStringSync();
    final inputService = File(
      'vntcrustdesk-src/flutter/android/app/src/main/kotlin/'
      'com/carriez/flutter_hbb/InputService.kt',
    ).readAsStringSync();
    final mainService = File(
      'vntcrustdesk-src/flutter/android/app/src/main/kotlin/'
      'com/carriez/flutter_hbb/MainService.kt',
    ).readAsStringSync();

    expect(mainActivity, contains('InputService.disconnect()'));
    expect(mainActivity, isNot(contains('InputService.ctx =')));
    expect(inputService, contains('fun disconnect()'));
    expect(
      mainService,
      contains('?: throw IllegalStateException('),
    );
  });
}

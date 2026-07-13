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
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_method_channel.dart';

void main() {
  MethodChannelFlutterGpuTextureRenderer platform = MethodChannelFlutterGpuTextureRenderer();
  const MethodChannel channel = MethodChannel('flutter_gpu_texture_renderer');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return '42';
    });
  });

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });
}

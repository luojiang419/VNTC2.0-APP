import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_platform_interface.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterGpuTextureRendererPlatform
    with MockPlatformInterfaceMixin
    implements FlutterGpuTextureRendererPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterGpuTextureRendererPlatform initialPlatform = FlutterGpuTextureRendererPlatform.instance;

  test('$MethodChannelFlutterGpuTextureRenderer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterGpuTextureRenderer>());
  });

  test('getPlatformVersion', () async {
    FlutterGpuTextureRenderer flutterGpuTextureRendererPlugin = FlutterGpuTextureRenderer();
    MockFlutterGpuTextureRendererPlatform fakePlatform = MockFlutterGpuTextureRendererPlatform();
    FlutterGpuTextureRendererPlatform.instance = fakePlatform;

    expect(await flutterGpuTextureRendererPlugin.getPlatformVersion(), '42');
  });
}

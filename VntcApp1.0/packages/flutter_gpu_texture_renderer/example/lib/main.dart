import 'dart:ffi';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_gpu_texture_renderer/flutter_gpu_texture_renderer.dart';
import 'package:window_manager/window_manager.dart';

import 'generated_bindings.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  final _flutterGpuTextureRendererPlugin = FlutterGpuTextureRenderer();
  final _duplicationLib = NativeLibrary(DynamicLibrary.open("duplication.dll"));
  final _pluginLib = NativeLibrary(
      DynamicLibrary.open("flutter_gpu_texture_renderer_plugin.dll"));
  var _count = 1;

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    _duplicationLib.StopDuplicateThread();
  }

  @override
  Widget build(BuildContext context) {
    bool isSingleItem = _count == 1;
    final size = MediaQuery.of(context).size;
    final screenWidth = size.width;
    final screenHeight = size.height;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Text('Plugin example app'),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text("Count:$_count")),
              ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _count++;
                    });
                  },
                  child: const Text('+')),
              ElevatedButton(
                  onPressed: () {
                    if (_count > 0) {
                      setState(() {
                        _count--;
                      });
                    }
                  },
                  child: const Text('-')),
            ],
          ),
        ),
        body: GridView.count(
          crossAxisCount: isSingleItem ? 1 : 2,
          childAspectRatio: isSingleItem ? 2 : 1,
          children: List.generate(
            _count,
            (index) => Padding(
              padding: EdgeInsets.all(isSingleItem ? 0 : 5),
              child: SizedBox(
                width: screenWidth,
                height: screenHeight,
                child: VideoOutput(
                    plugin: _flutterGpuTextureRendererPlugin,
                    pluginlib: _pluginLib,
                    duplib: _duplicationLib),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VideoOutput extends StatefulWidget {
  final FlutterGpuTextureRenderer plugin;
  final NativeLibrary pluginlib;
  final NativeLibrary duplib;
  const VideoOutput(
      {Key? key,
      required this.plugin,
      required this.pluginlib,
      required this.duplib})
      : super(key: key);

  @override
  State<VideoOutput> createState() => _VideoOutputState();
}

class _VideoOutputState extends State<VideoOutput> {
  int? _textureId;
  FlutterGpuTextureRenderer get plugin => widget.plugin;
  NativeLibrary get pluginlib => widget.pluginlib;
  NativeLibrary get duplib => widget.duplib;
  int _fps = 0;
  Timer? timer;
  int? output;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    debugPrint("dispose");
    super.dispose();
    timer?.cancel();
    if (output != null) {
      widget.duplib.RemoveOutput(Pointer.fromAddress(output!));
    }
    if (_textureId != null) {
      widget.plugin.unregisterTexture(_textureId!);
    }
  }

  Future<void> initPlatformState() async {
    try {
      _textureId = await widget.plugin.registerTexture();
      if (_textureId != null) {
        final luid =
            pluginlib.FlutterGpuTextureRendererPluginCApiGetAdapterLuid();
        output = await plugin.output(_textureId!);
        if (mounted) {
          setState(() {});
        }
        if (output != null) {
          duplib.StartDuplicateThread(luid);
          duplib.AddOutput(Pointer.fromAddress(output!));
          timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
            int? fps = await widget.plugin.fps(_textureId!);
            if (mounted) {
              setState(() {
                _fps = fps ?? 0;
              });
            }
          });
        }
      }
    } on PlatformException {
      debugPrint("platform exception");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      child: _textureId != null
          ? Stack(
              children: [
                Texture(textureId: _textureId!),
                Positioned(
                    top: 0,
                    right: 0,
                    child: Text(
                      "FPS: $_fps",
                      style: const TextStyle(fontSize: 30, color: Colors.green),
                    ))
              ],
            )
          : const Text("_textureId is null"),
    );
  }
}

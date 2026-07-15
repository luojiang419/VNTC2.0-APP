import 'package:flutter/material.dart';

import '../core/design_system/app_motion.dart';
import '../core/design_system/app_theme.dart';
import 'app_controller.dart';
import 'app_shell.dart';

class VntsConsoleApp extends StatefulWidget {
  const VntsConsoleApp({super.key, this.controller});

  static const title = 'VNTS 2.0 增强控制台';

  final AppController? controller;

  @override
  State<VntsConsoleApp> createState() => _VntsConsoleAppState();
}

class _VntsConsoleAppState extends State<VntsConsoleApp> {
  late final AppController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AppController.inMemory();
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: VntsConsoleApp.title,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _controller.themeMode,
        themeAnimationDuration: AppMotion.theme,
        home: AppShell(controller: _controller),
      ),
    );
  }
}

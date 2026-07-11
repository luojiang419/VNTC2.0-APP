import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' as hbb_common;
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/desktop/widgets/refresh_wrapper.dart';
import 'package:flutter_hbb/mobile/pages/remote_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:vnt_app/app_navigation.dart';
import 'package:vnt_app/remote_assist/remote_assist_android_runtime.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';

class EmbeddedRemoteAssistLauncher {
  EmbeddedRemoteAssistLauncher._();

  static Future<void> launch({
    required String virtualIp,
    String? password,
  }) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      throw StateError('应用导航尚未初始化，暂时无法打开内置远控会话');
    }

    await _ensureBootstrapped();

    await navigator.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _EmbeddedRemoteAssistShell(
          virtualIp: virtualIp,
          password: password,
        ),
      ),
    );
  }

  static Future<void> _ensureBootstrapped() async {
    await RemoteAssistAndroidRuntime.instance.ensureInitialized();
    draggablePositions.load();
  }
}

class _EmbeddedRemoteAssistShell extends StatelessWidget {
  const _EmbeddedRemoteAssistShell({
    required this.virtualIp,
    required this.password,
  });

  final String virtualIp;
  final String? password;

  @override
  Widget build(BuildContext context) {
    return RefreshWrapper(
      builder: (context) {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: hbb_common.gFFI.ffiModel),
            ChangeNotifierProvider.value(value: hbb_common.gFFI.imageModel),
            ChangeNotifierProvider.value(value: hbb_common.gFFI.cursorModel),
            ChangeNotifierProvider.value(value: hbb_common.gFFI.canvasModel),
            ChangeNotifierProvider.value(value: hbb_common.gFFI.peerTabModel),
          ],
          child: GetMaterialApp(
            navigatorKey: hbb_common.globalKey,
            debugShowCheckedModeBanner: false,
            title: 'VNT 远程协助',
            theme: hbb_common.MyTheme.lightTheme,
            darkTheme: hbb_common.MyTheme.darkTheme,
            themeMode: hbb_common.MyTheme.currentThemeMode(),
            home: _EmbeddedRemoteAssistEntryPage(
              virtualIp: virtualIp,
              password: password,
            ),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: hbb_common.supportedLocales,
            navigatorObservers: [
              BotToastNavigatorObserver(),
            ],
            builder: (context, child) {
              if (Platform.isAndroid) {
                return hbb_common.AccessibilityListener(
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: const TextScaler.linear(1.0),
                    ),
                    child: child ?? const SizedBox.shrink(),
                  ),
                );
              }
              return child ?? const SizedBox.shrink();
            },
          ),
        );
      },
    );
  }
}

class _EmbeddedRemoteAssistEntryPage extends StatefulWidget {
  const _EmbeddedRemoteAssistEntryPage({
    required this.virtualIp,
    required this.password,
  });

  final String virtualIp;
  final String? password;

  @override
  State<_EmbeddedRemoteAssistEntryPage> createState() =>
      _EmbeddedRemoteAssistEntryPageState();
}

class _EmbeddedRemoteAssistEntryPageState
    extends State<_EmbeddedRemoteAssistEntryPage> {
  bool _launchScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_launchScheduled) {
      return;
    }
    _launchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final sessionNavigator = Navigator.of(context);
      await sessionNavigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/session'),
          builder: (_) => RemotePage(
            id: '${widget.virtualIp}:${RemoteAssistConstants.directAccessPort}',
            password: widget.password,
          ),
        ),
      );
      if (!mounted) {
        return;
      }
      final rootNavigator = appNavigatorKey.currentState;
      if (rootNavigator != null && rootNavigator.canPop()) {
        rootNavigator.pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: hbb_common.MyTheme.canvasColor,
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}

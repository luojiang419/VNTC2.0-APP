import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/networking/api_client.dart';
import '../core/platform/portable_layout.dart';
import '../core/platform/service_operations.dart';
import '../core/platform/windows_startup_manager.dart';
import '../core/storage/app_preferences.dart';
import '../features/settings/data/server_config_repository.dart';
import 'app.dart';
import 'app_controller.dart';

Future<void> bootstrap({List<String> arguments = const []}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await AppPreferences.load();
  final apiPort = _portArgument(arguments, '--api-port', 39871);
  final tunnelPort = _portArgument(arguments, '--tunnel-port', 39872);
  final silentStart =
      Platform.isWindows &&
      arguments.any((argument) => argument.toLowerCase() == '--silent');
  final serviceName =
      _stringArgument(arguments, '--service-name') ??
      ServiceOperations.defaultServiceName;
  final portableLayout = PortableLayout.discover();
  final serviceOperations = portableLayout == null
      ? null
      : ServiceOperations(
          portableLayout,
          serviceName: serviceName,
          apiPort: apiPort,
          tunnelPort: tunnelPort,
        );
  final controller = AppController(
    themeMode: preferences.themeMode,
    dashboardPollSeconds: preferences.dashboardPollSeconds,
    preferences: preferences,
    apiClient: ApiClient.loopback(port: apiPort),
    configRepository: portableLayout == null
        ? null
        : ServerConfigRepository(portableLayout.config),
    autoLockHours: preferences.autoLockHours,
    lockShortcut: preferences.lockShortcut,
    closeBehavior: preferences.closeBehavior,
    startupBehavior: preferences.startupBehavior,
    startupManager: Platform.isWindows ? WindowsStartupManager() : null,
    serviceOperations: serviceOperations,
  );
  await controller.initializeIntegratedService();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    final options = WindowOptions(
      size: Size(1440, 900),
      minimumSize: Size(1180, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: silentStart,
      title: VntsConsoleApp.title,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await controller.initializeWindowsShell(silentStart: silentStart);
      if (!silentStart) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  runApp(VntsConsoleApp(controller: controller));
  if (silentStart) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(controller.minimizeToTray(showMessage: false));
    });
  }
}

int _portArgument(List<String> arguments, String name, int fallback) {
  final value = int.tryParse(_stringArgument(arguments, name) ?? '');
  return value != null && value >= 1 && value <= 65535 ? value : fallback;
}

String? _stringArgument(List<String> arguments, String name) {
  final prefix = '$name=';
  for (final argument in arguments) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}

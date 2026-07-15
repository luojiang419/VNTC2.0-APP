import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/design_system/app_theme.dart';
import 'package:vnts_console/core/platform/desktop_behavior.dart';
import 'package:vnts_console/core/security/console_lock_shortcut.dart';
import 'package:vnts_console/features/settings/controller/server_config_controller.dart';
import 'package:vnts_console/features/settings/data/server_config_repository.dart';
import 'package:vnts_console/features/settings/view/settings_shell_page.dart';

void main() {
  testWidgets('服务配置在最小窗口和放大文本下不裁切浮动标签', (tester) async {
    late final Directory root;
    late final ServerConfigController controller;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('vnts2-config-ui-');
      final config = File('${root.path}${Platform.pathSeparator}config.toml');
      await config.writeAsString('''
tcp_bind = "0.0.0.0:2222"
quic_bind = "0.0.0.0:2222"
ws_bind = "0.0.0.0:2222"
network = "10.26.0.0/24"
white_list = ["game"]
lease_duration = 86400
web_bind = "127.0.0.1:29871"
username = "admin"
password = "x"
persistence = true
wireguard_max_active_peers = 4096

[custom_nets]
''');
      controller = ServerConfigController(ServerConfigRepository(config), null);
      await controller.load();
    });
    addTearDown(() => root.delete(recursive: true));
    addTearDown(controller.dispose);

    for (final size in [
      const Size(1180, 720),
      const Size(1440, 900),
      const Size(1920, 1080),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.25)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ServerConfigSection(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('默认网络 CIDR'), findsOneWidget);
      expect(find.text('租约时长（秒）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final labelRect = tester.getRect(find.text('默认网络 CIDR'));
      final tileRect = tester.getRect(find.byType(ExpansionTile).first);
      expect(labelRect.top, greaterThan(tileRect.top + 50));
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('关闭与开机行为在最小窗口和放大文本下完整显示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: SettingsShellPage(
            themeMode: ThemeMode.dark,
            onThemeModeChanged: (_) {},
            dashboardPollSeconds: 1,
            onDashboardPollSecondsChanged: (_) {},
            autoLockHours: 2,
            onAutoLockHoursChanged: (_) {},
            lockShortcut: ConsoleLockShortcut.controlShiftL,
            onLockShortcutChanged: (_) {},
            adminUsername: 'admin',
            onChangeAdminCredentials: (_, _) async => true,
            onLock: () {},
            closeBehavior: AppCloseBehavior.minimizeToTray,
            onCloseBehaviorChanged: (_) {},
            startupBehavior: AppStartupBehavior.silentToTray,
            onStartupBehaviorChanged: (_) async => true,
            desktopBehaviorBusy: false,
            desktopBehaviorMessage: '开机行为已设为静默托盘运行',
            onExecuteCloseBehavior: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('desktop-behavior-card')), findsOneWidget);
    expect(find.text('默认关闭行为'), findsOneWidget);
    expect(find.text('开机自启行为'), findsOneWidget);
    expect(find.text('立即最小化到托盘'), findsOneWidget);
    expect(find.text('关闭服务并退出'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

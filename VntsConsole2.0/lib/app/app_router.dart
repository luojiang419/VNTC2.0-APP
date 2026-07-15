import 'package:flutter/material.dart';

import '../features/dashboard/view/dashboard_placeholder_page.dart';
import '../features/logs/view/logs_page.dart';
import '../features/networks/view/device_management_page.dart';
import '../features/networks/view/network_management_page.dart';
import '../features/peer_servers/view/peer_servers_page.dart';
import '../features/settings/view/settings_shell_page.dart';
import '../features/service_control/view/service_control_page.dart';
import '../features/wireguard/view/wireguard_page.dart';
import 'app_controller.dart';
import 'app_routes.dart';

class AppRouter extends StatelessWidget {
  const AppRouter({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: switch (controller.route) {
        AppRoute.dashboard => DashboardPlaceholderPage(
          key: ValueKey(AppRoute.dashboard),
          apiClient: controller.apiClient,
          onConnectionChanged: controller.updateServiceConnection,
          onRestartService: controller.serviceOperations == null
              ? null
              : controller.restartService,
          pollInterval: Duration(seconds: controller.dashboardPollSeconds),
        ),
        AppRoute.networks => NetworkManagementPage(
          key: const ValueKey(AppRoute.networks),
          apiClient: controller.apiClient,
        ),
        AppRoute.devices => DeviceManagementPage(
          key: const ValueKey(AppRoute.devices),
          apiClient: controller.apiClient,
        ),
        AppRoute.wireGuard => WireGuardPage(
          key: const ValueKey(AppRoute.wireGuard),
          apiClient: controller.apiClient,
        ),
        AppRoute.peerServers => PeerServersPage(
          key: const ValueKey(AppRoute.peerServers),
          apiClient: controller.apiClient,
        ),
        AppRoute.serviceControl => ServiceControlPage(
          key: const ValueKey(AppRoute.serviceControl),
          operations: controller.serviceOperations,
          apiClient: controller.apiClient,
          layout: controller.serviceOperations?.layout,
          onConnectionChanged: controller.updateServiceConnection,
          adminUsername: controller.knownUsername,
          onLock: controller.lockNow,
          onChangeAdminCredentials: controller.changeAdminCredentials,
        ),
        AppRoute.logs => LogsPage(
          key: const ValueKey(AppRoute.logs),
          layout: controller.serviceOperations?.layout,
        ),
        AppRoute.settings => SettingsShellPage(
          key: const ValueKey(AppRoute.settings),
          themeMode: controller.themeMode,
          onThemeModeChanged: controller.setThemeMode,
          dashboardPollSeconds: controller.dashboardPollSeconds,
          onDashboardPollSecondsChanged: controller.setDashboardPollSeconds,
          autoLockHours: controller.autoLockHours,
          onAutoLockHoursChanged: controller.setAutoLockHours,
          lockShortcut: controller.lockShortcut,
          onLockShortcutChanged: controller.setLockShortcut,
          adminUsername: controller.knownUsername,
          onChangeAdminCredentials: controller.changeAdminCredentials,
          onLock: controller.lockNow,
          closeBehavior: controller.closeBehavior,
          onCloseBehaviorChanged: controller.setCloseBehavior,
          startupBehavior: controller.startupBehavior,
          onStartupBehaviorChanged: controller.setStartupBehavior,
          desktopBehaviorBusy: controller.desktopBehaviorBusy,
          desktopBehaviorMessage: controller.desktopBehaviorMessage,
          onExecuteCloseBehavior: controller.executeCloseBehavior,
          layout: controller.serviceOperations?.layout,
          operations: controller.serviceOperations,
        ),
      },
    );
  }
}

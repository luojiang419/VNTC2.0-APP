import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/networking/api_client.dart';
import 'package:vnts_console/core/platform/portable_layout.dart';
import 'package:vnts_console/core/platform/service_operations.dart';
import 'package:vnts_console/features/service_control/controller/service_control_controller.dart';
import 'package:vnts_console/features/service_control/view/service_control_page.dart';
import 'package:vnts_console/features/settings/data/server_config_repository.dart';

void main() {
  testWidgets('管理员凭据对话框允许短密码并要求二次确认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _DialogController();
    String? savedUsername;
    String? savedPassword;

    await tester.pumpWidget(
      MaterialApp(
        home: ServiceControlPage(
          controller: controller,
          onChangeAdminCredentials: (username, password) async {
            savedUsername = username;
            savedPassword = password;
            return true;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final changeButton = find.byKey(
      const Key('change-admin-credentials-service'),
    );
    await tester.ensureVisible(changeButton);
    await tester.tap(changeButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const Key('new-admin-password')), 'x');
    await tester.enterText(
      find.byKey(const Key('confirm-admin-password')),
      'x',
    );
    await tester.tap(find.byKey(const Key('save-admin-credentials')));
    await tester.pumpAndSettle();
    expect(savedUsername, 'admin');
    expect(savedPassword, 'x');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test('控制器在配置备份后重启服务并清除旧会话', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'vnts2-console-password-controller-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final config = File(
      '${temporary.path}${Platform.pathSeparator}config.toml',
    );
    await _writeConfig(config);
    final layout = PortableLayout.discover(
      overrideRoot: Directory('../vnts2.0服务端开发包/windows-deploy').absolute.path,
    )!;
    final operations = _PasswordOperations(layout);
    final apiClient = ApiClient.loopback();
    final controller = ServiceControlController(
      operations: operations,
      apiClient: apiClient,
      configRepository: ServerConfigRepository(config),
    );
    addTearDown(controller.dispose);
    addTearDown(apiClient.close);

    const updatedPassword = 'x';
    expect(await controller.changeApiPassword(updatedPassword), isTrue);

    expect(
      await config.readAsString(),
      contains('password = "$updatedPassword"'),
    );
    expect(operations.actions, contains(ServiceAction.restart));
    expect(
      await config.parent
          .list()
          .where((entity) => entity is Directory)
          .any((entity) => entity.path.endsWith('.backups')),
      isTrue,
    );
  });
}

Future<void> _writeConfig(File config) {
  return config.writeAsString('''
tcp_bind = "127.0.0.1:29872"
quic_bind = "127.0.0.1:29872"
ws_bind = "127.0.0.1:29872"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
web_bind = "127.0.0.1:29871"
username = "admin"
password = "VNTS"
persistence = true
wireguard_max_active_peers = 4096

[custom_nets]
''');
}

class _PasswordOperations extends ServiceOperations {
  _PasswordOperations(super.layout);

  final List<ServiceAction> actions = [];

  @override
  Future<WindowsServiceStatus> status() async {
    return const WindowsServiceStatus(
      installed: true,
      state: 'Running',
      processId: 123,
      portableLayout: true,
    );
  }

  @override
  Future<List<DiagnosticCheck>> run(
    ServiceAction action, {
    String? updateSource,
  }) async {
    actions.add(action);
    return const [];
  }
}

class _DialogController extends ServiceControlController {
  @override
  Future<void> refreshStatus() async {}
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/app/app_controller.dart';
import 'package:vnts_console/core/networking/api_client.dart';
import 'package:vnts_console/core/platform/portable_layout.dart';
import 'package:vnts_console/core/platform/service_operations.dart';
import 'package:vnts_console/features/settings/data/server_config_repository.dart';

void main() {
  test('首次设置接受短密码、删除标记并进入已认证状态', () async {
    final fixture = await _SecurityFixture.create();
    addTearDown(fixture.dispose);

    await fixture.controller.initializeIntegratedService();
    expect(fixture.controller.accessState, ConsoleAccessState.setupRequired);

    expect(await fixture.controller.completeInitialSetup('admin', 'x'), isTrue);
    expect(fixture.controller.accessState, ConsoleAccessState.authenticated);
    expect(fixture.apiClient.lastUsername, 'admin');
    expect(fixture.apiClient.lastPassword, 'x');
    expect(await fixture.layout.initialSetupMarker.exists(), isFalse);
    expect(
      await fixture.layout.config.readAsString(),
      allOf(contains('username = "admin"'), contains('password = "x"')),
    );
    expect(fixture.operations.actions, contains(ServiceAction.restart));
  });

  test('管理员凭据修改后立即清除会话并强制重新登录', () async {
    final fixture = await _SecurityFixture.create();
    addTearDown(fixture.dispose);
    await fixture.controller.initializeIntegratedService();
    await fixture.controller.completeInitialSetup('admin', 'x');

    expect(
      await fixture.controller.changeAdminCredentials('operator', 'y'),
      isTrue,
    );
    expect(fixture.controller.accessState, ConsoleAccessState.loginRequired);
    expect(fixture.apiClient.hasSession, isFalse);
    expect(fixture.controller.knownUsername, 'operator');
    expect(
      await fixture.layout.config.readAsString(),
      allOf(contains('username = "operator"'), contains('password = "y"')),
    );
  });

  test('达到无操作时长后自动锁定并隐藏认证状态', () async {
    final apiClient = _SecurityApiClient();
    final controller = AppController(
      themeMode: ThemeMode.system,
      apiClient: apiClient,
      autoLockHours: 1,
      autoLockDelayOverride: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    addTearDown(apiClient.close);

    await controller.login('admin', 'x');
    expect(controller.isAuthenticated, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.accessState, ConsoleAccessState.locked);
  });
}

class _SecurityFixture {
  _SecurityFixture({
    required this.root,
    required this.layout,
    required this.operations,
    required this.apiClient,
    required this.controller,
  });

  final Directory root;
  final PortableLayout layout;
  final _SecurityOperations operations;
  final _SecurityApiClient apiClient;
  final AppController controller;

  static Future<_SecurityFixture> create() async {
    final root = await Directory.systemTemp.createTemp('vnts2-security-');
    for (final script in PortableLayout.requiredScripts) {
      await File('${root.path}${Platform.pathSeparator}$script').create();
    }
    final layout = PortableLayout.discover(overrideRoot: root.path)!;
    await layout.dataDirectory.create(recursive: true);
    await layout.config.writeAsString('''
tcp_bind = "127.0.0.1:29872"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
web_bind = "127.0.0.1:29871"
username = "bootstrap-admin"
password = "temporary-bootstrap-secret"
persistence = true
wireguard_max_active_peers = 4096

[custom_nets]
''');
    await layout.initialSetupMarker.writeAsString('setup-required');
    final operations = _SecurityOperations(layout);
    final apiClient = _SecurityApiClient();
    final controller = AppController(
      themeMode: ThemeMode.system,
      apiClient: apiClient,
      serviceOperations: operations,
      configRepository: ServerConfigRepository(layout.config),
      autoLockHours: 0,
    );
    return _SecurityFixture(
      root: root,
      layout: layout,
      operations: operations,
      apiClient: apiClient,
      controller: controller,
    );
  }

  Future<void> dispose() async {
    controller.dispose();
    apiClient.close();
    await root.delete(recursive: true);
  }
}

class _SecurityOperations extends ServiceOperations {
  _SecurityOperations(super.layout);

  final List<ServiceAction> actions = [];

  @override
  Future<IntegratedServiceBootstrapResult> ensureIntegratedService() async {
    return const IntegratedServiceBootstrapResult(
      ready: true,
      state: 'Running',
      processId: 123,
      configCreated: true,
      initialSetupRequired: true,
      apiEndpoint: '127.0.0.1:29871',
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

class _SecurityApiClient extends ApiClient {
  _SecurityApiClient()
    : super(baseUri: Uri.parse('http://127.0.0.1:29871/api/'));

  String? lastUsername;
  String? lastPassword;
  bool _loggedIn = false;

  @override
  bool get hasSession => _loggedIn;

  @override
  Future<void> login({
    required String username,
    required String password,
  }) async {
    lastUsername = username;
    lastPassword = password;
    _loggedIn = true;
  }

  @override
  void clearSession() {
    _loggedIn = false;
    super.clearSession();
  }
}

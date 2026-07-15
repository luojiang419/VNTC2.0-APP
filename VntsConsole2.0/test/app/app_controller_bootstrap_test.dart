import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/app/app_controller.dart';
import 'package:vnts_console/core/networking/api_client.dart';
import 'package:vnts_console/core/platform/portable_layout.dart';
import 'package:vnts_console/core/platform/service_operations.dart';

void main() {
  test('首次集成初始化后进入管理员首次设置门禁且不自动登录', () async {
    final layout = _testLayout();
    final apiClient = _BootstrapApiClient();
    final controller = AppController(
      themeMode: ThemeMode.system,
      apiClient: apiClient,
      serviceOperations: _BootstrapOperations(layout),
    );
    addTearDown(controller.dispose);
    addTearDown(apiClient.close);

    await controller.initializeIntegratedService();

    expect(controller.integratedServiceState, IntegratedServiceState.ready);
    expect(
      controller.serviceConnectionStatus,
      ServiceConnectionStatus.authenticationRequired,
    );
    expect(controller.accessState, ConsoleAccessState.setupRequired);
    expect(apiClient.username, isNull);
    expect(apiClient.password, isNull);
    expect(apiClient.hasSession, isFalse);
  });

  test('集成初始化失败时显示 PowerShell 首条具体原因', () async {
    final layout = _testLayout();
    final controller = AppController(
      themeMode: ThemeMode.system,
      serviceOperations: _FailingBootstrapOperations(layout),
    );
    addTearDown(controller.dispose);

    await controller.initializeIntegratedService();

    expect(controller.integratedServiceState, IntegratedServiceState.failed);
    expect(
      controller.integratedServiceMessage,
      allOf(contains('退出码 1'), contains('服务路径迁移失败')),
    );
  });
}

PortableLayout _testLayout() => PortableLayout.discover(
  overrideRoot: Directory('../vnts2.0服务端开发包/windows-deploy').absolute.path,
)!;

class _BootstrapOperations extends ServiceOperations {
  _BootstrapOperations(super.layout);

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
}

class _FailingBootstrapOperations extends ServiceOperations {
  _FailingBootstrapOperations(super.layout);

  @override
  Future<IntegratedServiceBootstrapResult> ensureIntegratedService() async {
    throw const ServiceOperationException(
      '准备集成服务失败（退出码 1）',
      details: '服务路径迁移失败\r\nAt initialize-vnts2-console.ps1:46',
    );
  }
}

class _BootstrapApiClient extends ApiClient {
  _BootstrapApiClient()
    : super(baseUri: Uri.parse('http://127.0.0.1:29871/api/'));

  String? username;
  String? password;
  bool loggedIn = false;

  @override
  bool get hasSession => loggedIn;

  @override
  Future<void> login({
    required String username,
    required String password,
  }) async {
    this.username = username;
    this.password = password;
    loggedIn = true;
  }
}

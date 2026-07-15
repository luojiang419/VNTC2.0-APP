import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/platform/portable_layout.dart';
import 'package:vnts_console/core/platform/service_operations.dart';

void main() {
  test('发现真实便携脚本目录并限制脚本白名单', () {
    final layout = _testLayout();
    expect(layout, isNotNull);
    expect(layout!.isComplete, isTrue);
    expect(() => layout.script('arbitrary.ps1'), throwsArgumentError);
  });

  test('PowerShell 使用 UTF-16LE EncodedCommand 与安全单引号', () {
    expect(
      PowerShellRunner.quote("D:\\O'Brien\\script.ps1"),
      "'D:\\O''Brien\\script.ps1'",
    );
    final encoded = PowerShellRunner.encodeCommand(r"Write-Output '中文'");
    final bytes = base64Decode(encoded);
    final codeUnits = <int>[];
    for (var index = 0; index < bytes.length; index += 2) {
      codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
    }
    final command = String.fromCharCodes(codeUnits);
    expect(command, contains(r'$ErrorActionPreference'));
    expect(command, contains("Write-Output '中文'"));
  });

  test('服务状态和重启只调用固定脚本与固定服务名', () async {
    final layout = _testLayout()!;
    final runner = _FakeRunner();
    final operations = ServiceOperations(layout, runner: runner);

    final status = await operations.status();
    expect(status.installed, isTrue);
    expect(status.isRunning, isTrue);
    expect(runner.commands.single, contains('status-vnts2-service.ps1'));
    expect(ServiceOperations.defaultServiceName, 'vnts2-console');
    expect(operations.serviceName, 'vnts2-console');
    expect(operations.apiPort, 39871);
    expect(operations.tunnelPort, 39872);
    expect(runner.commands.single, contains("-ServiceName 'vnts2-console'"));

    runner.commands.clear();
    await operations.run(ServiceAction.restart);
    expect(runner.commands.single, contains('stop-vnts2-service.ps1'));
    expect(runner.commands.single, contains('start-vnts2-service.ps1'));
  });

  test('集成初始化只调用白名单脚本并解析首次凭据状态', () async {
    final layout = _testLayout()!;
    final runner = _FakeRunner();
    final operations = ServiceOperations(
      layout,
      runner: runner,
      serviceName: 'vnts2-test',
      apiPort: 41231,
      tunnelPort: 41232,
    );

    final result = await operations.ensureIntegratedService();

    expect(result.ready, isTrue);
    expect(result.configCreated, isTrue);
    expect(result.initialSetupRequired, isTrue);
    expect(result.apiEndpoint, '127.0.0.1:41231');
    expect(runner.commands.single, contains('initialize-vnts2-console.ps1'));
    expect(runner.commands.single, contains("-ServiceName 'vnts2-test'"));
    expect(runner.commands.single, contains('-ApiPort 41231'));
    expect(runner.commands.single, contains('-TunnelPort 41232'));
  });
}

PortableLayout? _testLayout() => PortableLayout.discover(
  overrideRoot: Directory('../vnts2.0服务端开发包/windows-deploy').absolute.path,
);

class _FakeRunner extends PowerShellRunner {
  _FakeRunner() : super(Directory.current.path);

  final List<String> commands = [];

  @override
  Future<String> run(
    String body, {
    required String operation,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    commands.add(body);
    if (body.contains('initialize-vnts2-console.ps1')) {
      return jsonEncode({
        'Ready': true,
        'State': 'Running',
        'ProcessId': 456,
        'ConfigCreated': true,
        'InitialSetupRequired': true,
        'ApiEndpoint': '127.0.0.1:41231',
      });
    }
    if (body.contains('status-vnts2-service.ps1')) {
      return jsonEncode({
        'Installed': true,
        'State': 'Running',
        'ProcessId': 123,
        'PortableLayout': true,
      });
    }
    return '';
  }
}

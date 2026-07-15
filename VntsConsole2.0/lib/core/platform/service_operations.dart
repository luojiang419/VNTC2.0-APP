import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'portable_layout.dart';

enum ServiceAction {
  install,
  start,
  stop,
  restart,
  update,
  diagnose,
  uninstall,
}

class WindowsServiceStatus {
  const WindowsServiceStatus({
    required this.installed,
    required this.state,
    required this.processId,
    required this.portableLayout,
  });

  final bool installed;
  final String state;
  final int processId;
  final bool portableLayout;

  bool get isRunning => installed && state.toLowerCase() == 'running';

  factory WindowsServiceStatus.fromJson(Map<String, Object?> json) {
    return WindowsServiceStatus(
      installed: json['Installed'] == true,
      state: json['State'] is String ? json['State']! as String : 'Unknown',
      processId: json['ProcessId'] is num
          ? (json['ProcessId']! as num).toInt()
          : 0,
      portableLayout: json['PortableLayout'] == true,
    );
  }
}

class DiagnosticCheck {
  const DiagnosticCheck({
    required this.name,
    required this.status,
    required this.details,
  });

  final String name;
  final String status;
  final String details;

  factory DiagnosticCheck.fromJson(Map<String, Object?> json) =>
      DiagnosticCheck(
        name: json['Check']?.toString() ?? 'Unknown',
        status: json['Status']?.toString() ?? 'WARN',
        details: json['Details']?.toString() ?? '',
      );
}

class IntegratedServiceBootstrapResult {
  const IntegratedServiceBootstrapResult({
    required this.ready,
    required this.state,
    required this.processId,
    required this.configCreated,
    required this.initialSetupRequired,
    required this.apiEndpoint,
  });

  final bool ready;
  final String state;
  final int processId;
  final bool configCreated;
  final bool initialSetupRequired;
  final String? apiEndpoint;

  factory IntegratedServiceBootstrapResult.fromJson(Map<String, Object?> json) {
    return IntegratedServiceBootstrapResult(
      ready: json['Ready'] == true,
      state: json['State']?.toString() ?? 'Unknown',
      processId: json['ProcessId'] is num
          ? (json['ProcessId']! as num).toInt()
          : 0,
      configCreated: json['ConfigCreated'] == true,
      initialSetupRequired: json['InitialSetupRequired'] == true,
      apiEndpoint: json['ApiEndpoint']?.toString(),
    );
  }
}

class ServiceOperationException implements Exception {
  const ServiceOperationException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => message;
}

class ServiceOperations {
  ServiceOperations(
    this.layout, {
    PowerShellRunner? runner,
    String serviceName = defaultServiceName,
    this.apiPort = 39871,
    this.tunnelPort = 39872,
  }) : serviceName = _validateServiceName(serviceName),
       assert(apiPort >= 1 && apiPort <= 65535),
       assert(tunnelPort >= 1 && tunnelPort <= 65535),
       assert(apiPort != tunnelPort),
       _runner = runner ?? PowerShellRunner(layout.root.path);

  static const defaultServiceName = 'vnts2-console';

  final PortableLayout layout;
  final String serviceName;
  final int apiPort;
  final int tunnelPort;
  final PowerShellRunner _runner;

  static String _validateServiceName(String value) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'serviceName', 'Windows 服务名无效');
    }
    return value;
  }

  Future<IntegratedServiceBootstrapResult> ensureIntegratedService() async {
    final script = layout.script('initialize-vnts2-console.ps1').path;
    final output = await _runner.run(
      '\$value = & ${PowerShellRunner.quote(script)} '
      '-ServiceName ${PowerShellRunner.quote(serviceName)} '
      '-TargetDir ${PowerShellRunner.quote(layout.root.path)} '
      '-ApiPort $apiPort -TunnelPort $tunnelPort; '
      r'$value | ConvertTo-Json -Compress -Depth 5',
      operation: '准备集成服务',
    );
    final decoded = _decodeLastJson(output);
    if (decoded is! Map) {
      throw const ServiceOperationException('集成服务初始化脚本返回了无效结果');
    }
    final result = IntegratedServiceBootstrapResult.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (!result.ready) {
      throw ServiceOperationException('集成服务未进入运行状态：${result.state}');
    }
    return result;
  }

  Future<WindowsServiceStatus> status() async {
    final script = layout.script('status-vnts2-service.ps1').path;
    final output = await _runner.run(
      '\$value = & ${PowerShellRunner.quote(script)} '
      '-ServiceName ${PowerShellRunner.quote(serviceName)}; '
      r'$value | ConvertTo-Json -Compress -Depth 5',
      operation: '读取服务状态',
    );
    final decoded = _decodeLastJson(output);
    if (decoded is! Map) {
      throw const ServiceOperationException('服务状态脚本返回了无效结果');
    }
    return WindowsServiceStatus.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<List<DiagnosticCheck>> run(
    ServiceAction action, {
    String? updateSource,
  }) async {
    if (action == ServiceAction.diagnose) return diagnose();
    final command = switch (action) {
      ServiceAction.install => _invoke(
        'install-vnts2-service.ps1',
        '-ServiceName ${PowerShellRunner.quote(serviceName)} '
            '-TargetDir ${PowerShellRunner.quote(layout.root.path)}',
      ),
      ServiceAction.start => _invoke(
        'start-vnts2-service.ps1',
        '-ServiceName ${PowerShellRunner.quote(serviceName)}',
      ),
      ServiceAction.stop => _invoke(
        'stop-vnts2-service.ps1',
        '-ServiceName ${PowerShellRunner.quote(serviceName)}',
      ),
      ServiceAction.restart =>
        '${_invoke('stop-vnts2-service.ps1', '-ServiceName ${PowerShellRunner.quote(serviceName)}')} | Out-Null; '
            '${_invoke('start-vnts2-service.ps1', '-ServiceName ${PowerShellRunner.quote(serviceName)}')}',
      ServiceAction.update => _updateCommand(updateSource),
      ServiceAction.uninstall => _invoke(
        'uninstall-vnts2-service.ps1',
        '-ServiceName ${PowerShellRunner.quote(serviceName)}',
      ),
      ServiceAction.diagnose => throw StateError('diagnose handled above'),
    };
    await _runner.run(command, operation: _label(action));
    return const [];
  }

  Future<List<DiagnosticCheck>> diagnose() async {
    final output = await _runner.run(
      r'$checks = @(' +
          _invoke(
            'diagnose-vnts2-service.ps1',
            '-ServiceName ${PowerShellRunner.quote(serviceName)}',
          ) +
          r'); $checks | ConvertTo-Json -Compress -Depth 5',
      operation: '运行诊断',
    );
    final decoded = _decodeLastJson(output);
    final values = decoded is List ? decoded : [decoded];
    return values
        .whereType<Map>()
        .map(
          (value) => DiagnosticCheck.fromJson(Map<String, Object?>.from(value)),
        )
        .toList(growable: false);
  }

  String _updateCommand(String? source) {
    if (source == null || source.trim().isEmpty) {
      throw const ServiceOperationException('请选择新的 vnts2.exe 更新源');
    }
    final file = File(source.trim()).absolute;
    if (!file.path.toLowerCase().endsWith('.exe') || !file.existsSync()) {
      throw const ServiceOperationException('更新源必须是存在的 .exe 文件');
    }
    final target = layout.executable.absolute.path.toLowerCase();
    if (file.path.toLowerCase() == target) {
      throw const ServiceOperationException('更新源不能与当前服务程序相同');
    }
    return _invoke(
      'update-vnts2-service.ps1',
      '-ServiceName ${PowerShellRunner.quote(serviceName)} '
          '-TargetDir ${PowerShellRunner.quote(layout.root.path)} '
          '-SourceExecutable ${PowerShellRunner.quote(file.path)}',
    );
  }

  String _invoke(String scriptName, String arguments) {
    return '& ${PowerShellRunner.quote(layout.script(scriptName).path)} $arguments';
  }

  static Object? _decodeLastJson(String output) {
    final lines = const LineSplitter().convert(output).reversed;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return jsonDecode(trimmed);
        } on FormatException {
          continue;
        }
      }
    }
    throw const ServiceOperationException('PowerShell 未返回可解析的 JSON');
  }

  static String _label(ServiceAction action) => switch (action) {
    ServiceAction.install => '安装服务',
    ServiceAction.start => '启动服务',
    ServiceAction.stop => '停止服务',
    ServiceAction.restart => '重启服务',
    ServiceAction.update => '更新服务',
    ServiceAction.diagnose => '运行诊断',
    ServiceAction.uninstall => '卸载服务',
  };
}

class PowerShellRunner {
  PowerShellRunner(this.workingDirectory);

  final String workingDirectory;

  static String quote(String value) => "'${value.replaceAll("'", "''")}'";

  static String encodeCommand(String body) {
    final prefix =
        r"$ErrorActionPreference='Stop'; "
        r'$OutputEncoding=[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false); ';
    final bytes = <int>[];
    for (final codeUnit in '$prefix$body'.codeUnits) {
      bytes
        ..add(codeUnit & 0xff)
        ..add(codeUnit >> 8);
    }
    return base64Encode(bytes);
  }

  Future<String> run(
    String body, {
    required String operation,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (!Platform.isWindows) {
      throw const ServiceOperationException('Windows 服务操作只支持 Windows');
    }
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || systemRoot.isEmpty) {
      throw const ServiceOperationException('无法定位 Windows PowerShell');
    }
    final executable =
        '$systemRoot${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}WindowsPowerShell${Platform.pathSeparator}v1.0'
        '${Platform.pathSeparator}powershell.exe';
    if (!File(executable).existsSync()) {
      throw const ServiceOperationException('系统缺少 Windows PowerShell');
    }
    final windowsModules =
        '$systemRoot${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}WindowsPowerShell${Platform.pathSeparator}v1.0'
        '${Platform.pathSeparator}Modules';
    final process = await Process.start(
      executable,
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        encodeCommand(body),
      ],
      workingDirectory: workingDirectory,
      // PowerShell 7 can export module paths that are binary-incompatible
      // with the Windows PowerShell 5.1 host used by these signed-off scripts.
      environment: {'PSModulePath': windowsModules},
      runInShell: false,
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          stdoutBuffer.write,
          onDone: () {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
          onError: (_) {
            if (!stdoutDone.isCompleted) stdoutDone.complete();
          },
        );
    final stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          stderrBuffer.write,
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
          onError: (_) {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );
    late final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      throw ServiceOperationException('$operation超时，已终止 PowerShell 进程');
    }
    try {
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // A service child can temporarily inherit the PowerShell output pipe.
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
    final output = stdoutBuffer.toString();
    final error = stderrBuffer.toString();
    if (exitCode != 0) {
      throw ServiceOperationException(
        '$operation失败（退出码 $exitCode）',
        details: _limitedDetails(error.isNotEmpty ? error : output),
      );
    }
    return output;
  }

  static String _limitedDetails(String value) {
    final trimmed = value.trim();
    return trimmed.length <= 2000 ? trimmed : '${trimmed.substring(0, 2000)}…';
  }
}

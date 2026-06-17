import 'dart:convert';
import 'dart:io';

import 'remote_assist_constants.dart';
import 'remote_assist_launcher.dart';
import 'remote_assist_log.dart';
import 'remote_assist_models.dart';

class RemoteAssistHealthService {
  RemoteAssistHealthService({
    RemoteAssistLauncher? launcher,
  }) : _launcher = launcher ?? RemoteAssistLauncher.instance;

  final RemoteAssistLauncher _launcher;

  Future<RemoteAssistHealthStatus> collectStatus({
    required bool vntConnected,
    required List<String> localVirtualIps,
    required List<String> networkCidrs,
    required bool presenceRunning,
    required bool firewallSyncSucceeded,
  }) async {
    if (!Platform.isWindows) {
      return const RemoteAssistHealthStatus(
        supported: false,
        platform: RemoteAssistPlatform.unsupported,
        supportedRoles: <String>[],
        vntConnected: false,
        runtimeAvailable: false,
        serviceInstalled: false,
        serviceRunning: false,
        portListening: false,
        firewallTcpRulePresent: false,
        firewallUdpRulePresent: false,
        firewallSyncSucceeded: false,
        presenceRunning: false,
        hasAdminPrivileges: false,
        managedInstall: false,
        bundledInstallerAvailable: false,
        bundledBootstrapAvailable: false,
        localVirtualIps: <String>[],
        networkCidrs: <String>[],
        executablePath: '',
        runtimeVersion: '',
        controllerAvailable: false,
        controlledServiceRunning: false,
        notificationPermissionGranted: false,
        screenCapturePermissionGranted: false,
        accessibilityPermissionGranted: false,
        overlayPermissionGranted: false,
        batteryOptimizationIgnored: false,
        issues: <String>['当前平台暂不支持远程协助'],
      );
    }

    final manifest = await _launcher.loadManifest();
    final bundledInstallerAvailable =
        await _launcher.locateBundledMsiPath() != null;
    final bundledBootstrapAvailable =
        await _launcher.locateBundledBootstrapScriptPath() != null;
    final executablePath = await _launcher.locateExecutablePath() ?? '';
    final runtimeVersion = manifest?.version.trim().isNotEmpty == true
        ? manifest!.version.trim()
        : await _launcher.resolveVersion();
    final serviceInfo = await _queryService();
    final runtimeProcesses = await _queryRuntimeProcesses(
      executablePath: executablePath,
    );
    final tcpRule = await _queryFirewallRule(
      RemoteAssistConstants.tcpFirewallRuleName,
    );
    final udpRule = await _queryFirewallRule(
      RemoteAssistConstants.udpFirewallRuleName,
    );
    final isAdmin = await hasAdminPrivileges();
    final portListening = await _isPortListening(
      processIds: runtimeProcesses.processIds,
      port: RemoteAssistConstants.directAccessPort,
    );
    final runtimeReady = serviceInfo.isRunning ||
        runtimeProcesses.hasServiceProcess ||
        runtimeProcesses.hasServerProcess ||
        portListening;

    final issues = <String>[];
    if (!vntConnected) {
      issues.add('当前未连接任何虚拟网络');
    }
    if (executablePath.isEmpty) {
      if (bundledInstallerAvailable && bundledBootstrapAvailable) {
        issues.add('未检测到 vntcrustdesk 安装，可点击“修复”自动安装');
      } else {
        issues.add('未检测到 vntcrustdesk 安装，且当前运行目录未携带安装组件');
      }
    }
    if (serviceInfo.exists && !runtimeReady) {
      issues.add('vntcrustdesk 服务未运行');
    }
    if (executablePath.isNotEmpty &&
        !serviceInfo.exists &&
        !runtimeProcesses.hasAnyProcess &&
        bundledInstallerAvailable &&
        bundledBootstrapAvailable) {
      issues.add('已检测到 vntcrustdesk，但服务注册异常，可点击“修复”重新绑定');
    }
    if (executablePath.isNotEmpty &&
        !serviceInfo.exists &&
        !runtimeProcesses.hasAnyProcess &&
        !bundledInstallerAvailable &&
        !bundledBootstrapAvailable) {
      issues.add('已检测到 vntcrustdesk，但当前运行目录无法执行自动修复');
    }
    if (executablePath.isNotEmpty &&
        !serviceInfo.exists &&
        !runtimeProcesses.hasAnyProcess) {
      issues.add('vntcrustdesk 后台未运行');
    }
    if (executablePath.isNotEmpty && runtimeReady && !portListening) {
      issues.add('49999 端口未监听');
    }
    if (!tcpRule.exists || !udpRule.exists) {
      issues.add('远程协助防火墙规则缺失');
    }
    if (!isAdmin && (bundledInstallerAvailable || bundledBootstrapAvailable)) {
      issues.add('点击“修复”时会触发管理员授权，用于安装组件和同步防火墙');
    } else if (!isAdmin) {
      issues.add('当前进程未使用管理员权限，防火墙收口只能做只读检查');
    }

    return RemoteAssistHealthStatus(
      supported: true,
      platform: RemoteAssistPlatform.windows,
      supportedRoles: const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ],
      vntConnected: vntConnected,
      runtimeAvailable: executablePath.isNotEmpty,
      serviceInstalled:
          serviceInfo.exists || runtimeProcesses.hasServiceProcess,
      serviceRunning: runtimeReady,
      portListening: portListening,
      firewallTcpRulePresent: tcpRule.exists,
      firewallUdpRulePresent: udpRule.exists,
      firewallSyncSucceeded: firewallSyncSucceeded,
      presenceRunning: presenceRunning,
      hasAdminPrivileges: isAdmin,
      managedInstall: manifest?.isManagedByCurrentApp ?? false,
      bundledInstallerAvailable: bundledInstallerAvailable,
      bundledBootstrapAvailable: bundledBootstrapAvailable,
      localVirtualIps: localVirtualIps,
      networkCidrs: networkCidrs,
      executablePath: executablePath,
      runtimeVersion: runtimeVersion,
      controllerAvailable: executablePath.isNotEmpty,
      controlledServiceRunning: runtimeReady,
      notificationPermissionGranted: false,
      screenCapturePermissionGranted: false,
      accessibilityPermissionGranted: false,
      overlayPermissionGranted: false,
      batteryOptimizationIgnored: false,
      issues: issues,
    );
  }

  Future<bool> hasAdminPrivileges() async {
    final result = await _runPowerShell(
      '''
\$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (\$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'true' } else { 'false' }
''',
    );
    return result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';
  }

  Future<bool> warmUpBackgroundSilently() async {
    if (!Platform.isWindows) {
      return false;
    }

    var executablePath = await _launcher.locateExecutablePath() ?? '';
    if (executablePath.isEmpty) {
      await RemoteAssistLog.write('静默预热跳过：未定位到 vntcrustdesk 可执行文件');
      return false;
    }

    if (await _isRuntimeReady(
      executablePath: executablePath,
      port: RemoteAssistConstants.directAccessPort,
    )) {
      return true;
    }

    if (await _ensureServiceRunning()) {
      executablePath = await _launcher.locateExecutablePath() ?? executablePath;
      if (await _isRuntimeReady(
        executablePath: executablePath,
        port: RemoteAssistConstants.directAccessPort,
      )) {
        await RemoteAssistLog.write('状态刷新时已静默启动 vntcrustdesk 服务');
        return true;
      }
      await RemoteAssistLog.write('静默启动服务后仍未达到监听就绪状态');
    }

    if (await _launcher.tryStartBackgroundServer()) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await _isRuntimeReady(
        executablePath: executablePath,
        port: RemoteAssistConstants.directAccessPort,
      )) {
        await RemoteAssistLog.write('状态刷新时已静默拉起 vntcrustdesk 监听进程');
        return true;
      }
      await RemoteAssistLog.write('直接拉起 vntcrustdesk 监听进程后仍未检测到 49999 监听');
    }

    return false;
  }

  Future<void> ensureBackgroundReady() async {
    if (await warmUpBackgroundSilently()) {
      return;
    }

    var executablePath = await _launcher.locateExecutablePath() ?? '';
    final hasBundledRepairAssets = await _launcher.hasBundledRepairAssets();
    if (hasBundledRepairAssets) {
      await _launcher.installBundledRuntimeWithElevation();
      executablePath = await _launcher.locateExecutablePath() ?? executablePath;
      if (await _ensureServiceRunning() &&
          await _isRuntimeReady(
            executablePath: executablePath,
            port: RemoteAssistConstants.directAccessPort,
          )) {
        return;
      }
      await RemoteAssistLog.write('提权修复完成后，vntcrustdesk 服务仍未就绪');
      throw StateError('vntcrustdesk 已尝试修复，但服务仍未就绪，请重新安装');
    }

    if (executablePath.isNotEmpty) {
      await RemoteAssistLog.write('检测到 vntcrustdesk 可执行文件，但缺少可用服务与修复资源');
      throw StateError('已检测到 vntcrustdesk，但当前运行目录无法自动修复，请使用完整安装包');
    }

    await RemoteAssistLog.write('vntcrustdesk 缺失且当前运行目录未携带安装组件');
    throw StateError('当前运行目录未携带远程协助安装组件，请使用完整安装包或新版便携包');
  }

  Future<bool> _isRuntimeReady({
    required String executablePath,
    required int port,
  }) async {
    final runtimeProcesses = await _queryRuntimeProcesses(
      executablePath: executablePath,
    );
    if (!runtimeProcesses.hasAnyProcess) {
      return false;
    }

    final portListening = await _isPortListening(
      processIds: runtimeProcesses.processIds,
      port: port,
    );
    return runtimeProcesses.hasServiceProcess ||
        runtimeProcesses.hasServerProcess ||
        portListening;
  }

  Future<void> restartService() async {
    await _runPowerShell(
      '''
try {
  Restart-Service -Name '${_psString(RemoteAssistConstants.serviceName)}' -ErrorAction Stop
} catch {
  Start-Service -Name '${_psString(RemoteAssistConstants.serviceName)}' -ErrorAction SilentlyContinue
}
''',
    );
    await RemoteAssistLog.write('尝试重启 vntcrustdesk 服务');
  }

  Future<void> shutdownBackgroundSilently() async {
    if (!Platform.isWindows) {
      return;
    }

    final executablePath = await _launcher.locateExecutablePath() ?? '';
    final serviceInfo = await _queryService();
    var runtimeProcesses = await _queryRuntimeProcesses(
      executablePath: executablePath,
    );
    if (!serviceInfo.exists && !runtimeProcesses.hasAnyProcess) {
      await RemoteAssistLog.write('客户端退出时跳过停止远程协助：当前未发现运行中的后台组件');
      return;
    }

    await RemoteAssistLog.write(
      '客户端退出时准备停止远程协助: serviceExists=${serviceInfo.exists} status=${serviceInfo.status} processCount=${runtimeProcesses.processIds.length}',
    );

    final stopServiceResult = await _runPowerShell(
      '''
try {
  Stop-Service -Name '${_psString(RemoteAssistConstants.serviceName)}' -ErrorAction SilentlyContinue
} catch {
}
''',
    );
    await RemoteAssistLog.write(
      '客户端退出时尝试停止 vntcrustdesk 服务 exit=${stopServiceResult.exitCode} stdout=${_compactLogText(stopServiceResult.stdout.toString())} stderr=${_compactLogText(stopServiceResult.stderr.toString())}',
    );

    await Future<void>.delayed(const Duration(seconds: 2));
    runtimeProcesses = await _queryRuntimeProcesses(
      executablePath: executablePath,
    );
    if (runtimeProcesses.hasAnyProcess) {
      final processIdCsv = runtimeProcesses.processIds.join(',');
      final stopProcessResult = await _runPowerShell(
        '''
\$processIds = @('${_psString(processIdCsv)}'.Split(',') |
  Where-Object { -not [string]::IsNullOrWhiteSpace(\$_) } |
  ForEach-Object { [int]\$_ })
foreach (\$processId in \$processIds) {
  Stop-Process -Id \$processId -Force -ErrorAction SilentlyContinue
}
''',
      );
      await RemoteAssistLog.write(
        '客户端退出时清理 vntcrustdesk 残留进程 exit=${stopProcessResult.exitCode} stdout=${_compactLogText(stopProcessResult.stdout.toString())} stderr=${_compactLogText(stopProcessResult.stderr.toString())}',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      runtimeProcesses = await _queryRuntimeProcesses(
        executablePath: executablePath,
      );
    }

    final finalServiceInfo = await _queryService();
    await RemoteAssistLog.write(
      '客户端退出时远程协助停止结果: serviceExists=${finalServiceInfo.exists} status=${finalServiceInfo.status} processCount=${runtimeProcesses.processIds.length}',
    );
  }

  Future<bool> syncFirewallRules({
    required bool enabled,
    required List<String> remoteCidrs,
  }) async {
    if (!Platform.isWindows) {
      return false;
    }
    if (!await hasAdminPrivileges()) {
      await RemoteAssistLog.write('跳过防火墙同步：当前进程无管理员权限');
      return false;
    }

    final executablePath = await _launcher.locateExecutablePath() ?? '';
    final appExecutablePath = Platform.resolvedExecutable;
    final remoteAddresses = remoteCidrs.isEmpty ? 'Any' : remoteCidrs.join(',');
    final enabledText = enabled ? r'$true' : r'$false';

    final script = '''
function Ensure-FirewallRule {
  param(
    [string]\$DisplayName,
    [string]\$ProgramPath,
    [string]\$Protocol,
    [int]\$LocalPort
  )

  if (-not (Get-NetFirewallRule -DisplayName \$DisplayName -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace(\$ProgramPath)) {
      New-NetFirewallRule -DisplayName \$DisplayName -Direction Inbound -Action Allow -Profile Any -Protocol \$Protocol -LocalPort \$LocalPort | Out-Null
    } else {
      New-NetFirewallRule -DisplayName \$DisplayName -Direction Inbound -Action Allow -Profile Any -Protocol \$Protocol -LocalPort \$LocalPort -Program \$ProgramPath | Out-Null
    }
  }
}

\$tcpRule = '${_psString(RemoteAssistConstants.tcpFirewallRuleName)}'
\$udpRule = '${_psString(RemoteAssistConstants.udpFirewallRuleName)}'
\$tcpProgram = '${_psString(executablePath)}'
\$udpProgram = '${_psString(appExecutablePath)}'
\$remoteAddresses = '${_psString(remoteAddresses)}'
\$enabled = $enabledText

Ensure-FirewallRule -DisplayName \$tcpRule -ProgramPath \$tcpProgram -Protocol 'TCP' -LocalPort ${RemoteAssistConstants.directAccessPort}
Ensure-FirewallRule -DisplayName \$udpRule -ProgramPath \$udpProgram -Protocol 'UDP' -LocalPort ${RemoteAssistConstants.presencePort}

if (\$enabled) {
  Get-NetFirewallRule -DisplayName \$tcpRule | Enable-NetFirewallRule | Out-Null
  Get-NetFirewallRule -DisplayName \$udpRule | Enable-NetFirewallRule | Out-Null

  Get-NetFirewallRule -DisplayName \$tcpRule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress \$remoteAddresses | Out-Null
  Get-NetFirewallRule -DisplayName \$udpRule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress \$remoteAddresses | Out-Null
} else {
  Get-NetFirewallRule -DisplayName \$tcpRule | Disable-NetFirewallRule | Out-Null
  Get-NetFirewallRule -DisplayName \$udpRule | Disable-NetFirewallRule | Out-Null
}
''';

    final result = await _runPowerShell(script);
    final success = result.exitCode == 0;
    await RemoteAssistLog.write(
      '同步防火墙规则 enabled=$enabled remoteAddresses=$remoteAddresses success=$success',
    );
    return success;
  }

  Future<void> repair({
    required List<String> remoteCidrs,
  }) async {
    await ensureBackgroundReady();
    await restartService();
    await syncFirewallRules(
      enabled: remoteCidrs.isNotEmpty,
      remoteCidrs: remoteCidrs,
    );
  }

  Future<bool> _ensureServiceRunning() async {
    final serviceInfo = await _queryService();
    await RemoteAssistLog.write(
      '静默启动服务前检查: exists=${serviceInfo.exists} status=${serviceInfo.status}',
    );
    if (!serviceInfo.exists) {
      await RemoteAssistLog.write('静默启动服务跳过：未检测到 vntcrustdesk 服务注册');
      return false;
    }

    final result = await _runPowerShell(
      '''
try {
  Start-Service -Name '${_psString(RemoteAssistConstants.serviceName)}' -ErrorAction SilentlyContinue
} catch {
}
''',
    );
    await RemoteAssistLog.write(
      '尝试启动 vntcrustdesk 服务 exit=${result.exitCode} stdout=${_compactLogText(result.stdout.toString())} stderr=${_compactLogText(result.stderr.toString())}',
    );

    final refreshed = await _queryService();
    await RemoteAssistLog.write(
      '静默启动服务后检查: exists=${refreshed.exists} status=${refreshed.status}',
    );
    return refreshed.isRunning;
  }

  Future<_ServiceInfo> _queryService() async {
    final decoded = await _runPowerShellJson(
      '''
\$serviceName = '${_psString(RemoteAssistConstants.serviceName)}'
\$exists = \$false
\$status = ''
\$name = ''

\$service = Get-Service -Name \$serviceName -ErrorAction SilentlyContinue
if (\$null -ne \$service) {
  \$exists = \$true
  \$status = [string]\$service.Status
  \$name = \$service.Name
}

if (-not \$exists) {
  \$cimService = Get-CimInstance Win32_Service -Filter "Name='\$serviceName'" -ErrorAction SilentlyContinue
  if (\$null -ne \$cimService) {
    \$exists = \$true
    \$status = [string]\$cimService.State
    \$name = \$cimService.Name
  }
}

if (-not \$exists) {
  \$scOutput = & sc.exe query \$serviceName 2>\$null
  if (\$LASTEXITCODE -eq 0 -and \$scOutput -match 'SERVICE_NAME:\\s+' + [regex]::Escape(\$serviceName)) {
    \$exists = \$true
    \$name = \$serviceName
    \$stateLine = \$scOutput | Where-Object { \$_ -match 'STATE\\s*:\\s*\\d+\\s+\\w+' } | Select-Object -First 1
    if (\$null -ne \$stateLine -and \$stateLine -match 'STATE\\s*:\\s*\\d+\\s+(\\w+)') {
      \$status = [string]\$matches[1]
    }
  }
}

if (-not \$exists) {
  \$result = [pscustomobject]@{Exists = \$false; Status = ''; Name = ''}
} else {
  \$result = [pscustomobject]@{
    Exists = \$exists
    Status = \$status
    Name = \$name
  }
}
\$result | ConvertTo-Json -Compress
''',
    );
    final serviceInfo = _ServiceInfo.fromJson(decoded);
    if (!serviceInfo.exists || !serviceInfo.isRunning) {
      await RemoteAssistLog.write(
        '服务查询结果: exists=${serviceInfo.exists} status=${serviceInfo.status} raw=${jsonEncode(decoded)}',
      );
    }
    return serviceInfo;
  }

  Future<_RuntimeProcessInfo> _queryRuntimeProcesses({
    required String executablePath,
  }) async {
    final decoded = await _runPowerShellJson(
      '''
\$expectedPath = '${_psString(executablePath)}'
\$expectedPathNormalized = \$expectedPath.Trim().ToLowerInvariant()
\$expectedDirectoryNormalized = ''
if (-not [string]::IsNullOrWhiteSpace(\$expectedPathNormalized)) {
  \$expectedDirectoryNormalized = [System.IO.Path]::GetDirectoryName(\$expectedPathNormalized)
}

\$matchingProcesses = @(
  Get-CimInstance Win32_Process -Filter "Name='${_psString(RemoteAssistConstants.executableName)}'" -ErrorAction SilentlyContinue |
    Where-Object {
      if ([string]::IsNullOrWhiteSpace(\$_.ExecutablePath)) {
        return [string]::IsNullOrWhiteSpace(\$expectedPathNormalized)
      }

      \$candidatePath = ([string]\$_.ExecutablePath).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace(\$expectedPathNormalized) -and \$candidatePath -eq \$expectedPathNormalized) {
        return \$true
      }

      if (-not [string]::IsNullOrWhiteSpace(\$expectedDirectoryNormalized)) {
        \$candidateDirectory = [System.IO.Path]::GetDirectoryName(\$candidatePath)
        if (\$candidateDirectory -eq \$expectedDirectoryNormalized) {
          return \$true
        }
      }

      return [string]::IsNullOrWhiteSpace(\$expectedPathNormalized)
    }
)

\$processIds = @(\$matchingProcesses | ForEach-Object { [int]\$_.ProcessId })
\$result = [pscustomobject]@{
  Count = \$processIds.Count
  ProcessIds = \$processIds
  HasServerProcess = [bool](@(\$matchingProcesses | Where-Object { ([string]\$_.CommandLine).Contains('--server') }).Count -gt 0)
  HasServiceProcess = [bool](@(\$matchingProcesses | Where-Object { ([string]\$_.CommandLine).Contains('--service') }).Count -gt 0)
}
\$result | ConvertTo-Json -Compress
''',
    );
    return _RuntimeProcessInfo.fromJson(decoded);
  }

  Future<_FirewallRuleInfo> _queryFirewallRule(String displayName) async {
    final decoded = await _runPowerShellJson(
      '''
\$rule = Get-NetFirewallRule -DisplayName '${_psString(displayName)}' -ErrorAction SilentlyContinue | Select-Object -First 1
if (\$null -eq \$rule) {
  \$result = [pscustomobject]@{Exists = \$false; Enabled = 'False'}
} else {
  \$result = [pscustomobject]@{
    Exists = \$true
    Enabled = [string]\$rule.Enabled
  }
}
\$result | ConvertTo-Json -Compress
''',
    );
    return _FirewallRuleInfo.fromJson(decoded);
  }

  Future<bool> _isPortListening({
    required List<int> processIds,
    required int port,
  }) async {
    if (processIds.isEmpty) {
      return false;
    }

    final processIdCsv = processIds.join(',');
    final result = await _runPowerShell(
      '''
\$matchingProcesses = @('${_psString(processIdCsv)}'.Split(',') |
  Where-Object { -not [string]::IsNullOrWhiteSpace(\$_) } |
  ForEach-Object { [int]\$_ })

if (\$null -eq \$matchingProcesses -or \$matchingProcesses.Count -eq 0) {
  'false'
} else {
  \$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Where-Object { \$_.OwningProcess -in \$matchingProcesses } |
    Select-Object -First 1
  if (\$null -eq \$listener) { 'false' } else { 'true' }
}
''',
    );
    return result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';
  }

  Future<Map<String, dynamic>> _runPowerShellJson(String script) async {
    final result = await _runPowerShell(script);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      if (stderr.isNotEmpty) {
        await RemoteAssistLog.write(
          'PowerShell JSON 查询失败 exit=${result.exitCode} stderr=$stderr',
        );
      }
      return const {};
    }

    final trimmed = result.stdout.toString().trim();
    if (trimmed.isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (error) {
      await RemoteAssistLog.write('PowerShell JSON 解析失败: $error');
    }
    return const {};
  }

  Future<ProcessResult> _runPowerShell(String script) {
    return Process.run(
      _resolvePowerShellExecutable(),
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    );
  }

  String _psString(String value) {
    return value.replaceAll("'", "''");
  }

  String _resolvePowerShellExecutable() {
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot != null && systemRoot.trim().isNotEmpty) {
      return '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    }
    return 'powershell.exe';
  }

  String _compactLogText(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 180) {
      return normalized;
    }
    return '${normalized.substring(0, 180)}...';
  }
}

class _ServiceInfo {
  const _ServiceInfo({
    required this.exists,
    required this.status,
  });

  final bool exists;
  final String status;

  bool get isRunning => status.toLowerCase() == 'running';

  factory _ServiceInfo.fromJson(Map<String, dynamic> json) {
    return _ServiceInfo(
      exists: json['Exists'] == true,
      status: (json['Status'] ?? '').toString(),
    );
  }
}

class _RuntimeProcessInfo {
  const _RuntimeProcessInfo({
    required this.processIds,
    required this.hasServerProcess,
    required this.hasServiceProcess,
  });

  final List<int> processIds;
  final bool hasServerProcess;
  final bool hasServiceProcess;

  bool get hasAnyProcess => processIds.isNotEmpty;

  factory _RuntimeProcessInfo.fromJson(Map<String, dynamic> json) {
    final rawProcessIds = json['ProcessIds'];
    final processIds = <int>[];
    if (rawProcessIds is List) {
      for (final item in rawProcessIds) {
        final parsed = int.tryParse(item.toString());
        if (parsed != null && parsed > 0) {
          processIds.add(parsed);
        }
      }
    } else {
      final parsed = int.tryParse('${json['ProcessIds']}');
      if (parsed != null && parsed > 0) {
        processIds.add(parsed);
      }
    }
    return _RuntimeProcessInfo(
      processIds: processIds.toList(growable: false),
      hasServerProcess: json['HasServerProcess'] == true,
      hasServiceProcess: json['HasServiceProcess'] == true,
    );
  }
}

class _FirewallRuleInfo {
  const _FirewallRuleInfo({
    required this.exists,
    required this.enabled,
  });

  final bool exists;
  final bool enabled;

  factory _FirewallRuleInfo.fromJson(Map<String, dynamic> json) {
    return _FirewallRuleInfo(
      exists: json['Exists'] == true,
      enabled: (json['Enabled'] ?? '').toString().toLowerCase() == 'true',
    );
  }
}

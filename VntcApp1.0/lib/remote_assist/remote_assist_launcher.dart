import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vnt_app/utils/runtime_storage_paths.dart';

import 'remote_assist_constants.dart';
import 'remote_assist_log.dart';
import 'remote_assist_models.dart';

class RemoteAssistLauncher {
  RemoteAssistLauncher._();

  static final RemoteAssistLauncher instance = RemoteAssistLauncher._();

  Future<RemoteAssistRuntimeManifest?> loadManifest() async {
    if (!Platform.isWindows) {
      return null;
    }

    final manifestPath = RuntimeStoragePaths.resolveBundledPathSync(
      RemoteAssistConstants.manifestRelativePath,
    );
    final manifestFile = File(manifestPath);
    if (!await manifestFile.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is Map<String, dynamic>) {
        return RemoteAssistRuntimeManifest.fromJson(decoded);
      }
    } catch (error) {
      await RemoteAssistLog.write('读取 vntcrustdesk manifest 失败: $error');
    }
    return null;
  }

  Future<String?> locateExecutablePath() async {
    if (!Platform.isWindows) {
      return null;
    }

    final manifest = await loadManifest();
    final installedRuntime = await _queryInstalledRuntime();
    final candidates = <String>{
      if (Platform.environment['VNTC_RUSTDESK_EXE'] != null)
        Platform.environment['VNTC_RUSTDESK_EXE']!,
      if (manifest != null && manifest.executablePath.isNotEmpty)
        manifest.executablePath,
      if (installedRuntime.executablePath.isNotEmpty)
        installedRuntime.executablePath,
      path.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'VNTC RustDesk',
        RemoteAssistConstants.executableName,
      ),
      path.join(
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
        'VNTC RustDesk',
        RemoteAssistConstants.executableName,
      ),
    };

    for (final candidate in candidates) {
      if (candidate.trim().isEmpty) {
        continue;
      }
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  Future<bool> isAvailable() async {
    return await locateExecutablePath() != null;
  }

  Future<String> resolveVersion() async {
    final manifest = await loadManifest();
    if (manifest != null && manifest.version.trim().isNotEmpty) {
      return manifest.version.trim();
    }

    final installedRuntime = await _queryInstalledRuntime();
    return installedRuntime.version.trim();
  }

  Future<bool> hasBundledRepairAssets() async {
    return await locateBundledBootstrapScriptPath() != null &&
        await locateBundledMsiPath() != null;
  }

  Future<String?> locateBundledBootstrapScriptPath() async {
    return _locateBundledFile(
      RemoteAssistConstants.bootstrapScriptRelativePath,
    );
  }

  Future<String?> locateBundledMsiPath() async {
    return _locateBundledFile(
      RemoteAssistConstants.bundledMsiRelativePath,
    );
  }

  Future<void> installBundledRuntimeWithElevation() async {
    final bootstrapScriptPath = await locateBundledBootstrapScriptPath();
    final msiPath = await locateBundledMsiPath();
    if (bootstrapScriptPath == null || msiPath == null) {
      throw StateError('当前运行目录未携带远程协助安装组件');
    }

    final appDir = path.dirname(Platform.resolvedExecutable);
    final script = '''
\$bootstrapScriptPath = '${_psString(bootstrapScriptPath)}'
\$msiPath = '${_psString(msiPath)}'
\$appDir = '${_psString(appDir)}'

try {
  \$process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f \$bootstrapScriptPath),
    '-AppDir', ('"{0}"' -f \$appDir),
    '-MsiPath', ('"{0}"' -f \$msiPath)
  ) -PassThru -Wait -WindowStyle Hidden
  exit \$process.ExitCode
} catch {
  Write-Error \$_.Exception.Message
  exit 1223
}
''';

    await RemoteAssistLog.write('尝试提权安装/修复 vntcrustdesk');
    final result = await _runPowerShell(script);
    if (result.exitCode == 0) {
      return;
    }

    final message = [
      result.stdout.toString().trim(),
      result.stderr.toString().trim(),
    ].where((item) => item.isNotEmpty).join(' | ');
    await RemoteAssistLog.write(
      '提权安装/修复 vntcrustdesk 失败 exit=${result.exitCode} message=$message',
    );

    if (result.exitCode == 1223) {
      throw StateError('管理员授权已取消，未能完成远程协助安装/修复');
    }
    throw StateError(
      'vntcrustdesk 安装/修复失败，请以管理员权限重试${message.isEmpty ? "" : "：$message"}',
    );
  }

  Future<void> configureAccessPassword(String password) async {
    final executablePath = await locateExecutablePath();
    if (executablePath == null) {
      throw StateError('未找到 vntcrustdesk 可执行文件');
    }

    final accessMode = password.isEmpty ? 'click' : 'password';
    await RemoteAssistLog.write('设置远程协助访问密码: mode=$accessMode');
    final result = await Process.run(
      executablePath,
      ['--configure-access-password', password],
      workingDirectory: path.dirname(executablePath),
    );
    if (result.exitCode == 0) {
      await RemoteAssistLog.write('远程协助访问密码配置完成: mode=$accessMode');
      return;
    }

    final message = [
      result.stdout.toString().trim(),
      result.stderr.toString().trim(),
    ].where((item) => item.isNotEmpty).join(' | ');
    await RemoteAssistLog.write(
      '远程协助访问密码配置失败 exit=${result.exitCode} mode=$accessMode message=$message',
    );
    throw StateError(
      message.isEmpty ? '远程密码配置失败，请稍后重试' : '远程密码配置失败：$message',
    );
  }

  Future<void> openRemoteDesktop({
    required String targetAddress,
    String? password,
  }) async {
    final executablePath = await locateExecutablePath();
    if (executablePath == null) {
      throw StateError('未找到 vntcrustdesk 可执行文件');
    }
    await RemoteAssistLog.write('发起远程协助连接: $targetAddress');
    final arguments = <String>[
      '--connect',
      targetAddress,
      if (password != null && password.isNotEmpty) ...['--password', password],
    ];
    await Process.start(
      executablePath,
      arguments,
      workingDirectory: path.dirname(executablePath),
      mode: ProcessStartMode.detached,
    );
  }

  Future<bool> tryStartBackgroundServer() async {
    final executablePath = await locateExecutablePath();
    if (executablePath == null) {
      return false;
    }

    try {
      await RemoteAssistLog.write('尝试直接拉起 vntcrustdesk 后台监听进程');
      await Process.start(
        executablePath,
        const ['--server'],
        workingDirectory: path.dirname(executablePath),
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (error) {
      await RemoteAssistLog.write('直接拉起 vntcrustdesk 后台监听进程失败: $error');
      return false;
    }
  }

  Future<String?> _locateBundledFile(String relativePath) async {
    if (!Platform.isWindows) {
      return null;
    }

    final candidate = RuntimeStoragePaths.resolveBundledPathSync(relativePath);
    if (await File(candidate).exists()) {
      return candidate;
    }
    return null;
  }

  Future<_InstalledRuntimeInfo> _queryInstalledRuntime() async {
    final result = await _runPowerShell(
      '''
\$serviceName = '${_psString(RemoteAssistConstants.serviceName)}'
\$servicePath = ''
\$service = Get-CimInstance Win32_Service -Filter "Name='\$serviceName'" -ErrorAction SilentlyContinue
if (\$null -ne \$service -and -not [string]::IsNullOrWhiteSpace(\$service.PathName)) {
  \$pathName = [string]\$service.PathName
  if (\$pathName.StartsWith('"')) {
    \$servicePath = \$pathName.Split('"')[1]
  } else {
    \$servicePath = \$pathName.Split(' ')[0]
  }
}

\$installLocation = ''
\$displayVersion = ''
\$productCode = ''
\$registryPaths = @(
  'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
  'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
  'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*'
)

foreach (\$registryPath in \$registryPaths) {
  \$entry = Get-ItemProperty \$registryPath -ErrorAction SilentlyContinue |
    Where-Object {
      (\$_.DisplayName -like 'VNTC RustDesk*' -or \$_.DisplayName -like 'vntcrustdesk*') -and
      -not [string]::IsNullOrWhiteSpace(\$_.DisplayName)
    } |
    Select-Object -First 1

  if (\$null -eq \$entry) {
    continue
  }

  \$installLocation = [string]\$entry.InstallLocation
  \$displayVersion = [string]\$entry.DisplayVersion
  \$productCode = [string]\$entry.PSChildName

  if ([string]::IsNullOrWhiteSpace(\$servicePath) -and -not [string]::IsNullOrWhiteSpace(\$installLocation)) {
    \$registryExecutable = Join-Path \$installLocation '${_psString(RemoteAssistConstants.executableName)}'
    if (Test-Path -LiteralPath \$registryExecutable) {
      \$servicePath = \$registryExecutable
    }
  }
  break
}

[pscustomobject]@{
  executablePath = \$servicePath
  installDirectory = \$installLocation
  version = \$displayVersion
  productCode = \$productCode
} | ConvertTo-Json -Compress
''',
    );

    if (result.exitCode != 0) {
      return const _InstalledRuntimeInfo();
    }

    final trimmed = result.stdout.toString().trim();
    if (trimmed.isEmpty) {
      return const _InstalledRuntimeInfo();
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return _InstalledRuntimeInfo.fromJson(decoded);
      }
    } catch (error) {
      await RemoteAssistLog.write('读取系统级 vntcrustdesk 安装信息失败: $error');
    }
    return const _InstalledRuntimeInfo();
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
}

class _InstalledRuntimeInfo {
  const _InstalledRuntimeInfo({
    this.executablePath = '',
    this.installDirectory = '',
    this.version = '',
    this.productCode = '',
  });

  final String executablePath;
  final String installDirectory;
  final String version;
  final String productCode;

  factory _InstalledRuntimeInfo.fromJson(Map<String, dynamic> json) {
    return _InstalledRuntimeInfo(
      executablePath: (json['executablePath'] ?? '').toString(),
      installDirectory: (json['installDirectory'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      productCode: (json['productCode'] ?? '').toString(),
    );
  }
}

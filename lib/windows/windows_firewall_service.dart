import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class WindowsFirewallRuleSpec {
  const WindowsFirewallRuleSpec({
    required this.name,
    required this.protocol,
    required this.port,
    required this.purpose,
  });

  final String name;
  final String protocol;
  final int port;
  final String purpose;

  String get signature => '$protocol/$port';

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'protocol': protocol,
      'port': port,
      'purpose': purpose,
    };
  }
}

enum WindowsFirewallEnsureFailureKind {
  none,
  firewallDisabled,
  ruleCheckFailed,
  elevationNotShown,
  elevationCancelled,
  ruleApplyFailed,
  ruleStillMissingAfterApply,
}

class WindowsFirewallEnsureResult {
  const WindowsFirewallEnsureResult({
    required this.success,
    required this.promptedForElevation,
    required this.includeRemoteAssist,
    required this.targetedRules,
    required this.allowedRules,
    required this.missingRules,
    this.failureKind = WindowsFirewallEnsureFailureKind.none,
    this.blocksRemoteAssist = false,
    this.firewallEnabled = true,
    this.skippedRuleCheck = false,
    this.attemptedCommand,
    this.processExitCode,
    this.processStdout,
    this.processStderr,
    this.elevatedScriptStarted,
    this.errorMessage,
  });

  final bool success;
  final bool promptedForElevation;
  final bool includeRemoteAssist;
  final List<WindowsFirewallRuleSpec> targetedRules;
  final List<WindowsFirewallRuleSpec> allowedRules;
  final List<WindowsFirewallRuleSpec> missingRules;
  final WindowsFirewallEnsureFailureKind failureKind;
  final bool blocksRemoteAssist;
  final bool firewallEnabled;
  final bool skippedRuleCheck;
  final String? attemptedCommand;
  final int? processExitCode;
  final String? processStdout;
  final String? processStderr;
  final bool? elevatedScriptStarted;
  final String? errorMessage;

  WindowsFirewallEnsureResult copyWith({
    bool? success,
    bool? promptedForElevation,
    bool? includeRemoteAssist,
    List<WindowsFirewallRuleSpec>? targetedRules,
    List<WindowsFirewallRuleSpec>? allowedRules,
    List<WindowsFirewallRuleSpec>? missingRules,
    WindowsFirewallEnsureFailureKind? failureKind,
    bool? blocksRemoteAssist,
    bool? firewallEnabled,
    bool? skippedRuleCheck,
    String? attemptedCommand,
    int? processExitCode,
    String? processStdout,
    String? processStderr,
    bool? elevatedScriptStarted,
    String? errorMessage,
  }) {
    return WindowsFirewallEnsureResult(
      success: success ?? this.success,
      promptedForElevation: promptedForElevation ?? this.promptedForElevation,
      includeRemoteAssist: includeRemoteAssist ?? this.includeRemoteAssist,
      targetedRules: targetedRules ?? this.targetedRules,
      allowedRules: allowedRules ?? this.allowedRules,
      missingRules: missingRules ?? this.missingRules,
      failureKind: failureKind ?? this.failureKind,
      blocksRemoteAssist: blocksRemoteAssist ?? this.blocksRemoteAssist,
      firewallEnabled: firewallEnabled ?? this.firewallEnabled,
      skippedRuleCheck: skippedRuleCheck ?? this.skippedRuleCheck,
      attemptedCommand: attemptedCommand ?? this.attemptedCommand,
      processExitCode: processExitCode ?? this.processExitCode,
      processStdout: processStdout ?? this.processStdout,
      processStderr: processStderr ?? this.processStderr,
      elevatedScriptStarted:
          elevatedScriptStarted ?? this.elevatedScriptStarted,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

String buildWindowsFirewallEnsureScript(
  List<WindowsFirewallRuleSpec> rules, {
  String? startedMarkerPath,
  String? completedMarkerPath,
}) {
  final rulesJson = jsonEncode(
    rules.map((rule) => rule.toJson()).toList(growable: false),
  );
  final escapedJson = _escapePowerShellSingleQuoted(rulesJson);
  final startedMarkerScript = startedMarkerPath == null
      ? ''
      : "Set-Content -Path '${_escapePowerShellSingleQuoted(startedMarkerPath)}' -Value 'started' -Encoding UTF8\n";
  final completedMarkerScript = completedMarkerPath == null
      ? ''
      : "Set-Content -Path '${_escapePowerShellSingleQuoted(completedMarkerPath)}' -Value 'completed' -Encoding UTF8\n";
  return '''
\$ErrorActionPreference = 'Stop'
$startedMarkerScript
\$rules = ConvertFrom-Json -InputObject '$escapedJson'
foreach (\$rule in \$rules) {
  \$existing = Get-NetFirewallRule -DisplayName \$rule.name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (\$null -eq \$existing) {
    New-NetFirewallRule `
      -DisplayName \$rule.name `
      -Direction Inbound `
      -Action Allow `
      -Enabled True `
      -Profile Any `
      -Protocol \$rule.protocol `
      -LocalPort \$rule.port | Out-Null
  }
}
$completedMarkerScript
''';
}

String _escapePowerShellSingleQuoted(String value) {
  return value.replaceAll("'", "''");
}

String? _normalizeOptionalText(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool blocksRemoteAssistForFirewallFailure(
  WindowsFirewallEnsureFailureKind kind,
) {
  switch (kind) {
    case WindowsFirewallEnsureFailureKind.none:
    case WindowsFirewallEnsureFailureKind.firewallDisabled:
    case WindowsFirewallEnsureFailureKind.ruleCheckFailed:
    case WindowsFirewallEnsureFailureKind.elevationNotShown:
    case WindowsFirewallEnsureFailureKind.elevationCancelled:
    case WindowsFirewallEnsureFailureKind.ruleApplyFailed:
    case WindowsFirewallEnsureFailureKind.ruleStillMissingAfterApply:
      return false;
  }
}

String buildWindowsFirewallElevationLauncherScript(String scriptPath) {
  final escapedPath = _escapePowerShellSingleQuoted(scriptPath);
  return '''
\$ErrorActionPreference = 'Stop'
try {
  \$argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '$escapedPath')
  \$process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList \$argumentList -Wait -PassThru
  exit \$process.ExitCode
} catch {
  Write-Error \$_.Exception.Message
  exit 2
}
''';
}

class _WindowsFirewallElevationAttemptResult {
  const _WindowsFirewallElevationAttemptResult({
    required this.attemptedCommand,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elevatedScriptStarted,
    required this.elevatedScriptCompleted,
  });

  final String attemptedCommand;
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool elevatedScriptStarted;
  final bool elevatedScriptCompleted;
}

class WindowsFirewallService {
  WindowsFirewallService._();

  static final WindowsFirewallService instance = WindowsFirewallService._();

  static const List<WindowsFirewallRuleSpec> _chatRules = [
    WindowsFirewallRuleSpec(
      name: 'VNT Chat Control TCP 23100',
      protocol: 'TCP',
      port: 23100,
      purpose: '聊天室控制消息',
    ),
    WindowsFirewallRuleSpec(
      name: 'VNT Chat Attachment TCP 23101',
      protocol: 'TCP',
      port: 23101,
      purpose: '聊天室附件传输',
    ),
    WindowsFirewallRuleSpec(
      name: 'VNT Chat Voice UDP 23102',
      protocol: 'UDP',
      port: 23102,
      purpose: '聊天室语音媒体',
    ),
  ];

  static const WindowsFirewallRuleSpec _remoteAssistRule =
      WindowsFirewallRuleSpec(
    name: 'VNT Remote Assist TCP 21118',
    protocol: 'TCP',
    port: 21118,
    purpose: '远程协助 RustDesk 监听',
  );

  @visibleForTesting
  bool? debugForceSupportedPlatform;

  @visibleForTesting
  Future<bool> Function(WindowsFirewallRuleSpec rule)? debugRuleExists;

  @visibleForTesting
  Future<void> Function(List<WindowsFirewallRuleSpec> rules)?
      debugEnsureRulesElevated;

  @visibleForTesting
  Future<bool?> Function()? debugFirewallEnabled;

  @visibleForTesting
  Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    bool runInShell,
  })? debugRunProcess;

  @visibleForTesting
  Directory Function()? debugTempDirectory;

  WindowsFirewallEnsureResult? lastEnsureResult;

  bool get _isSupportedPlatform =>
      debugForceSupportedPlatform ?? Platform.isWindows;

  List<WindowsFirewallRuleSpec> targetRules({
    bool includeRemoteAssist = false,
  }) {
    return [
      ..._chatRules,
      if (includeRemoteAssist) _remoteAssistRule,
    ];
  }

  Future<WindowsFirewallEnsureResult> checkRuleStatus({
    bool includeRemoteAssist = false,
  }) async {
    final rules = targetRules(includeRemoteAssist: includeRemoteAssist);
    if (!_isSupportedPlatform) {
      return WindowsFirewallEnsureResult(
        success: true,
        promptedForElevation: false,
        includeRemoteAssist: includeRemoteAssist,
        targetedRules: rules,
        allowedRules: const [],
        missingRules: const [],
      );
    }
    try {
      final firewallEnabled = await _queryFirewallEnabled();
      if (firewallEnabled == false) {
        return WindowsFirewallEnsureResult(
          success: true,
          promptedForElevation: false,
          includeRemoteAssist: includeRemoteAssist,
          targetedRules: rules,
          allowedRules: const [],
          missingRules: const [],
          failureKind: WindowsFirewallEnsureFailureKind.firewallDisabled,
          blocksRemoteAssist: false,
          firewallEnabled: false,
          skippedRuleCheck: true,
        );
      }
      final allowedRules = <WindowsFirewallRuleSpec>[];
      final missingRules = <WindowsFirewallRuleSpec>[];
      for (final rule in rules) {
        final exists = await _ruleExists(rule);
        if (exists) {
          allowedRules.add(rule);
        } else {
          missingRules.add(rule);
        }
      }
      return WindowsFirewallEnsureResult(
        success: missingRules.isEmpty,
        promptedForElevation: false,
        includeRemoteAssist: includeRemoteAssist,
        targetedRules: rules,
        allowedRules: allowedRules,
        missingRules: missingRules,
        failureKind: WindowsFirewallEnsureFailureKind.none,
        blocksRemoteAssist: false,
        firewallEnabled: true,
      );
    } catch (error) {
      return WindowsFirewallEnsureResult(
        success: false,
        promptedForElevation: false,
        includeRemoteAssist: includeRemoteAssist,
        targetedRules: rules,
        allowedRules: const [],
        missingRules: rules,
        failureKind: WindowsFirewallEnsureFailureKind.ruleCheckFailed,
        blocksRemoteAssist: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<WindowsFirewallEnsureResult> ensureChatAndRemoteAssistRules({
    bool includeRemoteAssist = false,
  }) async {
    final before = await checkRuleStatus(
      includeRemoteAssist: includeRemoteAssist,
    );
    if (!_isSupportedPlatform ||
        before.skippedRuleCheck ||
        before.missingRules.isEmpty) {
      lastEnsureResult = before;
      return before;
    }

    String? errorMessage;
    WindowsFirewallEnsureFailureKind failureKind = before.failureKind;
    _WindowsFirewallElevationAttemptResult? attempt;
    try {
      attempt = await _ensureRulesElevated(before.missingRules);
    } catch (error) {
      errorMessage = error.toString();
      failureKind = _classifyElevationFailureKind(
        errorMessage,
        elevatedScriptStarted: false,
      );
    }

    final after =
        await checkRuleStatus(includeRemoteAssist: includeRemoteAssist);
    final unresolvedRules = after.missingRules;
    if (!after.success) {
      if (after.failureKind ==
          WindowsFirewallEnsureFailureKind.ruleCheckFailed) {
        failureKind = after.failureKind;
      } else if (errorMessage != null) {
        failureKind = failureKind;
      } else if (attempt != null && attempt.exitCode != 0) {
        failureKind = _classifyElevationFailureKind(
          '${attempt.stderr}\n${attempt.stdout}',
          elevatedScriptStarted: attempt.elevatedScriptStarted,
        );
      } else if (attempt != null && !attempt.elevatedScriptStarted) {
        failureKind = WindowsFirewallEnsureFailureKind.elevationNotShown;
      } else {
        failureKind =
            WindowsFirewallEnsureFailureKind.ruleStillMissingAfterApply;
      }
    } else {
      failureKind = WindowsFirewallEnsureFailureKind.none;
    }
    final nextError = errorMessage ??
        after.errorMessage ??
        (after.success
            ? null
            : '仍缺少放行规则: ${unresolvedRules.map((rule) => rule.signature).join(', ')}');
    final result = after.copyWith(
      promptedForElevation: true,
      failureKind: failureKind,
      blocksRemoteAssist: blocksRemoteAssistForFirewallFailure(failureKind),
      attemptedCommand: attempt?.attemptedCommand,
      processExitCode: attempt?.exitCode,
      processStdout: _normalizeOptionalText(attempt?.stdout),
      processStderr: _normalizeOptionalText(attempt?.stderr),
      elevatedScriptStarted: attempt?.elevatedScriptStarted,
      errorMessage: nextError,
    );
    lastEnsureResult = result;
    return result;
  }

  WindowsFirewallEnsureFailureKind _classifyElevationFailureKind(
    String? detail, {
    required bool elevatedScriptStarted,
  }) {
    final lower = (detail ?? '').toLowerCase();
    if (lower.contains('operation was canceled by the user') ||
        lower.contains('the operation was canceled by the user') ||
        lower.contains('用户取消') ||
        lower.contains('该操作已被用户取消') ||
        lower.contains('user denied')) {
      return WindowsFirewallEnsureFailureKind.elevationCancelled;
    }
    if (!elevatedScriptStarted) {
      return WindowsFirewallEnsureFailureKind.elevationNotShown;
    }
    return WindowsFirewallEnsureFailureKind.ruleApplyFailed;
  }

  Future<bool?> _queryFirewallEnabled() async {
    if (debugFirewallEnabled != null) {
      return debugFirewallEnabled!();
    }
    final script = '''
\$profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
if (\$null -eq \$profiles) {
  Write-Output 'Unknown'
  exit 0
}
\$enabledProfiles = @(\$profiles | Where-Object { \$_.Enabled -eq \$true -or \$_.Enabled -eq 1 -or \$_.Enabled -eq 'True' })
if (\$enabledProfiles.Count -gt 0) {
  Write-Output 'True'
} else {
  Write-Output 'False'
}
''';
    final result = await _runProcess(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
    );
    if (result.exitCode != 0) {
      throw StateError(
        '检查 Windows 防火墙状态失败: ${result.stderr}'.trim(),
      );
    }
    final output = result.stdout.toString().trim().toLowerCase();
    if (output == 'true') {
      return true;
    }
    if (output == 'false') {
      return false;
    }
    return null;
  }

  Future<bool> _ruleExists(WindowsFirewallRuleSpec rule) async {
    if (debugRuleExists != null) {
      return debugRuleExists!(rule);
    }
    final script = '''
\$rule = Get-NetFirewallRule -DisplayName '${_escapePowerShellSingleQuoted(rule.name)}' -ErrorAction SilentlyContinue | Select-Object -First 1
if (\$null -eq \$rule) { Write-Output 'False' } else { Write-Output 'True' }
''';
    final result = await _runProcess(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
    );
    if (result.exitCode != 0) {
      throw StateError(
        '检查 Windows 防火墙规则失败: ${result.stderr}'.trim(),
      );
    }
    return result.stdout.toString().trim().toLowerCase() == 'true';
  }

  Future<_WindowsFirewallElevationAttemptResult> _ensureRulesElevated(
    List<WindowsFirewallRuleSpec> rules,
  ) async {
    if (debugEnsureRulesElevated != null) {
      await debugEnsureRulesElevated!(rules);
      return const _WindowsFirewallElevationAttemptResult(
        attemptedCommand: 'debugEnsureRulesElevated',
        exitCode: 0,
        stdout: '',
        stderr: '',
        elevatedScriptStarted: true,
        elevatedScriptCompleted: true,
      );
    }
    final tempRoot = debugTempDirectory?.call() ?? Directory.systemTemp;
    final tempDir = await tempRoot.createTemp('vnt_firewall_');
    final scriptPath = '${tempDir.path}\\ensure_firewall_rules.ps1';
    final launcherPath = '${tempDir.path}\\run_firewall_rules_elevated.ps1';
    final startedMarkerPath =
        '${tempDir.path}\\ensure_firewall_rules_started.txt';
    final completedMarkerPath =
        '${tempDir.path}\\ensure_firewall_rules_completed.txt';
    final scriptFile = File(scriptPath);
    final launcherFile = File(launcherPath);
    try {
      await scriptFile.writeAsString(
        buildWindowsFirewallEnsureScript(
          rules,
          startedMarkerPath: startedMarkerPath,
          completedMarkerPath: completedMarkerPath,
        ),
      );
      await launcherFile.writeAsString(
        buildWindowsFirewallElevationLauncherScript(scriptPath),
      );
      final arguments = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        launcherPath,
      ];
      final result = await _runProcess(
        'powershell.exe',
        arguments,
      );
      return _WindowsFirewallElevationAttemptResult(
        attemptedCommand: 'powershell.exe ${arguments.join(' ')}',
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
        elevatedScriptStarted: await File(startedMarkerPath).exists(),
        elevatedScriptCompleted: await File(completedMarkerPath).exists(),
      );
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
  }) async {
    if (debugRunProcess != null) {
      return debugRunProcess!(
        executable,
        arguments,
        runInShell: runInShell,
      );
    }
    return Process.run(
      executable,
      arguments,
      runInShell: runInShell,
    );
  }
}

import 'dart:io';

import 'package:vnt_app/chat/chat_constants.dart';

class ChatFirewallService {
  Future<bool> syncRules({
    required bool enabled,
    required List<String> remoteCidrs,
  }) async {
    if (!Platform.isWindows) {
      return false;
    }
    if (!await hasAdminPrivileges()) {
      return false;
    }

    final remoteAddresses = remoteCidrs.isEmpty ? 'Any' : remoteCidrs.join(',');
    final enabledText = enabled ? r'$true' : r'$false';
    final executablePath = Platform.resolvedExecutable;

    final script = '''
function Ensure-FirewallRule {
  param(
    [string]\$DisplayName,
    [string]\$ProgramPath,
    [string]\$Protocol,
    [int]\$LocalPort
  )

  if (-not (Get-NetFirewallRule -DisplayName \$DisplayName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName \$DisplayName -Direction Inbound -Action Allow -Profile Any -Protocol \$Protocol -LocalPort \$LocalPort -Program \$ProgramPath | Out-Null
  }
}

\$tcpRule = '${_psString(ChatConstants.chatRuleNameTcp)}'
\$udpRule = '${_psString(ChatConstants.chatRuleNameUdp)}'
\$program = '${_psString(executablePath)}'
\$remoteAddresses = '${_psString(remoteAddresses)}'
\$enabled = $enabledText

Ensure-FirewallRule -DisplayName \$tcpRule -ProgramPath \$program -Protocol 'TCP' -LocalPort ${ChatConstants.transportPort}
Ensure-FirewallRule -DisplayName \$udpRule -ProgramPath \$program -Protocol 'UDP' -LocalPort ${ChatConstants.presencePort}

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
    return result.exitCode == 0;
  }

  Future<bool> hasAdminPrivileges() async {
    if (!Platform.isWindows) {
      return false;
    }
    final result = await _runPowerShell(
      '''
\$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (\$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'true' } else { 'false' }
''',
    );
    return result.exitCode == 0 &&
        result.stdout.toString().trim().toLowerCase() == 'true';
  }

  Future<ProcessResult> _runPowerShell(String script) {
    final systemRoot = Platform.environment['SystemRoot'];
    final executable =
        systemRoot == null || systemRoot.trim().isEmpty
            ? 'powershell.exe'
            : '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    return Process.run(
      executable,
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    );
  }

  String _psString(String value) {
    return value.replaceAll("'", "''");
  }
}

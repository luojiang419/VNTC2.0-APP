import 'remote_assist_constants.dart';

class RemoteAssistRuntimeManifest {
  const RemoteAssistRuntimeManifest({
    required this.executablePath,
    required this.installDirectory,
    required this.version,
    required this.serviceName,
    required this.managedBy,
    required this.productCode,
  });

  final String executablePath;
  final String installDirectory;
  final String version;
  final String serviceName;
  final String managedBy;
  final String productCode;

  bool get isManagedByCurrentApp =>
      managedBy.trim() == RemoteAssistConstants.managedBy;

  factory RemoteAssistRuntimeManifest.fromJson(Map<String, dynamic> json) {
    return RemoteAssistRuntimeManifest(
      executablePath: (json['executablePath'] ?? '').toString(),
      installDirectory: (json['installDirectory'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      serviceName: (json['serviceName'] ?? '').toString(),
      managedBy: (json['managedBy'] ?? '').toString(),
      productCode: (json['productCode'] ?? '').toString(),
    );
  }
}

class RemoteAssistPresenceAnnouncement {
  const RemoteAssistPresenceAnnouncement({
    required this.displayName,
    required this.virtualIp,
    required this.networkName,
    required this.version,
    required this.capabilities,
    required this.sentAtEpochMs,
  });

  final String displayName;
  final String virtualIp;
  final String networkName;
  final String version;
  final List<String> capabilities;
  final int sentAtEpochMs;

  factory RemoteAssistPresenceAnnouncement.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities.map((item) => item.toString()).toList()
        : const <String>[];
    return RemoteAssistPresenceAnnouncement(
      displayName: (json['displayName'] ?? '').toString(),
      virtualIp: (json['virtualIp'] ?? '').toString(),
      networkName: (json['networkName'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      capabilities: capabilities,
      sentAtEpochMs: int.tryParse('${json['sentAtEpochMs']}') ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': RemoteAssistConstants.presencePacketType,
      'displayName': displayName,
      'virtualIp': virtualIp,
      'networkName': networkName,
      'version': version,
      'capabilities': capabilities,
      'sentAtEpochMs': sentAtEpochMs,
    };
  }
}

class RemoteAssistPresenceContext {
  const RemoteAssistPresenceContext({
    required this.displayName,
    required this.virtualIp,
    required this.networkName,
    required this.version,
    required this.capabilities,
    required this.peerVirtualIps,
  });

  final String displayName;
  final String virtualIp;
  final String networkName;
  final String version;
  final List<String> capabilities;
  final List<String> peerVirtualIps;
}

class RemoteAssistPeer {
  const RemoteAssistPeer({
    required this.key,
    required this.displayName,
    required this.virtualIp,
    required this.networkName,
    required this.status,
    required this.isOnline,
    required this.capabilities,
    required this.version,
    required this.hasPresence,
    required this.lastSeen,
  });

  final String key;
  final String displayName;
  final String virtualIp;
  final String networkName;
  final String status;
  final bool isOnline;
  final List<String> capabilities;
  final String version;
  final bool hasPresence;
  final DateTime? lastSeen;
}

class RemoteAssistHealthStatus {
  const RemoteAssistHealthStatus({
    required this.supported,
    required this.vntConnected,
    required this.runtimeAvailable,
    required this.serviceInstalled,
    required this.serviceRunning,
    required this.portListening,
    required this.firewallTcpRulePresent,
    required this.firewallUdpRulePresent,
    required this.firewallSyncSucceeded,
    required this.presenceRunning,
    required this.hasAdminPrivileges,
    required this.managedInstall,
    required this.bundledInstallerAvailable,
    required this.bundledBootstrapAvailable,
    required this.localVirtualIps,
    required this.networkCidrs,
    required this.executablePath,
    required this.runtimeVersion,
    required this.issues,
  });

  final bool supported;
  final bool vntConnected;
  final bool runtimeAvailable;
  final bool serviceInstalled;
  final bool serviceRunning;
  final bool portListening;
  final bool firewallTcpRulePresent;
  final bool firewallUdpRulePresent;
  final bool firewallSyncSucceeded;
  final bool presenceRunning;
  final bool hasAdminPrivileges;
  final bool managedInstall;
  final bool bundledInstallerAvailable;
  final bool bundledBootstrapAvailable;
  final List<String> localVirtualIps;
  final List<String> networkCidrs;
  final String executablePath;
  final String runtimeVersion;
  final List<String> issues;

  factory RemoteAssistHealthStatus.initial() {
    return const RemoteAssistHealthStatus(
      supported: true,
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
      issues: <String>[],
    );
  }

  bool get canLaunch => supported && vntConnected && runtimeAvailable;

  bool get bundledRepairAvailable =>
      bundledInstallerAvailable && bundledBootstrapAvailable;

  bool get canAttemptRepair =>
      supported &&
      (runtimeAvailable || serviceInstalled || bundledRepairAvailable);

  String get installationModeDescription {
    if (managedInstall) {
      return '受当前安装器管理';
    }
    if (runtimeAvailable) {
      return '已检测到独立安装（未绑定当前应用）';
    }
    if (bundledRepairAvailable) {
      return '当前目录已携带远程协助安装组件';
    }
    return '当前目录未携带远程协助安装组件';
  }
}

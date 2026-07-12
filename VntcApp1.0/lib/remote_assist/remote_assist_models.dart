import 'remote_assist_constants.dart';

enum RemoteAssistPlatform {
  windows('windows'),
  android('android'),
  macos('macos'),
  linux('linux'),
  unsupported('unsupported');

  const RemoteAssistPlatform(this.token);

  final String token;

  static RemoteAssistPlatform fromToken(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'windows':
        return RemoteAssistPlatform.windows;
      case 'android':
        return RemoteAssistPlatform.android;
      case 'macos':
      case 'mac':
      case 'darwin':
        return RemoteAssistPlatform.macos;
      case 'linux':
        return RemoteAssistPlatform.linux;
      default:
        return RemoteAssistPlatform.unsupported;
    }
  }
}

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
    required this.platform,
    required this.supportedRoles,
    required this.capabilities,
    required this.sentAtEpochMs,
  });

  final String displayName;
  final String virtualIp;
  final String networkName;
  final String version;
  final RemoteAssistPlatform platform;
  final List<String> supportedRoles;
  final List<String> capabilities;
  final int sentAtEpochMs;

  factory RemoteAssistPresenceAnnouncement.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final rawSupportedRoles = json['supportedRoles'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities.map((item) => item.toString()).toList()
        : const <String>[];
    return RemoteAssistPresenceAnnouncement(
      displayName: (json['displayName'] ?? '').toString(),
      virtualIp: (json['virtualIp'] ?? '').toString(),
      networkName: (json['networkName'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      platform: RemoteAssistPlatform.fromToken(json['platform']?.toString()),
      supportedRoles: rawSupportedRoles is List
          ? rawSupportedRoles.map((item) => item.toString()).toList(
                growable: false,
              )
          : capabilities.where((item) {
              return item == RemoteAssistConstants.capabilityController ||
                  item == RemoteAssistConstants.capabilityControlled;
            }).toList(growable: false),
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
      'platform': platform.token,
      'supportedRoles': supportedRoles,
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
    required this.platform,
    required this.supportedRoles,
    required this.capabilities,
    required this.peerVirtualIps,
  });

  final String displayName;
  final String virtualIp;
  final String networkName;
  final String version;
  final RemoteAssistPlatform platform;
  final List<String> supportedRoles;
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
    required this.platform,
    required this.supportedRoles,
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
  final RemoteAssistPlatform platform;
  final List<String> supportedRoles;
  final List<String> capabilities;
  final String version;
  final bool hasPresence;
  final DateTime? lastSeen;

  bool get canControlOthers =>
      supportedRoles.contains(RemoteAssistConstants.capabilityController);

  bool get canBeControlled =>
      supportedRoles.contains(RemoteAssistConstants.capabilityControlled);

  bool get isLinux => platform == RemoteAssistPlatform.linux;
}

class RemoteAssistHealthStatus {
  const RemoteAssistHealthStatus({
    required this.supported,
    required this.platform,
    required this.supportedRoles,
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
    required this.controllerAvailable,
    required this.controlledServiceRunning,
    required this.notificationPermissionGranted,
    required this.screenCapturePermissionGranted,
    required this.accessibilityPermissionGranted,
    required this.overlayPermissionGranted,
    required this.batteryOptimizationIgnored,
    required this.issues,
  });

  final bool supported;
  final RemoteAssistPlatform platform;
  final List<String> supportedRoles;
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
  final bool controllerAvailable;
  final bool controlledServiceRunning;
  final bool notificationPermissionGranted;
  final bool screenCapturePermissionGranted;
  final bool accessibilityPermissionGranted;
  final bool overlayPermissionGranted;
  final bool batteryOptimizationIgnored;
  final List<String> issues;

  factory RemoteAssistHealthStatus.initial() {
    return const RemoteAssistHealthStatus(
      supported: true,
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
      issues: <String>[],
    );
  }

  bool get isWindows => platform == RemoteAssistPlatform.windows;
  bool get isAndroid => platform == RemoteAssistPlatform.android;
  bool get isMacOS => platform == RemoteAssistPlatform.macos;

  bool get supportsControllerRole =>
      supportedRoles.contains(RemoteAssistConstants.capabilityController);

  bool get supportsControlledRole =>
      supportedRoles.contains(RemoteAssistConstants.capabilityControlled);

  bool get controllerReady =>
      supported &&
      vntConnected &&
      controllerAvailable &&
      supportsControllerRole;

  bool get listenerReady =>
      isWindows ? portListening : supportsControlledRole && portListening;

  bool get permissionsReady {
    if (!isAndroid || !supportsControlledRole) {
      return !isAndroid;
    }
    return notificationPermissionGranted &&
        screenCapturePermissionGranted &&
        accessibilityPermissionGranted &&
        overlayPermissionGranted &&
        batteryOptimizationIgnored;
  }

  bool get controlledReady {
    if (!supportsControlledRole) {
      return false;
    }
    if (isAndroid) {
      return supported &&
          vntConnected &&
          controlledServiceRunning &&
          listenerReady &&
          permissionsReady;
    }
    return supported &&
        vntConnected &&
        controlledServiceRunning &&
        listenerReady;
  }

  bool get canLaunch => controllerReady;

  bool get bundledRepairAvailable =>
      bundledInstallerAvailable && bundledBootstrapAvailable;

  bool get canAttemptRepair => isAndroid
      ? supported
      : supported &&
          (runtimeAvailable || serviceInstalled || bundledRepairAvailable);

  bool get canStartControlledService =>
      supported && vntConnected && supportsControlledRole;

  bool get needsAndroidPermissionGuidance =>
      isAndroid &&
      supportsControlledRole &&
      (!notificationPermissionGranted ||
          !screenCapturePermissionGranted ||
          !accessibilityPermissionGranted ||
          !overlayPermissionGranted ||
          !batteryOptimizationIgnored);

  String get installationModeDescription {
    if (isAndroid) {
      return supportsControlledRole
          ? '当前应用内置 Android 远控组件'
          : '当前应用内置 Android 控制端组件';
    }
    if (isMacOS) {
      if (managedInstall) {
        return '当前应用已内置 macOS 远控组件';
      }
      if (runtimeAvailable) {
        return '已检测到 /Applications 中的 macOS 远控组件';
      }
      return '当前 macOS 包未内置远控组件';
    }
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

  String get primaryActionLabel => isAndroid || isMacOS ? '同步状态' : '安装/修复';
}

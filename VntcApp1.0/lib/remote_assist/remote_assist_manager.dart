import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

import 'remote_assist_constants.dart';
import 'remote_assist_health_service.dart';
import 'remote_assist_launcher.dart';
import 'remote_assist_log.dart';
import 'remote_assist_models.dart';
import 'remote_assist_presence_service.dart';
import 'remote_assist_utils.dart';

class RemoteAssistManager extends ChangeNotifier {
  RemoteAssistManager._();

  static final RemoteAssistManager instance = RemoteAssistManager._();

  final RemoteAssistLauncher _launcher = RemoteAssistLauncher.instance;
  final RemoteAssistHealthService _healthService = RemoteAssistHealthService();
  final RemoteAssistPresenceService _presenceService =
      RemoteAssistPresenceService();

  Timer? _refreshTimer;
  bool _started = false;
  bool _stopping = false;
  bool _refreshing = false;
  bool _firewallSyncSucceeded = false;
  String _lastFirewallStateKey = '';

  RemoteAssistHealthStatus _health = RemoteAssistHealthStatus.initial();
  DateTime? _lastRefreshAt;
  List<_RemoteAssistPeerSeed> _basePeers = const [];
  List<RemoteAssistPeer> _peers = const [];
  Map<String, RemoteAssistPresenceAnnouncement> _presenceCache = const {};
  List<_RemoteAssistLocalNode> _localNodes = const [];
  List<String> _networkCidrs = const [];

  bool get refreshing => _refreshing;
  DateTime? get lastRefreshAt => _lastRefreshAt;
  RemoteAssistHealthStatus get health => _health;
  List<RemoteAssistPeer> get peers => UnmodifiableListView(_peers);

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _stopping = false;

    if (!Platform.isWindows) {
      notifyListeners();
      return;
    }

    await refresh();
    _refreshTimer = Timer.periodic(
      RemoteAssistConstants.refreshInterval,
      (_) => unawaited(refresh(silent: true)),
    );
  }

  Future<void> stop() async {
    _started = false;
    _stopping = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _presenceService.stop();
    await _healthService.shutdownBackgroundSilently();
    _basePeers = const [];
    _peers = const [];
    _localNodes = const [];
    _networkCidrs = const [];
    _presenceCache = const {};
    _health = RemoteAssistHealthStatus.initial();
    _stopping = false;
    notifyListeners();
  }

  Future<void> refresh({bool silent = false}) async {
    if (_refreshing || !_started || _stopping) {
      return;
    }

    _refreshing = true;
    if (!silent) {
      notifyListeners();
    }

    try {
      final localNodes = <_RemoteAssistLocalNode>[];
      final basePeers = <_RemoteAssistPeerSeed>[];
      final networkCidrs = <String>{};

      for (final entry in vntManager.map.entries) {
        final key = entry.key;
        final box = entry.value;
        if (box.isClosed()) {
          continue;
        }

        final networkConfig = box.getNetConfig();
        final networkName = trimToEmpty(networkConfig?.configName).isNotEmpty
            ? trimToEmpty(networkConfig?.configName)
            : '默认网络';
        final displayName = trimToEmpty(networkConfig?.deviceName).isNotEmpty
            ? trimToEmpty(networkConfig?.deviceName)
            : networkName;

        final currentDevice = box.currentDevice();
        final localVirtualIp = trimToEmpty(currentDevice['virtualIp']);
        final virtualNetwork = trimToEmpty(currentDevice['virtualNetwork']);
        final virtualNetmask = trimToEmpty(currentDevice['virtualNetmask']);
        final cidr = cidrFromNetworkAndMask(virtualNetwork, virtualNetmask);
        if (cidr != null) {
          networkCidrs.add(cidr);
        }

        final peerDevices = box.peerDeviceList();
        if (localVirtualIp.isNotEmpty) {
          localNodes.add(
            _RemoteAssistLocalNode(
              connectionKey: key,
              displayName: displayName,
              virtualIp: localVirtualIp,
              networkName: networkName,
              peerVirtualIps: peerDevices
                  .map((device) => trimToEmpty(device.virtualIp))
                  .where((ip) => ip.isNotEmpty)
                  .toList(growable: false),
            ),
          );
        }

        for (final device in peerDevices) {
          basePeers.add(
            _RemoteAssistPeerSeed(
              key: buildRemoteAssistPeerKey(
                networkName: networkName,
                virtualIp: trimToEmpty(device.virtualIp),
              ),
              displayName: trimToEmpty(device.name),
              virtualIp: trimToEmpty(device.virtualIp),
              networkName: networkName,
              status: trimToEmpty(device.status),
              isOnline: trimToEmpty(device.status).toLowerCase() == 'online',
            ),
          );
        }
      }

      _localNodes = localNodes;
      _networkCidrs = networkCidrs.toList(growable: false)..sort();
      _basePeers = basePeers;

      if (!_started || _stopping) {
        return;
      }

      await _healthService.warmUpBackgroundSilently();
      if (!_started || _stopping) {
        return;
      }
      await _syncPresence();
      if (!_started || _stopping) {
        return;
      }
      await _syncFirewallIfNeeded();
      if (!_started || _stopping) {
        return;
      }

      _health = await _healthService.collectStatus(
        vntConnected: _localNodes.isNotEmpty,
        localVirtualIps:
            _localNodes.map((node) => node.virtualIp).toList(growable: false),
        networkCidrs: _networkCidrs,
        presenceRunning: _presenceService.isRunning,
        firewallSyncSucceeded: _firewallSyncSucceeded,
      );
      _peers = _mergePeers();
      _lastRefreshAt = DateTime.now();
    } catch (error, stackTrace) {
      await RemoteAssistLog.write(
        '刷新远程协助状态失败: $error\n$stackTrace',
      );
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> launchController(String virtualIp, {String? password}) async {
    final trimmedIp = virtualIp.trim();
    if (!isValidIpv4(trimmedIp)) {
      throw ArgumentError('请输入有效的 IPv4 地址');
    }

    await _healthService.ensureBackgroundReady();
    await _launcher.openRemoteDesktop(
      targetAddress: '$trimmedIp:${RemoteAssistConstants.directAccessPort}',
      password: password,
    );
  }

  Future<void> configureAccessPassword(String password) async {
    await _healthService.ensureBackgroundReady();
    await _launcher.configureAccessPassword(password);
    await refresh();
  }

  Future<void> repair() async {
    await _healthService.repair(remoteCidrs: _networkCidrs);
    await refresh();
  }

  Future<void> _syncPresence() async {
    if (_localNodes.isEmpty) {
      _presenceCache = const {};
      await _presenceService.stop();
      return;
    }

    final version = await _launcher.resolveVersion();
    final contexts = _localNodes
        .map(
          (node) => RemoteAssistPresenceContext(
            displayName: node.displayName,
            virtualIp: node.virtualIp,
            networkName: node.networkName,
            version: version,
            capabilities: const [
              RemoteAssistConstants.capabilityWindows,
              RemoteAssistConstants.capabilityController,
              RemoteAssistConstants.capabilityControlled,
            ],
            peerVirtualIps: node.peerVirtualIps,
          ),
        )
        .toList(growable: false);

    await _presenceService.updateContexts(
      contexts: contexts,
      onSnapshot: (snapshot) {
        _presenceCache = snapshot;
        _peers = _mergePeers();
        notifyListeners();
      },
    );
  }

  Future<void> _syncFirewallIfNeeded() async {
    final nextKey = '${_localNodes.isNotEmpty}|${_networkCidrs.join(",")}';
    if (nextKey == _lastFirewallStateKey) {
      return;
    }
    _lastFirewallStateKey = nextKey;
    _firewallSyncSucceeded = await _healthService.syncFirewallRules(
      enabled: _localNodes.isNotEmpty,
      remoteCidrs: _networkCidrs,
    );
  }

  List<RemoteAssistPeer> _mergePeers() {
    final merged = _basePeers.map((peer) {
      final presence = _presenceCache[peer.key];
      final displayName = normalizeRemoteAssistDisplayName(
        presence?.displayName ?? peer.displayName,
        fallbackIp: peer.virtualIp,
      );
      return RemoteAssistPeer(
        key: peer.key,
        displayName: displayName,
        virtualIp: peer.virtualIp,
        networkName: peer.networkName,
        status: peer.status,
        isOnline: peer.isOnline,
        capabilities: presence?.capabilities ?? const <String>[],
        version: presence?.version ?? '',
        hasPresence: presence != null,
        lastSeen: presence == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(presence.sentAtEpochMs),
      );
    }).toList(growable: false);

    merged.sort((left, right) {
      if (left.isOnline != right.isOnline) {
        return left.isOnline ? -1 : 1;
      }
      final networkCompare = left.networkName.compareTo(right.networkName);
      if (networkCompare != 0) {
        return networkCompare;
      }
      return left.virtualIp.compareTo(right.virtualIp);
    });
    return merged;
  }
}

class _RemoteAssistPeerSeed {
  const _RemoteAssistPeerSeed({
    required this.key,
    required this.displayName,
    required this.virtualIp,
    required this.networkName,
    required this.status,
    required this.isOnline,
  });

  final String key;
  final String displayName;
  final String virtualIp;
  final String networkName;
  final String status;
  final bool isOnline;
}

class _RemoteAssistLocalNode {
  const _RemoteAssistLocalNode({
    required this.connectionKey,
    required this.displayName,
    required this.virtualIp,
    required this.networkName,
    required this.peerVirtualIps,
  });

  final String connectionKey;
  final String displayName;
  final String virtualIp;
  final String networkName;
  final List<String> peerVirtualIps;
}

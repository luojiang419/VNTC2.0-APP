import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

import 'remote_assist_constants.dart';
import 'remote_assist_log.dart';
import 'remote_assist_models.dart';
import 'remote_assist_macos_adapter.dart';
import 'remote_assist_platform_adapter.dart';
import 'remote_assist_presence_service.dart';
import 'remote_assist_utils.dart';
import 'remote_assist_windows_adapter.dart';
import 'remote_assist_unsupported_adapter.dart';

class RemoteAssistManager extends ChangeNotifier {
  RemoteAssistManager._();

  static final RemoteAssistManager instance = RemoteAssistManager._();

  final RemoteAssistPlatformAdapter _adapter = _createAdapter();
  final RemoteAssistPresenceService _presenceService =
      RemoteAssistPresenceService();

  Timer? _refreshTimer;
  bool _started = false;
  bool _stopping = false;
  bool _refreshing = false;

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

  static RemoteAssistPlatformAdapter _createAdapter() {
    if (Platform.isWindows) {
      return RemoteAssistWindowsAdapter();
    }
    if (Platform.isMacOS) {
      return RemoteAssistMacosAdapter();
    }
    return const RemoteAssistUnsupportedAdapter();
  }

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    _stopping = false;

    await _adapter.start();
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
    await _adapter.stop();
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

      await _adapter.refreshState();
      if (!_started || _stopping) {
        return;
      }

      await _syncPresence();
      if (!_started || _stopping) {
        return;
      }

      _health = await _adapter.collectStatus(
        vntConnected: _localNodes.isNotEmpty,
        localVirtualIps:
            _localNodes.map((node) => node.virtualIp).toList(growable: false),
        networkCidrs: _networkCidrs,
        presenceRunning: _presenceService.isRunning,
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

    await _adapter.launchController(
      trimmedIp,
      password: password,
    );
  }

  Future<void> configureAccessPassword(String password) async {
    await _adapter.configureAccessPassword(password);
    await refresh();
  }

  Future<void> repair() async {
    await _adapter.repair(remoteCidrs: _networkCidrs);
    await refresh();
  }

  Future<void> requestPermission(String permission) async {
    await _adapter.requestPermission(permission);
    await refresh();
  }

  Future<void> openSystemSettings(String section) async {
    await _adapter.openSystemSettings(section);
  }

  Future<void> startControlledService() async {
    await _adapter.startControlledService();
    await refresh();
  }

  Future<void> stopControlledService() async {
    await _adapter.stopControlledService();
    await refresh();
  }

  Future<void> _syncPresence() async {
    if (_localNodes.isEmpty) {
      _presenceCache = const {};
      await _presenceService.stop();
      return;
    }

    final version = await _adapter.resolveVersion();
    final contexts = _localNodes
        .map(
          (node) => RemoteAssistPresenceContext(
            displayName: node.displayName,
            virtualIp: node.virtualIp,
            networkName: node.networkName,
            version: version,
            platform: _adapter.platform,
            supportedRoles: _adapter.supportedRoles,
            capabilities: _adapter.presenceCapabilities,
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
        platform: presence?.platform ?? RemoteAssistPlatform.unsupported,
        supportedRoles: presence?.supportedRoles ?? const <String>[],
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

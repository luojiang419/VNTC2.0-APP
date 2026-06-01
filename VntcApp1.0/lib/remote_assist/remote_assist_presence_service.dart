import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_assist_constants.dart';
import 'remote_assist_log.dart';
import 'remote_assist_models.dart';
import 'remote_assist_utils.dart';

class RemoteAssistPresenceService {
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  List<RemoteAssistPresenceContext> _contexts = const [];
  final Map<String, RemoteAssistPresenceAnnouncement> _announcements = {};
  void Function(Map<String, RemoteAssistPresenceAnnouncement>)? _onSnapshot;

  bool get isRunning => _socket != null;

  Future<void> updateContexts({
    required List<RemoteAssistPresenceContext> contexts,
    required void Function(Map<String, RemoteAssistPresenceAnnouncement>)
        onSnapshot,
  }) async {
    _onSnapshot = onSnapshot;
    _contexts = contexts
        .where((context) => isValidIpv4(context.virtualIp))
        .toList(growable: false);

    if (_contexts.isEmpty) {
      await stop();
      return;
    }

    await _ensureSocket();
    _ensureTimers();
    await _broadcastNow();
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer = null;
    _contexts = const [];
    _announcements.clear();

    final socket = _socket;
    _socket = null;
    socket?.close();
    _emitSnapshot();
    await RemoteAssistLog.write('停止 Presence 服务');
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) {
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        RemoteAssistConstants.presencePort,
      );
      socket.readEventsEnabled = true;
      socket.writeEventsEnabled = false;
      socket.broadcastEnabled = false;
      socket.listen(_handleSocketEvent);
      _socket = socket;
      await RemoteAssistLog.write(
          '启动 Presence 监听端口 ${RemoteAssistConstants.presencePort}');
    } catch (error) {
      await RemoteAssistLog.write('启动 Presence 监听失败: $error');
      rethrow;
    }
  }

  void _ensureTimers() {
    _broadcastTimer ??= Timer.periodic(
      RemoteAssistConstants.presenceBroadcastInterval,
      (_) => unawaited(_broadcastNow()),
    );
    _cleanupTimer ??= Timer.periodic(
      RemoteAssistConstants.presenceBroadcastInterval,
      (_) => _cleanupExpiredAnnouncements(),
    );
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _socket!.receive()) != null) {
      final message = utf8.decode(datagram!.data, allowMalformed: true).trim();
      if (message.isEmpty) {
        continue;
      }

      try {
        final decoded = jsonDecode(message);
        if (decoded is! Map<String, dynamic>) {
          continue;
        }
        if ((decoded['type'] ?? '').toString() !=
            RemoteAssistConstants.presencePacketType) {
          continue;
        }

        final announcement = RemoteAssistPresenceAnnouncement.fromJson(decoded);
        if (!isValidIpv4(announcement.virtualIp) ||
            announcement.networkName.trim().isEmpty) {
          continue;
        }

        final isSelf = _contexts.any(
          (context) =>
              context.virtualIp == announcement.virtualIp &&
              context.networkName == announcement.networkName,
        );
        if (isSelf) {
          continue;
        }

        _announcements[buildRemoteAssistPeerKey(
          networkName: announcement.networkName,
          virtualIp: announcement.virtualIp,
        )] = announcement;
        _emitSnapshot();
      } catch (_) {
        // 非法报文直接忽略
      }
    }
  }

  Future<void> _broadcastNow() async {
    final socket = _socket;
    if (socket == null || _contexts.isEmpty) {
      return;
    }

    for (final context in _contexts) {
      final payload = utf8.encode(
        jsonEncode(
          RemoteAssistPresenceAnnouncement(
            displayName: context.displayName,
            virtualIp: context.virtualIp,
            networkName: context.networkName,
            version: context.version,
            capabilities: context.capabilities,
            sentAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
      );

      final targets = context.peerVirtualIps
          .map((ip) => ip.trim())
          .where((ip) => ip.isNotEmpty && ip != context.virtualIp)
          .toSet();

      for (final target in targets) {
        if (!isValidIpv4(target)) {
          continue;
        }
        socket.send(
          payload,
          InternetAddress(target),
          RemoteAssistConstants.presencePort,
        );
      }
    }
  }

  void _cleanupExpiredAnnouncements() {
    final threshold = DateTime.now()
        .subtract(RemoteAssistConstants.presenceExpiry)
        .millisecondsSinceEpoch;
    final expiredKeys = _announcements.entries
        .where((entry) => entry.value.sentAtEpochMs < threshold)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (expiredKeys.isEmpty) {
      return;
    }
    for (final key in expiredKeys) {
      _announcements.remove(key);
    }
    _emitSnapshot();
  }

  void _emitSnapshot() {
    _onSnapshot?.call(Map.unmodifiable(Map.of(_announcements)));
  }
}

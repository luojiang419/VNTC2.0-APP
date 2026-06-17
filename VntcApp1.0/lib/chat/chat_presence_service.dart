import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vnt_app/chat/chat_constants.dart';
import 'package:vnt_app/chat/chat_models.dart';

class ChatPresenceService {
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  List<ChatPresenceContext> _contexts = const [];
  final Map<String, ChatPresenceAnnouncement> _announcements = {};
  void Function(Map<String, ChatPresenceAnnouncement>)? _onSnapshot;

  bool get isRunning => _socket != null;

  Future<void> updateContexts({
    required List<ChatPresenceContext> contexts,
    required void Function(Map<String, ChatPresenceAnnouncement>) onSnapshot,
  }) async {
    _contexts = contexts
        .where(
          (context) => context.virtualIp.trim().isNotEmpty,
        )
        .toList(growable: false);
    _onSnapshot = onSnapshot;

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
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) {
      return;
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      ChatConstants.presencePort,
    );
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = false;
    socket.broadcastEnabled = false;
    socket.listen(_handleSocketEvent);
    _socket = socket;
  }

  void _ensureTimers() {
    _broadcastTimer ??= Timer.periodic(
      ChatConstants.presenceBroadcastInterval,
      (_) => unawaited(_broadcastNow()),
    );
    _cleanupTimer ??= Timer.periodic(
      ChatConstants.presenceBroadcastInterval,
      (_) => _cleanupExpired(),
    );
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _socket!.receive()) != null) {
      final payload = utf8.decode(datagram!.data, allowMalformed: true).trim();
      if (payload.isEmpty) {
        continue;
      }

      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) {
          continue;
        }
        if ((decoded['type'] ?? '').toString() !=
            ChatConstants.presencePacketType) {
          continue;
        }
        final announcement = ChatPresenceAnnouncement.fromJson(decoded);
        final isSelf = _contexts.any(
          (context) =>
              context.hallId == announcement.hallId &&
              context.virtualIp == announcement.virtualIp,
        );
        if (isSelf) {
          continue;
        }
        _announcements[
          buildPresencePeerKey(
            hallId: announcement.hallId,
            virtualIp: announcement.virtualIp,
          )
        ] = announcement;
        _emitSnapshot();
      } catch (_) {
        // 忽略非法报文
      }
    }
  }

  Future<void> _broadcastNow() async {
    final socket = _socket;
    if (socket == null || _contexts.isEmpty) {
      return;
    }

    for (final context in _contexts) {
      final bytes = utf8.encode(
        jsonEncode(
          ChatPresenceAnnouncement(
            hallId: context.hallId,
            hallTitle: context.hallTitle,
            displayName: context.displayName,
            virtualIp: context.virtualIp,
            rooms: context.rooms,
            sentAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
      );
      final targets = context.peerVirtualIps
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty && item != context.virtualIp)
          .toSet();
      for (final target in targets) {
        socket.send(
          bytes,
          InternetAddress(target),
          ChatConstants.presencePort,
        );
      }
    }
  }

  void _cleanupExpired() {
    final threshold = DateTime.now()
        .subtract(ChatConstants.presenceExpiry)
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

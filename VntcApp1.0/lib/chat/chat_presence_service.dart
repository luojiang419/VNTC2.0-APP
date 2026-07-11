import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vnt_app/chat/chat_constants.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_security.dart';

class ChatPresenceService {
  ChatPresenceService({
    int? listenPort,
  }) : _listenPort = listenPort ?? ChatConstants.presencePort;

  final int _listenPort;
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  List<ChatPresenceContext> _contexts = const [];
  String? _contextsSignature;
  final Map<String, ChatPresenceAnnouncement> _announcements = {};
  void Function(Map<String, ChatPresenceAnnouncement>)? _onSnapshot;

  bool get isRunning => _socket != null;
  int? get listeningPort => _socket?.port;

  Future<void> updateContexts({
    required List<ChatPresenceContext> contexts,
    required void Function(Map<String, ChatPresenceAnnouncement>) onSnapshot,
  }) async {
    final nextContexts = contexts
        .where(
          (context) => context.virtualIp.trim().isNotEmpty,
        )
        .toList(growable: false);
    final nextSignature = _signatureForContexts(nextContexts);
    final shouldBroadcastNow =
        _socket == null || nextSignature != _contextsSignature;
    _contexts = nextContexts;
    _contextsSignature = nextSignature;
    _onSnapshot = onSnapshot;

    if (_contexts.isEmpty) {
      await stop();
      return;
    }

    await _ensureSocket();
    _ensureTimers();
    if (shouldBroadcastNow) {
      await _broadcastNow();
    }
  }

  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer = null;
    _contexts = const [];
    _contextsSignature = null;
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
      _listenPort,
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

  String _signatureForContexts(List<ChatPresenceContext> contexts) {
    final signatures = contexts.map((context) {
      final peers = context.peerVirtualIps
          .map((peer) => peer.trim())
          .where((peer) => peer.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
      final rooms = context.rooms.toList(growable: false)
        ..sort((left, right) => left.roomId.compareTo(right.roomId));
      return jsonEncode(<String, Object?>{
        'hallId': context.hallId,
        'hallTitle': context.hallTitle,
        'displayName': context.displayName,
        'virtualIp': context.virtualIp,
        'peers': peers,
        'rooms':
            rooms.map((room) => room.toTransportJson()).toList(growable: false),
      });
    }).toList(growable: false)
      ..sort();
    return signatures.join('\n');
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _socket == null) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _socket!.receive()) != null) {
      final currentDatagram = datagram!;
      final payload =
          utf8.decode(currentDatagram.data, allowMalformed: true).trim();
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
        if (!isChatRemoteAddressConsistent(
          remoteAddress: currentDatagram.address.address,
          declaredVirtualIp: announcement.virtualIp,
        )) {
          continue;
        }
        final isSelf = _contexts.any(
          (context) =>
              context.hallId == announcement.hallId &&
              context.virtualIp == announcement.virtualIp,
        );
        if (isSelf) {
          continue;
        }
        _announcements[buildPresencePeerKey(
          hallId: announcement.hallId,
          virtualIp: announcement.virtualIp,
        )] = announcement;
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

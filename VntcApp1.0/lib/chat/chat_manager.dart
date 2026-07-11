import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:vnt_app/chat/chat_constants.dart';
import 'package:vnt_app/chat/chat_firewall_service.dart';
import 'package:vnt_app/chat/chat_log.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_presence_service.dart';
import 'package:vnt_app/chat/chat_security.dart';
import 'package:vnt_app/chat/chat_storage.dart';
import 'package:vnt_app/chat/chat_transport_service.dart';
import 'package:vnt_app/remote_assist/remote_assist_utils.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

@visibleForTesting
bool isChatSupportedPlatform({
  required bool isWindows,
  required bool isMacOS,
}) {
  return isWindows || isMacOS;
}

@visibleForTesting
String? buildChatStartupIssueMessage({
  String? transportError,
  String? presenceError,
  String? refreshError,
}) {
  final issues = <String>[
    if (transportError?.trim().isNotEmpty == true)
      '消息监听未就绪：${transportError!.trim()}',
    if (presenceError?.trim().isNotEmpty == true)
      '在线状态广播未就绪：${presenceError!.trim()}',
    if (refreshError?.trim().isNotEmpty == true)
      '大厅刷新未就绪：${refreshError!.trim()}',
  ];
  if (issues.isEmpty) {
    return null;
  }
  return issues.join('；');
}

class ChatManager extends ChangeNotifier {
  ChatManager._();

  static final ChatManager instance = ChatManager._();

  final ChatStorage _storage = ChatStorage();
  final ChatPresenceService _presenceService = ChatPresenceService();
  final ChatTransportService _transportService = ChatTransportService();
  final ChatFirewallService _firewallService = ChatFirewallService();
  final Uuid _uuid = const Uuid();

  Timer? _refreshTimer;
  bool _started = false;
  bool _loading = false;
  bool _refreshing = false;
  bool _stopping = false;

  ChatMainTab _selectedTab = ChatMainTab.hall;
  String? _selectedHallId;
  String? _selectedConversationId;

  List<ChatConversation> _conversations = const [];
  List<ChatRoomDescriptor> _rooms = const [];
  final Map<String, List<ChatMessageRecord>> _messageCache = {};
  int _privateUnreadTotal = 0;

  List<ChatHall> _halls = const [];
  Map<String, _LocalHallNode> _localNodes = const {};
  List<_PeerSeed> _basePeers = const [];
  Map<String, ChatPresenceAnnouncement> _presenceCache = const {};
  List<ChatPeerPresence> _onlinePeers = const [];
  Map<String, int> _syncCheckpoints = const {};
  String _lastFirewallStateKey = '';
  String _lastVntSnapshotLogKey = '';
  bool _listeningToVntConnections = false;
  bool _transportStartInProgress = false;
  int _observedVntConnectionCount = 0;
  String? _transportStartError;
  String? _presenceStartError;
  String? _refreshError;
  List<String> _lastSkippedVntStates = const [];

  bool get supported => isChatSupportedPlatform(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
      );
  bool get loading => _loading || _refreshing;
  bool get started => _started;
  ChatMainTab get selectedTab => _selectedTab;
  String? get selectedHallId => _selectedHallId;
  String? get selectedConversationId => _selectedConversationId;
  int get privateUnreadTotal => _privateUnreadTotal;
  List<ChatConversation> get conversations =>
      List<ChatConversation>.unmodifiable(_conversations);
  List<ChatRoomDescriptor> get rooms =>
      List<ChatRoomDescriptor>.unmodifiable(_rooms);
  List<ChatHall> get halls => List<ChatHall>.unmodifiable(_halls);
  List<ChatPeerPresence> get onlinePeers =>
      List<ChatPeerPresence>.unmodifiable(_onlinePeers);
  bool get hasActiveVntConnections =>
      _observedVntConnectionCount > 0 || _hasLiveVntConnectionSnapshot();
  String? get chatStartupIssue => buildChatStartupIssueMessage(
        transportError: _transportStartError,
        presenceError: _presenceStartError,
        refreshError: _refreshError,
      );
  String? get lastVntConnectionIssue =>
      _lastSkippedVntStates.isEmpty ? null : _lastSkippedVntStates.first;
  List<ChatMessageRecord> get selectedMessages =>
      List<ChatMessageRecord>.unmodifiable(
        _messageCache[_selectedConversationId] ?? const [],
      );

  List<ChatConversation> get directConversations =>
      List<ChatConversation>.unmodifiable(
        _conversations
            .where((item) => item.type == ChatConversationType.direct),
      );

  bool _hasLiveVntConnectionSnapshot() {
    for (final box in vntManager.map.values) {
      try {
        if (!box.isClosed()) {
          return true;
        }
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  String? _resolveLocalHallId(String hallId) {
    final normalizedHallId = normalizeChatHallId(hallId);
    if (_localNodes.containsKey(normalizedHallId)) {
      return normalizedHallId;
    }
    if (_localNodes.containsKey(hallId)) {
      return hallId;
    }
    for (final localHallId in _localNodes.keys) {
      if (normalizeChatHallId(localHallId) == normalizedHallId) {
        return localHallId;
      }
    }
    for (final entry in _localNodes.entries) {
      if (entry.value.legacyHallIds.any(
        (alias) =>
            alias == hallId || normalizeChatHallId(alias) == normalizedHallId,
      )) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _mergeDirectConversationAliases() async {
    final conversations = await _storage.loadConversationsByType(
      ChatConversationType.direct,
    );
    for (final conversation in conversations) {
      final localHallId = _resolveLocalHallId(conversation.hallId);
      final peerVirtualIp =
          normalizeChatVirtualIp(conversation.peerVirtualIp ?? '');
      if (localHallId == null || peerVirtualIp.isEmpty) {
        continue;
      }
      final localNode = _localNodes[localHallId]!;
      final canonicalId = buildDirectConversationId(
        hallId: localHallId,
        firstVirtualIp: localNode.hall.localVirtualIp,
        secondVirtualIp: peerVirtualIp,
      );
      if (conversation.id == canonicalId &&
          conversation.hallId == localHallId &&
          conversation.peerVirtualIp == peerVirtualIp) {
        continue;
      }
      await _storage.mergeConversationAlias(
        sourceConversationId: conversation.id,
        targetConversation: ChatConversation(
          id: canonicalId,
          type: ChatConversationType.direct,
          hallId: localHallId,
          title: conversation.title,
          unreadCount: conversation.unreadCount,
          lastReadAtEpochMs: conversation.lastReadAtEpochMs,
          lastMessageAtEpochMs: conversation.lastMessageAtEpochMs,
          updatedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          metadataJson: conversation.metadataJson,
          peerVirtualIp: peerVirtualIp,
          peerDisplayName: conversation.peerDisplayName,
        ),
      );
      if (_selectedConversationId == conversation.id) {
        _selectedConversationId = canonicalId;
      }
    }
  }

  String? _canonicalRoomId(String? roomId, String localHallId) {
    final value = roomId?.trim() ?? '';
    if (value.isEmpty || !value.startsWith('room:')) {
      return value.isEmpty ? null : value;
    }
    final tokenSeparator = value.lastIndexOf(':');
    if (tokenSeparator <= 'room:'.length) {
      return value;
    }
    final creatorSeparator = value.lastIndexOf(':', tokenSeparator - 1);
    if (creatorSeparator <= 'room:'.length) {
      return value;
    }
    final creatorVirtualIp =
        value.substring(creatorSeparator + 1, tokenSeparator);
    final roomToken = value.substring(tokenSeparator + 1);
    if (creatorVirtualIp.trim().isEmpty || roomToken.trim().isEmpty) {
      return value;
    }
    return buildRoomId(
      hallId: localHallId,
      creatorVirtualIp: creatorVirtualIp,
      roomToken: roomToken,
    );
  }

  ChatRoomDescriptor _canonicalizeRoomDescriptor(
    ChatRoomDescriptor room,
    String localHallId,
  ) {
    return ChatRoomDescriptor(
      roomId: _canonicalRoomId(room.roomId, localHallId) ?? room.roomId,
      hallId: localHallId,
      roomName: room.roomName,
      creatorVirtualIp: room.creatorVirtualIp,
      locallyJoined: room.locallyJoined,
      isActive: room.isActive,
      lastSeenAtEpochMs: room.lastSeenAtEpochMs,
      updatedAtEpochMs: room.updatedAtEpochMs,
      metadataJson: room.metadataJson,
    );
  }

  ChatMessageRecord _canonicalizeIncomingMessage(
    ChatMessageRecord message,
    String localHallId,
    _LocalHallNode localNode,
  ) {
    final roomId = _canonicalRoomId(
      message.roomId ??
          (message.conversationType == ChatConversationType.room
              ? message.conversationId
              : null),
      localHallId,
    );
    final conversationId = switch (message.conversationType) {
      ChatConversationType.hall => localHallId,
      ChatConversationType.direct => buildDirectConversationId(
          hallId: localHallId,
          firstVirtualIp: localNode.hall.localVirtualIp,
          secondVirtualIp: message.senderVirtualIp,
        ),
      ChatConversationType.room => roomId ?? message.conversationId,
    };
    return ChatMessageRecord(
      id: message.id,
      conversationId: conversationId,
      hallId: localHallId,
      conversationType: message.conversationType,
      senderVirtualIp: message.senderVirtualIp,
      senderName: message.senderName,
      senderSeq: message.senderSeq,
      direction: message.direction,
      contentType: message.contentType,
      status: message.status,
      text: message.text,
      isSyncMessage: message.isSyncMessage,
      isRead: message.isRead,
      sentAtEpochMs: message.sentAtEpochMs,
      createdAtEpochMs: message.createdAtEpochMs,
      metadataJson: message.metadataJson,
      peerVirtualIp: message.peerVirtualIp,
      roomId: roomId,
      attachmentId: message.attachmentId,
      attachment: message.attachment,
    );
  }

  List<String> _buildLegacyHallIds({
    required String connectServer,
    required String virtualNetwork,
    required Object? networkConfig,
    required String canonicalHallId,
  }) {
    final servers = <String>{
      connectServer,
    };
    try {
      final config = networkConfig as dynamic;
      final primary = config.primaryServerAddress?.toString() ?? '';
      if (primary.trim().isNotEmpty) {
        servers.add(primary);
      }
      final effectiveList = config.effectiveServerList;
      if (effectiveList is Iterable) {
        for (final item in effectiveList) {
          final value = item.toString();
          if (value.trim().isNotEmpty) {
            servers.add(value);
          }
        }
      }
      final compatibleList = config.v2CompatibleServerList;
      if (compatibleList is Iterable) {
        for (final item in compatibleList) {
          final value = item.toString();
          if (value.trim().isNotEmpty) {
            servers.add(value);
          }
        }
      }
    } catch (_) {
      // 兼容测试桩和旧配置对象，取不到配置字段时只保留当前连接服务器。
    }

    return servers
        .expand(
          (server) => buildLegacyChatHallIdCandidates(
            connectServer: server,
            virtualNetwork: virtualNetwork,
          ),
        )
        .where((hallId) => hallId != canonicalHallId)
        .toSet()
        .toList(growable: false);
  }

  String? _legacyRoomIdForHallAlias(String? roomId, String aliasHallId) {
    final value = roomId?.trim() ?? '';
    if (value.isEmpty || !value.startsWith('room:')) {
      return value.isEmpty ? null : value;
    }
    final tokenSeparator = value.lastIndexOf(':');
    if (tokenSeparator <= 'room:'.length) {
      return value;
    }
    final creatorSeparator = value.lastIndexOf(':', tokenSeparator - 1);
    if (creatorSeparator <= 'room:'.length) {
      return value;
    }
    final creatorVirtualIp =
        value.substring(creatorSeparator + 1, tokenSeparator);
    final roomToken = value.substring(tokenSeparator + 1);
    if (creatorVirtualIp.trim().isEmpty || roomToken.trim().isEmpty) {
      return value;
    }
    return buildLegacyRoomId(
      hallId: aliasHallId,
      creatorVirtualIp: creatorVirtualIp,
      roomToken: roomToken,
    );
  }

  String _legacyConversationIdForHallAlias({
    required String conversationId,
    required ChatConversationType type,
    required String aliasHallId,
    required _LocalHallNode localNode,
    required String targetIp,
    String? roomId,
  }) {
    switch (type) {
      case ChatConversationType.hall:
        return aliasHallId;
      case ChatConversationType.direct:
        return buildLegacyDirectConversationId(
          hallId: aliasHallId,
          firstVirtualIp: localNode.hall.localVirtualIp,
          secondVirtualIp: targetIp,
        );
      case ChatConversationType.room:
        return _legacyRoomIdForHallAlias(
                roomId ?? conversationId, aliasHallId) ??
            conversationId;
    }
  }

  ChatMessageRecord _messageForHallAlias({
    required ChatMessageRecord message,
    required String aliasHallId,
    required _LocalHallNode localNode,
    required String targetIp,
  }) {
    final roomId = _legacyRoomIdForHallAlias(message.roomId, aliasHallId);
    return ChatMessageRecord(
      id: message.id,
      conversationId: _legacyConversationIdForHallAlias(
        conversationId: message.conversationId,
        type: message.conversationType,
        aliasHallId: aliasHallId,
        localNode: localNode,
        targetIp: targetIp,
        roomId: roomId,
      ),
      hallId: aliasHallId,
      conversationType: message.conversationType,
      senderVirtualIp: message.senderVirtualIp,
      senderName: message.senderName,
      senderSeq: message.senderSeq,
      direction: message.direction,
      contentType: message.contentType,
      status: message.status,
      text: message.text,
      isSyncMessage: message.isSyncMessage,
      isRead: message.isRead,
      sentAtEpochMs: message.sentAtEpochMs,
      createdAtEpochMs: message.createdAtEpochMs,
      metadataJson: message.metadataJson,
      peerVirtualIp: message.peerVirtualIp,
      roomId: roomId,
      attachmentId: message.attachmentId,
      attachment: message.attachment,
    );
  }

  ChatTransportPacket _packetForHallAlias({
    required ChatTransportPacket packet,
    required String aliasHallId,
    required _LocalHallNode localNode,
    required String targetIp,
  }) {
    final syncRequest = packet.syncRequest;
    return ChatTransportPacket(
      type: packet.type,
      message: packet.message == null
          ? null
          : _messageForHallAlias(
              message: packet.message!,
              aliasHallId: aliasHallId,
              localNode: localNode,
              targetIp: targetIp,
            ),
      syncRequest: syncRequest == null
          ? null
          : ChatSyncRequestPayload(
              hallId: aliasHallId,
              requesterVirtualIp: syncRequest.requesterVirtualIp,
              requesterName: syncRequest.requesterName,
              joinedRoomIds: syncRequest.joinedRoomIds
                  .map((roomId) =>
                      _legacyRoomIdForHallAlias(roomId, aliasHallId) ?? roomId)
                  .toList(growable: false),
              summary: syncRequest.summary.map(
                (conversationId, value) => MapEntry(
                  _legacyConversationIdForHallAlias(
                    conversationId: conversationId,
                    type: conversationId == localNode.hall.id
                        ? ChatConversationType.hall
                        : conversationId.startsWith('dm:')
                            ? ChatConversationType.direct
                            : ChatConversationType.room,
                    aliasHallId: aliasHallId,
                    localNode: localNode,
                    targetIp: targetIp,
                    roomId: conversationId,
                  ),
                  value,
                ),
              ),
            ),
      attachmentBase64: packet.attachmentBase64,
    );
  }

  Future<void> _sendPacketWithHallCompatibility({
    required String targetIp,
    required ChatTransportPacket packet,
    required _LocalHallNode localNode,
  }) async {
    Object? firstError;
    var sent = false;
    final packets = <ChatTransportPacket>[
      packet,
      for (final aliasHallId in localNode.legacyHallIds)
        _packetForHallAlias(
          packet: packet,
          aliasHallId: aliasHallId,
          localNode: localNode,
          targetIp: targetIp,
        ),
    ];
    for (final candidate in packets) {
      try {
        await _transportService.sendPacket(
          targetIp: targetIp,
          packet: candidate,
        );
        sent = true;
      } catch (error) {
        firstError ??= error;
      }
    }
    if (!sent) {
      throw firstError ?? StateError('聊天报文发送失败');
    }
  }

  ChatConversation? get selectedConversation {
    final id = _selectedConversationId;
    if (id == null) {
      return null;
    }
    for (final conversation in _conversations) {
      if (conversation.id == id) {
        return conversation;
      }
    }
    return null;
  }

  List<ChatPeerPresence> hallPeers(String hallId) {
    final peers = _onlinePeers.where((item) => item.hallId == hallId).toList();
    peers.sort((left, right) => left.virtualIp.compareTo(right.virtualIp));
    return peers;
  }

  List<ChatRoomDescriptor> hallRooms(String hallId) {
    final result = _rooms.where((room) => room.hallId == hallId).toList();
    result.sort((left, right) {
      if (left.isActive != right.isActive) {
        return left.isActive ? -1 : 1;
      }
      if (left.locallyJoined != right.locallyJoined) {
        return left.locallyJoined ? -1 : 1;
      }
      return left.roomName.compareTo(right.roomName);
    });
    return result;
  }

  Future<String> resolveAttachmentPath(ChatAttachmentRecord attachment) {
    return _storage.resolveAttachmentPath(attachment.relativePath);
  }

  List<ChatConversation> hallConversations(String hallId) {
    final result = _conversations
        .where((item) => item.hallId == hallId)
        .toList(growable: false);
    return result;
  }

  Future<void> start() async {
    if (_started) {
      if (supported) {
        _ensureVntConnectionListener();
        _ensureRefreshTimer();
        unawaited(_ensureTransportStarted());
        unawaited(refresh());
      }
      return;
    }
    _started = true;
    _stopping = false;

    await _storage.init();
    _syncCheckpoints = await _storage.loadSyncCheckpoints();
    await reloadFromStorage(notify: false);

    if (!supported) {
      await ChatLog.write('聊天室启动跳过：当前平台不支持');
      notifyListeners();
      return;
    }

    _ensureVntConnectionListener();
    _ensureRefreshTimer();
    await _ensureTransportStarted();
    await refresh();
    await ChatLog.write('聊天室管理器已启动');
  }

  Future<void> stop() async {
    _started = false;
    _stopping = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _removeVntConnectionListener();
    await _presenceService.stop();
    await _transportService.stop();
    await ChatLog.write('聊天室管理器已停止');
    _stopping = false;
  }

  void _ensureVntConnectionListener() {
    if (_listeningToVntConnections) {
      return;
    }
    vntManager.addConnectionListener(_handleVntConnectionsChanged);
    _listeningToVntConnections = true;
  }

  void _removeVntConnectionListener() {
    if (!_listeningToVntConnections) {
      return;
    }
    vntManager.removeConnectionListener(_handleVntConnectionsChanged);
    _listeningToVntConnections = false;
  }

  void _handleVntConnectionsChanged() {
    if (!_started || _stopping || !supported) {
      return;
    }
    unawaited(_ensureTransportStarted());
    unawaited(refresh());
  }

  void _ensureRefreshTimer() {
    _refreshTimer ??= Timer.periodic(
      ChatConstants.refreshInterval,
      (_) {
        unawaited(_ensureTransportStarted());
        unawaited(refresh());
      },
    );
  }

  Future<void> _ensureTransportStarted() async {
    if (!supported ||
        _stopping ||
        _transportService.isRunning ||
        _transportStartInProgress) {
      return;
    }
    _transportStartInProgress = true;
    try {
      await _transportService.start(onPacket: _handleTransportPacket);
      _transportStartError = null;
      await ChatLog.write('聊天室消息监听已就绪');
    } catch (error) {
      _transportStartError = error.toString();
      await ChatLog.write(
        '聊天室消息监听启动失败，继续刷新 VNT 大厅: $error',
      );
    } finally {
      _transportStartInProgress = false;
      notifyListeners();
    }
  }

  Future<void> reloadFromStorage({bool notify = true}) async {
    _loading = true;
    if (notify) {
      notifyListeners();
    }
    try {
      _conversations = await _storage.loadConversations();
      _rooms = await _storage.loadRoomDescriptors();
      _privateUnreadTotal = await _storage.loadPrivateUnreadTotal();

      if (_selectedConversationId != null) {
        await loadConversationMessages(_selectedConversationId!);
      }
    } finally {
      _loading = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    if (!_started || _refreshing || _stopping || !supported) {
      return;
    }
    _refreshing = true;
    notifyListeners();
    final refreshIssues = <String>[];
    try {
      var currentRooms = const <ChatRoomDescriptor>[];
      try {
        currentRooms = await _storage.loadRoomDescriptors();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '读取本地聊天室房间缓存',
          error,
          stackTrace,
        );
      }
      final joinedRoomsByHall = <String, List<ChatRoomDescriptor>>{};
      for (final room in currentRooms) {
        if (!room.locallyJoined) {
          continue;
        }
        joinedRoomsByHall.putIfAbsent(
            room.hallId, () => <ChatRoomDescriptor>[]);
        joinedRoomsByHall[room.hallId]!.add(room);
      }

      final nextHalls = <ChatHall>[];
      final nextLocalNodes = <String, _LocalHallNode>{};
      final nextBasePeers = <_PeerSeed>[];
      final skippedStates = <String>[];
      var activeVntConnections = 0;

      for (final entry in vntManager.map.entries.toList(growable: false)) {
        final box = entry.value;
        bool isClosed;
        try {
          isClosed = box.isClosed();
        } catch (error, stackTrace) {
          activeVntConnections += 1;
          skippedStates.add('${entry.key}: 连接状态读取失败 $error');
          await _recordRefreshIssue(
            refreshIssues,
            '读取 VNT 连接状态',
            error,
            stackTrace,
          );
          continue;
        }
        if (isClosed) {
          continue;
        }
        activeVntConnections += 1;
        try {
          final currentDevice = box.currentDevice();
          final networkConfig = box.getNetConfig();
          final localVirtualIp =
              (currentDevice['virtualIp'] ?? '').toString().trim();
          final virtualNetwork =
              (currentDevice['virtualNetwork'] ?? '').toString().trim();
          final connectServer =
              (currentDevice['connectServer'] ?? '').toString().trim();
          final virtualNetmask =
              (currentDevice['virtualNetmask'] ?? '').toString().trim();
          if (localVirtualIp.isEmpty || virtualNetwork.isEmpty) {
            final configName = networkConfig?.configName.trim();
            final status = (currentDevice['status'] ?? '').toString().trim();
            skippedStates.add(
              '${configName?.isNotEmpty == true ? configName : entry.key}: '
              'ip=${localVirtualIp.isEmpty ? "-" : localVirtualIp}, '
              'network=${virtualNetwork.isEmpty ? "-" : virtualNetwork}, '
              'status=${status.isEmpty ? "-" : status}',
            );
            continue;
          }

          final hallId = buildHallId(
            connectServer: connectServer.isEmpty ? 'unknown' : connectServer,
            virtualNetwork: virtualNetwork,
          );
          final hallTitle = networkConfig?.configName.trim().isNotEmpty == true
              ? networkConfig!.configName.trim()
              : (connectServer.isEmpty ? virtualNetwork : connectServer);
          final displayName =
              networkConfig?.deviceName.trim().isNotEmpty == true
                  ? networkConfig!.deviceName.trim()
                  : hallTitle;
          final peerDevices = box.peerDeviceList();
          final peerVirtualIps = peerDevices
              .map((item) => item.virtualIp.trim())
              .where((item) => item.isNotEmpty)
              .toSet()
              .toList(growable: false);

          nextHalls.add(
            ChatHall(
              id: hallId,
              title: hallTitle,
              networkName: virtualNetwork,
              connectServer: connectServer,
              localVirtualIp: localVirtualIp,
              peerVirtualIps: peerVirtualIps,
            ),
          );
          nextLocalNodes[hallId] = _LocalHallNode(
            hall: nextHalls.last,
            displayName: displayName,
            joinedRooms:
                joinedRoomsByHall[hallId] ?? const <ChatRoomDescriptor>[],
            networkCidr: cidrFromNetworkAndMask(virtualNetwork, virtualNetmask),
            legacyHallIds: _buildLegacyHallIds(
              connectServer: connectServer.isEmpty ? 'unknown' : connectServer,
              virtualNetwork: virtualNetwork,
              networkConfig: networkConfig,
              canonicalHallId: hallId,
            ),
          );

          for (final peer in peerDevices) {
            final status = peer.status.trim().toLowerCase();
            nextBasePeers.add(
              _PeerSeed(
                key: buildPresencePeerKey(
                  hallId: hallId,
                  virtualIp: peer.virtualIp.trim(),
                ),
                hallId: hallId,
                hallTitle: hallTitle,
                virtualIp: peer.virtualIp.trim(),
                displayName: peer.name.trim().isEmpty
                    ? peer.virtualIp.trim()
                    : peer.name.trim(),
                isOnline: status == 'online',
              ),
            );
          }
        } catch (error, stackTrace) {
          skippedStates.add('${entry.key}: VNT 设备信息读取失败 $error');
          await _recordRefreshIssue(
            refreshIssues,
            '读取 VNT 设备信息',
            error,
            stackTrace,
          );
        }
      }

      _halls = nextHalls;
      _localNodes = nextLocalNodes;
      _basePeers = nextBasePeers;
      _observedVntConnectionCount = activeVntConnections;
      _lastSkippedVntStates = List<String>.unmodifiable(skippedStates);
      await _logVntSnapshotIfChanged(
        activeVntConnections: activeVntConnections,
        halls: nextHalls,
        skippedStates: skippedStates,
      );

      try {
        await _mergeDirectConversationAliases();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '合并重复私聊会话',
          error,
          stackTrace,
        );
      }

      try {
        await _ensureHallConversations();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '写入大厅会话',
          error,
          stackTrace,
        );
      }
      try {
        await _presenceService.updateContexts(
          contexts: nextLocalNodes.values
              .map(
                (node) => ChatPresenceContext(
                  hallId: node.hall.id,
                  hallTitle: node.hall.title,
                  displayName: node.displayName,
                  virtualIp: node.hall.localVirtualIp,
                  peerVirtualIps: node.hall.peerVirtualIps,
                  rooms: node.joinedRooms,
                ),
              )
              .toList(growable: false),
          onSnapshot: _handlePresenceSnapshot,
        );
        _presenceStartError = null;
      } catch (error) {
        _presenceStartError = error.toString();
        await ChatLog.write(
          '聊天室在线状态广播更新失败，继续保留 VNT 大厅: $error',
        );
      }

      try {
        await _reconcilePresenceAndRooms();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '同步聊天室房间状态',
          error,
          stackTrace,
        );
      }
      try {
        await reloadFromStorage(notify: false);
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '重新加载聊天记录',
          error,
          stackTrace,
        );
      }
      try {
        _mergeOnlinePeers();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '合并在线用户',
          error,
          stackTrace,
        );
      }
      try {
        await _syncKnownPeers();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '同步已知聊天节点',
          error,
          stackTrace,
        );
      }
      try {
        await _syncFirewallRulesIfNeeded();
      } catch (error, stackTrace) {
        await _recordRefreshIssue(
          refreshIssues,
          '同步聊天防火墙规则',
          error,
          stackTrace,
        );
      }

      if (_selectedHallId == null && _halls.isNotEmpty) {
        _selectedHallId = _halls.first.id;
      }
      if (_selectedConversationId == null && _selectedHallId != null) {
        _selectedConversationId = _selectedHallId;
        try {
          await loadConversationMessages(_selectedConversationId!);
        } catch (error, stackTrace) {
          await _recordRefreshIssue(
            refreshIssues,
            '加载当前大厅消息',
            error,
            stackTrace,
          );
        }
      }
      _refreshError = refreshIssues.isEmpty ? null : refreshIssues.join('；');
    } catch (error, stackTrace) {
      _refreshError = error.toString();
      await ChatLog.write('聊天室刷新流程异常: $error\n$stackTrace');
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> _recordRefreshIssue(
    List<String> issues,
    String stage,
    Object error,
    StackTrace stackTrace,
  ) async {
    final message = '$stage失败: $error';
    issues.add(message);
    await ChatLog.write('聊天室刷新阶段失败 $stage: $error\n$stackTrace');
  }

  Future<void> _logVntSnapshotIfChanged({
    required int activeVntConnections,
    required List<ChatHall> halls,
    required List<String> skippedStates,
  }) async {
    final hallSummary = halls
        .map((hall) =>
            '${hall.title}/${hall.localVirtualIp}/${hall.networkName}')
        .join(',');
    final skippedSummary = skippedStates.join('; ');
    final stateKey = '$activeVntConnections|$hallSummary|$skippedSummary';
    if (_lastVntSnapshotLogKey == stateKey) {
      return;
    }
    _lastVntSnapshotLogKey = stateKey;
    if (halls.isEmpty && activeVntConnections > 0) {
      await ChatLog.write(
        '聊天室刷新未生成大厅 activeVntConnections=$activeVntConnections skipped=$skippedSummary',
      );
      return;
    }
    await ChatLog.write(
      '聊天室刷新完成 activeVntConnections=$activeVntConnections halls=${halls.length} halls=[$hallSummary]',
    );
  }

  Future<void> selectTab(ChatMainTab tab) async {
    _selectedTab = tab;
    final conversation = selectedConversation;
    if (conversation != null &&
        conversation.type == ChatConversationType.direct) {
      await markConversationRead(conversation.id, notify: false);
    }
    notifyListeners();
  }

  Future<void> selectHall(String hallId) async {
    _selectedHallId = hallId;
    _selectedTab = ChatMainTab.hall;
    await openConversation(hallId);
  }

  Future<void> openConversation(String conversationId) async {
    _selectedConversationId = conversationId;
    await loadConversationMessages(conversationId);
    final conversation = selectedConversation;
    if (conversation != null &&
        conversation.type == ChatConversationType.direct) {
      await markConversationRead(conversationId, notify: false);
    }
    notifyListeners();
  }

  Future<void> loadConversationMessages(String conversationId) async {
    _messageCache[conversationId] = await _storage.loadMessages(
      conversationId,
      limit: 500,
    );
  }

  Future<void> markConversationRead(
    String conversationId, {
    bool notify = true,
  }) async {
    await _storage.markConversationRead(conversationId);
    await reloadFromStorage(notify: false);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> openDirectChat(ChatPeerPresence peer) async {
    final localNode = _localNodes[peer.hallId];
    if (localNode == null) {
      throw StateError('当前大厅未在线，暂时无法发起私聊');
    }
    final conversationId = buildDirectConversationId(
      hallId: peer.hallId,
      firstVirtualIp: localNode.hall.localVirtualIp,
      secondVirtualIp: peer.virtualIp,
    );
    final existing = await _storage.getConversation(conversationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _storage.upsertConversation(
      ChatConversation(
        id: conversationId,
        type: ChatConversationType.direct,
        hallId: peer.hallId,
        title: peer.displayName,
        unreadCount: existing?.unreadCount ?? 0,
        lastReadAtEpochMs: existing?.lastReadAtEpochMs ?? 0,
        lastMessageAtEpochMs: existing?.lastMessageAtEpochMs ?? 0,
        updatedAtEpochMs: now,
        metadataJson: existing?.metadataJson ?? '{}',
        peerVirtualIp: peer.virtualIp,
        peerDisplayName: peer.displayName,
      ),
    );
    await reloadFromStorage(notify: false);
    _selectedHallId = peer.hallId;
    _selectedTab = ChatMainTab.direct;
    await openConversation(conversationId);
  }

  Future<void> createRoom(String hallId, String roomName) async {
    final localNode = _localNodes[hallId];
    if (localNode == null) {
      throw StateError('当前大厅未在线，暂时无法创建房间');
    }
    final trimmed = roomName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('请输入聊天室名称');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final roomId = buildRoomId(
      hallId: hallId,
      creatorVirtualIp: localNode.hall.localVirtualIp,
      roomToken: _uuid.v4(),
    );
    final room = ChatRoomDescriptor(
      roomId: roomId,
      hallId: hallId,
      roomName: trimmed,
      creatorVirtualIp: localNode.hall.localVirtualIp,
      locallyJoined: true,
      isActive: true,
      lastSeenAtEpochMs: now,
      updatedAtEpochMs: now,
    );
    await _storage.upsertRoomDescriptor(room);
    await _ensureRoomConversation(room);
    await reloadFromStorage(notify: false);
    await refresh();
    await openConversation(roomId);
  }

  Future<void> joinRoom(ChatRoomDescriptor room) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _storage.upsertRoomDescriptor(
      room.copyWith(
        locallyJoined: true,
        isActive: true,
        lastSeenAtEpochMs: now,
        updatedAtEpochMs: now,
      ),
    );
    await _ensureRoomConversation(room);
    await reloadFromStorage(notify: false);
    await refresh();
    await openConversation(room.roomId);
  }

  Future<void> leaveRoom(ChatRoomDescriptor room) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _storage.upsertRoomDescriptor(
      room.copyWith(
        locallyJoined: false,
        updatedAtEpochMs: now,
      ),
    );
    await reloadFromStorage(notify: false);
    await refresh();
  }

  Future<ChatSendResult> sendText({
    required String conversationId,
    required String text,
  }) async {
    final conversation = _conversations
        .where((item) => item.id == conversationId)
        .cast<ChatConversation?>()
        .firstWhere((_) => true, orElse: () => null);
    if (conversation == null) {
      throw StateError('未找到当前会话');
    }

    final localNode = _localNodes[conversation.hallId];
    if (localNode == null) {
      throw StateError('当前大厅未在线，无法发送消息');
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return ChatSendResult(
        conversationId: conversation.id,
        attemptedRecipients: 0,
        deliveredRecipients: 0,
        failedRecipients: 0,
        finalStatus: ChatMessageStatus.sent,
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final senderSeq = await _storage.nextSenderSequence(
      conversation.id,
      localNode.hall.localVirtualIp,
    );
    final recipients = _resolveRecipients(conversation);
    var deliveredRecipients = 0;
    var failedRecipients = 0;
    final outboundPacket = ChatTransportPacket(
      type: 'message',
      message: ChatMessageRecord(
        id: _uuid.v4(),
        conversationId: conversation.id,
        hallId: conversation.hallId,
        conversationType: conversation.type,
        senderVirtualIp: localNode.hall.localVirtualIp,
        senderName: localNode.displayName,
        senderSeq: senderSeq,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.text,
        status: ChatMessageStatus.sent,
        text: trimmed,
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: now,
        createdAtEpochMs: now,
        metadataJson: '{}',
        peerVirtualIp: conversation.peerVirtualIp,
        roomId: conversation.roomId,
      ),
    );
    for (final recipient in recipients) {
      try {
        await _sendPacketWithHallCompatibility(
          targetIp: recipient,
          packet: outboundPacket,
          localNode: localNode,
        );
        deliveredRecipients += 1;
      } catch (error) {
        failedRecipients += 1;
        await ChatLog.write(
          '文本消息发送失败 conversation=${conversation.id} target=$recipient error=$error',
        );
      }
    }
    final finalStatus = deliveredRecipients > 0
        ? ChatMessageStatus.sent
        : ChatMessageStatus.failed;

    final localMessage = ChatMessageRecord(
      id: _uuid.v4(),
      conversationId: conversation.id,
      hallId: conversation.hallId,
      conversationType: conversation.type,
      senderVirtualIp: localNode.hall.localVirtualIp,
      senderName: localNode.displayName,
      senderSeq: senderSeq,
      direction: ChatMessageDirection.outgoing,
      contentType: ChatMessageContentType.text,
      status: finalStatus,
      text: trimmed,
      isSyncMessage: false,
      isRead: true,
      sentAtEpochMs: now,
      createdAtEpochMs: now,
      metadataJson: '{}',
      peerVirtualIp: conversation.peerVirtualIp,
      roomId: conversation.roomId,
    );
    await _storage.upsertMessage(localMessage);
    await loadConversationMessages(conversation.id);
    await reloadFromStorage(notify: false);
    notifyListeners();
    final result = ChatSendResult(
      conversationId: conversation.id,
      attemptedRecipients: recipients.length,
      deliveredRecipients: deliveredRecipients,
      failedRecipients: failedRecipients,
      finalStatus: finalStatus,
    );
    await ChatLog.write(
      '文本消息发送完成 conversation=${conversation.id} attempted=${result.attemptedRecipients} delivered=${result.deliveredRecipients} failed=${result.failedRecipients} status=${chatEnumName(result.finalStatus)}',
    );
    return result;
  }

  Future<ChatSendResult> sendAttachment({
    required String conversationId,
    required String sourceFilePath,
    ChatMessageContentType? explicitContentType,
    int? durationMs,
  }) async {
    final conversation = _conversations
        .where((item) => item.id == conversationId)
        .cast<ChatConversation?>()
        .firstWhere((_) => true, orElse: () => null);
    if (conversation == null) {
      throw StateError('未找到当前会话');
    }
    final localNode = _localNodes[conversation.hallId];
    if (localNode == null) {
      throw StateError('当前大厅未在线，无法发送附件');
    }

    final sourceFile = File(sourceFilePath);
    if (!await sourceFile.exists()) {
      throw StateError('附件文件不存在');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final messageId = _uuid.v4();
    final attachmentId = _uuid.v4();
    final senderSeq = await _storage.nextSenderSequence(
      conversation.id,
      localNode.hall.localVirtualIp,
    );
    final mimeType =
        lookupMimeType(sourceFilePath) ?? 'application/octet-stream';
    final sizeBytes = await sourceFile.length();
    final contentType = explicitContentType ??
        _contentTypeFromMimeType(
          mimeType,
          fallbackPath: sourceFilePath,
        );
    final relativePath = await _storage.importAttachmentFile(
      sourceFilePath,
      messageId: messageId,
    );
    final attachment = ChatAttachmentRecord(
      id: attachmentId,
      messageId: messageId,
      fileName: path.basename(sourceFilePath),
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      relativePath: relativePath,
      durationMs: durationMs,
      autoSyncEligible: sizeBytes <= ChatConstants.smallAttachmentMaxBytes,
      payloadAvailable: true,
      needsManualResend: false,
      createdAtEpochMs: now,
    );
    final bytes = await sourceFile.readAsBytes();
    final recipients = _resolveRecipients(conversation);
    var deliveredRecipients = 0;
    var failedRecipients = 0;
    final outboundPacket = ChatTransportPacket(
      type: 'message',
      message: ChatMessageRecord(
        id: messageId,
        conversationId: conversation.id,
        hallId: conversation.hallId,
        conversationType: conversation.type,
        senderVirtualIp: localNode.hall.localVirtualIp,
        senderName: localNode.displayName,
        senderSeq: senderSeq,
        direction: ChatMessageDirection.outgoing,
        contentType: contentType,
        status: ChatMessageStatus.sent,
        text: attachment.fileName,
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: now,
        createdAtEpochMs: now,
        metadataJson: '{}',
        peerVirtualIp: conversation.peerVirtualIp,
        roomId: conversation.roomId,
        attachmentId: attachment.id,
        attachment: attachment,
      ),
      attachmentBase64: base64Encode(bytes),
    );
    for (final recipient in recipients) {
      try {
        await _sendPacketWithHallCompatibility(
          targetIp: recipient,
          packet: outboundPacket,
          localNode: localNode,
        );
        deliveredRecipients += 1;
      } catch (error) {
        failedRecipients += 1;
        await ChatLog.write(
          '附件消息发送失败 conversation=${conversation.id} target=$recipient file=${attachment.fileName} error=$error',
        );
      }
    }
    final finalStatus = deliveredRecipients > 0
        ? ChatMessageStatus.sent
        : ChatMessageStatus.failed;

    await _storage.upsertMessage(
      ChatMessageRecord(
        id: messageId,
        conversationId: conversation.id,
        hallId: conversation.hallId,
        conversationType: conversation.type,
        senderVirtualIp: localNode.hall.localVirtualIp,
        senderName: localNode.displayName,
        senderSeq: senderSeq,
        direction: ChatMessageDirection.outgoing,
        contentType: contentType,
        status: finalStatus,
        text: attachment.fileName,
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: now,
        createdAtEpochMs: now,
        metadataJson: '{}',
        peerVirtualIp: conversation.peerVirtualIp,
        roomId: conversation.roomId,
        attachmentId: attachment.id,
        attachment: attachment,
      ),
      attachment: attachment,
    );
    await loadConversationMessages(conversation.id);
    await reloadFromStorage(notify: false);
    notifyListeners();
    final result = ChatSendResult(
      conversationId: conversation.id,
      attemptedRecipients: recipients.length,
      deliveredRecipients: deliveredRecipients,
      failedRecipients: failedRecipients,
      finalStatus: finalStatus,
    );
    await ChatLog.write(
      '附件消息发送完成 conversation=${conversation.id} attempted=${result.attemptedRecipients} delivered=${result.deliveredRecipients} failed=${result.failedRecipients} status=${chatEnumName(result.finalStatus)}',
    );
    return result;
  }

  Future<ChatSendResult> resendMessage(ChatMessageRecord message) async {
    if (message.contentType == ChatMessageContentType.text) {
      return sendText(
        conversationId: message.conversationId,
        text: message.text,
      );
    }
    final attachment = message.attachment;
    if (attachment == null) {
      throw StateError('附件记录缺失，无法重发');
    }
    final filePath =
        await _storage.resolveAttachmentPath(attachment.relativePath);
    return sendAttachment(
      conversationId: message.conversationId,
      sourceFilePath: filePath,
      explicitContentType: message.contentType,
      durationMs: attachment.durationMs,
    );
  }

  Future<void> _handleTransportPacket(
    ChatTransportPacket packet,
    InternetAddress remoteAddress,
  ) async {
    await ChatLog.write(
      '处理聊天报文 type=${packet.type} remote=${remoteAddress.address}',
    );
    if (packet.type == 'message' && packet.message != null) {
      if (!isChatRemoteAddressConsistent(
        remoteAddress: remoteAddress.address,
        declaredVirtualIp: packet.message!.senderVirtualIp,
      )) {
        await ChatLog.write(
          '丢弃身份不匹配的聊天消息 remote=${remoteAddress.address} declared=${packet.message!.senderVirtualIp}',
        );
        return;
      }
      await _handleIncomingMessage(
        packet.message!,
        attachmentBase64: packet.attachmentBase64,
      );
      return;
    }
    if (packet.type == 'sync_request' && packet.syncRequest != null) {
      if (!isChatRemoteAddressConsistent(
        remoteAddress: remoteAddress.address,
        declaredVirtualIp: packet.syncRequest!.requesterVirtualIp,
      )) {
        await ChatLog.write(
          '丢弃身份不匹配的聊天补同步请求 remote=${remoteAddress.address} declared=${packet.syncRequest!.requesterVirtualIp}',
        );
        return;
      }
      await _handleSyncRequest(packet.syncRequest!, remoteAddress.address);
    }
  }

  Future<void> _handleIncomingMessage(
    ChatMessageRecord rawRemoteMessage, {
    String? attachmentBase64,
  }) async {
    final localHallId = _resolveLocalHallId(rawRemoteMessage.hallId);
    if (localHallId == null) {
      await ChatLog.write(
        '丢弃聊天消息 conversation=${rawRemoteMessage.conversationId} hall=${rawRemoteMessage.hallId} normalizedHall=${normalizeChatHallId(rawRemoteMessage.hallId)} reason=local_hall_offline',
      );
      return;
    }
    final localNode = _localNodes[localHallId]!;
    final remoteMessage = _canonicalizeIncomingMessage(
      rawRemoteMessage,
      localHallId,
      localNode,
    );

    final conversationId = remoteMessage.conversationId;
    final existing = await _storage.getConversation(conversationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final isOpenDirectConversation = _selectedTab == ChatMainTab.direct &&
        _selectedConversationId == conversationId;
    final shouldIncrementUnread =
        remoteMessage.conversationType == ChatConversationType.direct &&
            !isOpenDirectConversation &&
            remoteMessage.sentAtEpochMs > (existing?.lastReadAtEpochMs ?? 0);

    ChatAttachmentRecord? incomingAttachment = remoteMessage.attachment;
    if (incomingAttachment != null) {
      if (attachmentBase64 != null && attachmentBase64.isNotEmpty) {
        final bytes = base64Decode(attachmentBase64);
        await _storage.writeAttachmentBytes(
          incomingAttachment.relativePath,
          bytes,
        );
        incomingAttachment = incomingAttachment.copyWith(
          payloadAvailable: true,
          needsManualResend: false,
        );
      } else if (!incomingAttachment.autoSyncEligible) {
        incomingAttachment = incomingAttachment.copyWith(
          payloadAvailable: false,
          needsManualResend: true,
        );
      } else {
        final existingPath = await _storage.resolveAttachmentPath(
          incomingAttachment.relativePath,
        );
        if (!await File(existingPath).exists()) {
          incomingAttachment = incomingAttachment.copyWith(
            payloadAvailable: false,
            needsManualResend: true,
          );
        }
      }
    }

    final title = _resolveConversationTitleForIncoming(remoteMessage);
    await _storage.upsertConversation(
      ChatConversation(
        id: conversationId,
        type: remoteMessage.conversationType,
        hallId: remoteMessage.hallId,
        title: title,
        unreadCount: existing?.unreadCount ?? 0,
        lastReadAtEpochMs: existing?.lastReadAtEpochMs ?? 0,
        lastMessageAtEpochMs: remoteMessage.sentAtEpochMs,
        updatedAtEpochMs: now,
        metadataJson: existing?.metadataJson ?? '{}',
        peerVirtualIp:
            remoteMessage.conversationType == ChatConversationType.direct
                ? remoteMessage.senderVirtualIp
                : existing?.peerVirtualIp,
        peerDisplayName:
            remoteMessage.conversationType == ChatConversationType.direct
                ? remoteMessage.senderName
                : existing?.peerDisplayName,
        roomId: remoteMessage.roomId ?? existing?.roomId,
      ),
    );

    final localMessage = ChatMessageRecord(
      id: remoteMessage.id,
      conversationId: conversationId,
      hallId: remoteMessage.hallId,
      conversationType: remoteMessage.conversationType,
      senderVirtualIp: remoteMessage.senderVirtualIp,
      senderName: remoteMessage.senderName,
      senderSeq: remoteMessage.senderSeq,
      direction: ChatMessageDirection.incoming,
      contentType: remoteMessage.contentType,
      status: remoteMessage.status,
      text: remoteMessage.text,
      isSyncMessage: remoteMessage.isSyncMessage,
      isRead: !shouldIncrementUnread,
      sentAtEpochMs: remoteMessage.sentAtEpochMs,
      createdAtEpochMs: remoteMessage.createdAtEpochMs,
      metadataJson: remoteMessage.metadataJson,
      peerVirtualIp:
          remoteMessage.conversationType == ChatConversationType.direct
              ? remoteMessage.senderVirtualIp
              : remoteMessage.peerVirtualIp,
      roomId: remoteMessage.roomId,
      attachmentId: remoteMessage.attachmentId,
      attachment: incomingAttachment,
    );
    await _storage.upsertMessage(
      localMessage,
      attachment: incomingAttachment,
      incrementUnread: shouldIncrementUnread,
    );
    if (!shouldIncrementUnread &&
        remoteMessage.conversationType == ChatConversationType.direct) {
      await _storage.markConversationRead(conversationId);
    }
    await reloadFromStorage(notify: false);
    if (_selectedConversationId == conversationId) {
      await loadConversationMessages(conversationId);
    }
    notifyListeners();
    await ChatLog.write(
      '聊天消息已入库 conversation=$conversationId sender=${remoteMessage.senderVirtualIp} type=${chatEnumName(remoteMessage.contentType)} unreadIncremented=$shouldIncrementUnread',
    );
  }

  Future<void> _handleSyncRequest(
    ChatSyncRequestPayload payload,
    String remoteIp,
  ) async {
    final localHallId = _resolveLocalHallId(payload.hallId);
    await ChatLog.write(
      '收到聊天补同步请求 hall=${payload.hallId} mappedHall=${localHallId ?? "-"} requester=${payload.requesterVirtualIp} remote=$remoteIp joinedRooms=${payload.joinedRoomIds.length}',
    );
    if (localHallId == null) {
      return;
    }
    final localNode = _localNodes[localHallId]!;
    final conversationIds = <String>{
      localHallId,
      buildDirectConversationId(
        hallId: localHallId,
        firstVirtualIp: localNode.hall.localVirtualIp,
        secondVirtualIp: payload.requesterVirtualIp,
      ),
      ...payload.joinedRoomIds,
    };
    final missingMessages = await _storage.loadMissingMessages(
      conversationIds: conversationIds,
      remoteSummary: payload.summary,
    );
    for (final message in missingMessages) {
      String? attachmentBase64;
      var syncMessage = message;
      if (message.attachment != null) {
        final attachment = message.attachment!;
        if (attachment.autoSyncEligible && attachment.payloadAvailable) {
          final filePath = await _storage.resolveAttachmentPath(
            attachment.relativePath,
          );
          final file = File(filePath);
          if (await file.exists()) {
            attachmentBase64 = base64Encode(await file.readAsBytes());
          } else {
            syncMessage = message.copyWith(
              attachment: attachment.copyWith(
                payloadAvailable: false,
                needsManualResend: true,
              ),
            );
          }
        } else {
          syncMessage = message.copyWith(
            attachment: attachment.copyWith(
              payloadAvailable: false,
              needsManualResend: true,
            ),
          );
        }
      }
      try {
        await _sendPacketWithHallCompatibility(
          targetIp: remoteIp,
          packet: ChatTransportPacket(
            type: 'message',
            message: syncMessage.copyWith(
              status: ChatMessageStatus.sent,
            ),
            attachmentBase64: attachmentBase64,
          ),
          localNode: localNode,
        );
      } catch (_) {
        // 同步阶段失败，等待下次 Presence 驱动重新补齐
      }
    }
  }

  Future<void> _syncKnownPeers() async {
    if (_onlinePeers.isEmpty || _localNodes.isEmpty) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final peer in _onlinePeers) {
      final lastSync = _syncCheckpoints[peer.key] ?? 0;
      if (now - lastSync < ChatConstants.syncInterval.inMilliseconds) {
        continue;
      }
      final localNode = _localNodes[peer.hallId];
      if (localNode == null) {
        continue;
      }
      final conversationIds = <String>{
        peer.hallId,
        buildDirectConversationId(
          hallId: peer.hallId,
          firstVirtualIp: localNode.hall.localVirtualIp,
          secondVirtualIp: peer.virtualIp,
        ),
        ...localNode.joinedRooms.map((item) => item.roomId),
      };
      final summary = await _storage.buildSummaryForConversations(
        conversationIds: conversationIds,
      );
      try {
        await _sendPacketWithHallCompatibility(
          targetIp: peer.virtualIp,
          packet: ChatTransportPacket(
            type: 'sync_request',
            syncRequest: ChatSyncRequestPayload(
              hallId: peer.hallId,
              requesterVirtualIp: localNode.hall.localVirtualIp,
              requesterName: localNode.displayName,
              joinedRoomIds:
                  localNode.joinedRooms.map((item) => item.roomId).toList(),
              summary: summary,
            ),
          ),
          localNode: localNode,
        );
        _syncCheckpoints = Map<String, int>.from(_syncCheckpoints)
          ..[peer.key] = now;
        await _storage.recordSyncCheckpoint(
          peerKey: peer.key,
          hallId: peer.hallId,
          timestampEpochMs: now,
        );
      } catch (_) {
        // 忽略单个节点同步失败
      }
    }
  }

  Future<void> _ensureHallConversations() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final hall in _halls) {
      final existing = await _storage.getConversation(hall.id);
      await _storage.upsertConversation(
        ChatConversation(
          id: hall.id,
          type: ChatConversationType.hall,
          hallId: hall.id,
          title: hall.title,
          unreadCount: existing?.unreadCount ?? 0,
          lastReadAtEpochMs: existing?.lastReadAtEpochMs ?? 0,
          lastMessageAtEpochMs: existing?.lastMessageAtEpochMs ?? 0,
          updatedAtEpochMs: timestamp,
          metadataJson: existing?.metadataJson ?? '{}',
        ),
      );
    }
  }

  Future<void> _reconcilePresenceAndRooms() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final localRooms = await _storage.loadRoomDescriptors();
    final mergedRooms = <String, ChatRoomDescriptor>{
      for (final room in localRooms) room.roomId: room,
    };
    final activeRoomIdsByHall = <String, Set<String>>{};

    for (final node in _localNodes.values) {
      for (final room in node.joinedRooms) {
        mergedRooms[room.roomId] = room.copyWith(
          isActive: true,
          lastSeenAtEpochMs: now,
          updatedAtEpochMs: now,
        );
        activeRoomIdsByHall.putIfAbsent(room.hallId, () => <String>{});
        activeRoomIdsByHall[room.hallId]!.add(room.roomId);
      }
    }

    for (final announcement in _presenceCache.values) {
      for (final room in announcement.rooms) {
        final existing = mergedRooms[room.roomId];
        mergedRooms[room.roomId] = (existing ?? room).copyWith(
          isActive: true,
          lastSeenAtEpochMs: announcement.sentAtEpochMs,
          updatedAtEpochMs: now,
        );
        activeRoomIdsByHall.putIfAbsent(room.hallId, () => <String>{});
        activeRoomIdsByHall[room.hallId]!.add(room.roomId);
      }
    }

    for (final room in mergedRooms.values) {
      await _storage.upsertRoomDescriptor(room);
      await _ensureRoomConversation(room);
    }
    for (final hall in _halls) {
      await _storage.syncRoomActivityForHall(
        hallId: hall.id,
        activeRoomIds: activeRoomIdsByHall[hall.id] ?? <String>{},
        timestampEpochMs: now,
      );
    }
  }

  Future<void> _ensureRoomConversation(ChatRoomDescriptor room) async {
    final existing = await _storage.getConversation(room.roomId);
    await _storage.upsertConversation(
      ChatConversation(
        id: room.roomId,
        type: ChatConversationType.room,
        hallId: room.hallId,
        title: room.roomName,
        unreadCount: existing?.unreadCount ?? 0,
        lastReadAtEpochMs: existing?.lastReadAtEpochMs ?? 0,
        lastMessageAtEpochMs: existing?.lastMessageAtEpochMs ?? 0,
        updatedAtEpochMs: room.updatedAtEpochMs,
        metadataJson: existing?.metadataJson ?? '{}',
        roomId: room.roomId,
      ),
    );
  }

  void _handlePresenceSnapshot(
    Map<String, ChatPresenceAnnouncement> snapshot,
  ) {
    final normalizedSnapshot = <String, ChatPresenceAnnouncement>{};
    for (final announcement in snapshot.values) {
      final localHallId = _resolveLocalHallId(announcement.hallId);
      if (localHallId == null) {
        continue;
      }
      final normalizedAnnouncement = ChatPresenceAnnouncement(
        hallId: localHallId,
        hallTitle: announcement.hallTitle,
        displayName: announcement.displayName,
        virtualIp: announcement.virtualIp,
        rooms: announcement.rooms
            .map((room) => _canonicalizeRoomDescriptor(room, localHallId))
            .toList(growable: false),
        sentAtEpochMs: announcement.sentAtEpochMs,
      );
      normalizedSnapshot[buildPresencePeerKey(
        hallId: localHallId,
        virtualIp: announcement.virtualIp,
      )] = normalizedAnnouncement;
    }
    _presenceCache = normalizedSnapshot;
    _mergeOnlinePeers();
    unawaited(_reconcilePresenceAndRooms().then((_) async {
      await reloadFromStorage(notify: false);
      notifyListeners();
    }));
  }

  void _mergeOnlinePeers() {
    final peers = <ChatPeerPresence>[];
    for (final peer in _basePeers) {
      if (!peer.isOnline) {
        continue;
      }
      final announcement = _presenceCache[peer.key];
      peers.add(
        ChatPeerPresence(
          key: peer.key,
          hallId: peer.hallId,
          hallTitle: peer.hallTitle,
          displayName: announcement?.displayName.trim().isEmpty != false
              ? peer.displayName
              : announcement!.displayName.trim(),
          virtualIp: peer.virtualIp,
          isOnline: true,
          rooms: announcement?.rooms ?? const <ChatRoomDescriptor>[],
          sentAtEpochMs: announcement?.sentAtEpochMs ?? 0,
        ),
      );
    }
    peers.sort((left, right) {
      final hallCompare = left.hallTitle.compareTo(right.hallTitle);
      if (hallCompare != 0) {
        return hallCompare;
      }
      return left.virtualIp.compareTo(right.virtualIp);
    });
    _onlinePeers = peers;
  }

  List<String> _resolveRecipients(ChatConversation conversation) {
    if (conversation.type == ChatConversationType.direct) {
      final peerIp = conversation.peerVirtualIp?.trim() ?? '';
      if (peerIp.isEmpty) {
        return const [];
      }
      final isPeerOnline = _onlinePeers.any(
        (peer) =>
            peer.hallId == conversation.hallId && peer.virtualIp == peerIp,
      );
      return isPeerOnline ? <String>[peerIp] : const <String>[];
    }

    if (conversation.type == ChatConversationType.hall) {
      return hallPeers(conversation.hallId)
          .map((peer) => peer.virtualIp)
          .toSet()
          .toList(growable: false);
    }

    final roomId = conversation.roomId ?? conversation.id;
    return _onlinePeers
        .where(
          (peer) =>
              peer.hallId == conversation.hallId &&
              peer.rooms.any((room) => room.roomId == roomId),
        )
        .map((peer) => peer.virtualIp)
        .toSet()
        .toList(growable: false);
  }

  String _resolveConversationTitleForIncoming(ChatMessageRecord message) {
    if (message.conversationType == ChatConversationType.direct) {
      return message.senderName.trim().isEmpty
          ? message.senderVirtualIp
          : message.senderName.trim();
    }
    if (message.conversationType == ChatConversationType.room) {
      final room = _rooms
          .where((item) => item.roomId == message.conversationId)
          .cast<ChatRoomDescriptor?>()
          .firstWhere((_) => true, orElse: () => null);
      return room?.roomName ?? '聊天室';
    }
    final hall = _halls
        .where((item) => item.id == message.hallId)
        .cast<ChatHall?>()
        .firstWhere((_) => true, orElse: () => null);
    return hall?.title ?? '大厅';
  }

  Future<void> _syncFirewallRulesIfNeeded() async {
    if (!supported) {
      return;
    }
    final cidrs = _localNodes.values
        .map((node) => node.networkCidr)
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    final nextKey = '${_localNodes.isNotEmpty}|${cidrs.join(",")}';
    if (nextKey == _lastFirewallStateKey) {
      return;
    }
    _lastFirewallStateKey = nextKey;
    await _firewallService.syncRules(
      enabled: _localNodes.isNotEmpty,
      remoteCidrs: cidrs,
    );
  }

  ChatMessageContentType _contentTypeFromMimeType(
    String mimeType, {
    required String fallbackPath,
  }) {
    if (mimeType.startsWith('image/')) {
      return ChatMessageContentType.image;
    }
    if (mimeType.startsWith('video/')) {
      return ChatMessageContentType.video;
    }
    final extension = path.extension(fallbackPath).toLowerCase();
    if (extension == '.m4a' ||
        extension == '.aac' ||
        extension == '.wav' ||
        extension == '.mp3' ||
        extension == '.flac') {
      return ChatMessageContentType.voice;
    }
    return ChatMessageContentType.file;
  }
}

class _LocalHallNode {
  const _LocalHallNode({
    required this.hall,
    required this.displayName,
    required this.joinedRooms,
    required this.networkCidr,
    required this.legacyHallIds,
  });

  final ChatHall hall;
  final String displayName;
  final List<ChatRoomDescriptor> joinedRooms;
  final String? networkCidr;
  final List<String> legacyHallIds;
}

class _PeerSeed {
  const _PeerSeed({
    required this.key,
    required this.hallId,
    required this.hallTitle,
    required this.virtualIp,
    required this.displayName,
    required this.isOnline,
  });

  final String key;
  final String hallId;
  final String hallTitle;
  final String virtualIp;
  final String displayName;
  final bool isOnline;
}

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
import 'package:vnt_app/chat/chat_storage.dart';
import 'package:vnt_app/chat/chat_transport_service.dart';
import 'package:vnt_app/remote_assist/remote_assist_utils.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

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

  bool get supported => Platform.isWindows;
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
  List<ChatMessageRecord> get selectedMessages =>
      List<ChatMessageRecord>.unmodifiable(
        _messageCache[_selectedConversationId] ?? const [],
      );

  List<ChatConversation> get directConversations =>
      List<ChatConversation>.unmodifiable(
        _conversations
            .where((item) => item.type == ChatConversationType.direct),
      );

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

    await _transportService.start(onPacket: _handleTransportPacket);
    await ChatLog.write('聊天室管理器已启动');
    await refresh();
    _refreshTimer = Timer.periodic(
      ChatConstants.refreshInterval,
      (_) => unawaited(refresh()),
    );
  }

  Future<void> stop() async {
    _started = false;
    _stopping = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await _presenceService.stop();
    await _transportService.stop();
    await ChatLog.write('聊天室管理器已停止');
    _stopping = false;
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
    try {
      final currentRooms = await _storage.loadRoomDescriptors();
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

      for (final entry in vntManager.map.entries) {
        final box = entry.value;
        if (box.isClosed()) {
          continue;
        }
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
          continue;
        }

        final hallId = buildHallId(
          connectServer: connectServer.isEmpty ? 'unknown' : connectServer,
          virtualNetwork: virtualNetwork,
        );
        final hallTitle = networkConfig?.configName.trim().isNotEmpty == true
            ? networkConfig!.configName.trim()
            : (connectServer.isEmpty ? virtualNetwork : connectServer);
        final displayName = networkConfig?.deviceName.trim().isNotEmpty == true
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
      }

      _halls = nextHalls;
      _localNodes = nextLocalNodes;
      _basePeers = nextBasePeers;

      await _ensureHallConversations();
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

      await _reconcilePresenceAndRooms();
      await reloadFromStorage(notify: false);
      _mergeOnlinePeers();
      await _syncKnownPeers();
      await _syncFirewallRulesIfNeeded();

      if (_selectedHallId == null && _halls.isNotEmpty) {
        _selectedHallId = _halls.first.id;
      }
      if (_selectedConversationId == null && _selectedHallId != null) {
        _selectedConversationId = _selectedHallId;
        await loadConversationMessages(_selectedConversationId!);
      }
    } finally {
      _refreshing = false;
      notifyListeners();
    }
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
        await _transportService.sendPacket(
          targetIp: recipient,
          packet: outboundPacket,
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
        await _transportService.sendPacket(
          targetIp: recipient,
          packet: outboundPacket,
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
      await _handleIncomingMessage(
        packet.message!,
        attachmentBase64: packet.attachmentBase64,
      );
      return;
    }
    if (packet.type == 'sync_request' && packet.syncRequest != null) {
      await _handleSyncRequest(packet.syncRequest!, remoteAddress.address);
    }
  }

  Future<void> _handleIncomingMessage(
    ChatMessageRecord remoteMessage, {
    String? attachmentBase64,
  }) async {
    if (_localNodes[remoteMessage.hallId] == null) {
      await ChatLog.write(
        '丢弃聊天消息 conversation=${remoteMessage.conversationId} hall=${remoteMessage.hallId} reason=local_hall_offline',
      );
      return;
    }

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
    await ChatLog.write(
      '收到聊天补同步请求 hall=${payload.hallId} requester=${payload.requesterVirtualIp} remote=$remoteIp joinedRooms=${payload.joinedRoomIds.length}',
    );
    final localNode = _localNodes[payload.hallId];
    if (localNode == null) {
      return;
    }
    final conversationIds = <String>{
      payload.hallId,
      buildDirectConversationId(
        hallId: payload.hallId,
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
        await _transportService.sendPacket(
          targetIp: remoteIp,
          packet: ChatTransportPacket(
            type: 'message',
            message: syncMessage.copyWith(
              status: ChatMessageStatus.sent,
            ),
            attachmentBase64: attachmentBase64,
          ),
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
        await _transportService.sendPacket(
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
    _presenceCache = snapshot;
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
  });

  final ChatHall hall;
  final String displayName;
  final List<ChatRoomDescriptor> joinedRooms;
  final String? networkCidr;
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

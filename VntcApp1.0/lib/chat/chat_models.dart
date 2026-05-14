import 'dart:convert';

enum ChatConversationType { direct, channel }

enum ChatFriendStatus { stranger, pending, friend, blocked }

enum ChatMessageKind { text, image, file, voiceNote, system }

enum ChatMessageDirection { incoming, outgoing }

enum ChatMessageStatus {
  pending,
  sent,
  delivered,
  failed,
  awaitingAccept,
  accepted,
  rejected,
  transferred,
  expired,
}

enum ChatEnvelopeType {
  hello,
  profileSync,
  friendRequest,
  friendAccept,
  friendReject,
  friendRemove,
  friendBlock,
  dmMessage,
  channelCreate,
  channelAnnounce,
  channelInvite,
  channelJoin,
  channelLeave,
  channelArchive,
  attachmentOffer,
  attachmentAccept,
  attachmentReject,
  voiceNoteOffer,
  callInvite,
  callAccept,
  callReject,
  callHangup,
  remoteAssistInvite,
  remoteAssistAccept,
  remoteAssistReject,
  remoteAssistCancel,
  remoteAssistReady,
  remoteAssistEnd,
  pttRequest,
  pttGrant,
  pttRelease,
  presence,
  ack,
}

enum ChatCallType { direct, channel }

enum ChatCallState { idle, dialing, ringing, active, ended }

enum RemoteAssistMode { requestControl, inviteControl }

enum RemoteAssistState {
  pending,
  accepted,
  ready,
  active,
  rejected,
  ended,
  failed,
}

class ChatIds {
  static String peerId(String networkKey, String virtualIp) {
    return '$networkKey:$virtualIp';
  }

  static String directConversationId(
    String networkKey,
    String localPeerId,
    String remotePeerId,
  ) {
    final pair = [localPeerId, remotePeerId]..sort();
    return 'dm:$networkKey:${pair.join('|')}';
  }

  static String channelConversationId(String networkKey, String channelId) {
    return 'channel:$networkKey:$channelId';
  }

  static String lobbyChannelId(String networkKey) {
    return 'lobby:$networkKey';
  }
}

class ChatPeer {
  final String peerId;
  final String networkKey;
  final String virtualIp;
  final String deviceName;
  final String remark;
  final bool isOnline;
  final DateTime lastSeenAt;
  final List<String> capabilities;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ChatPeer({
    required this.peerId,
    required this.networkKey,
    required this.virtualIp,
    required this.deviceName,
    this.remark = '',
    required this.isOnline,
    required this.lastSeenAt,
    this.capabilities = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  String get displayName =>
      remark.trim().isNotEmpty ? remark.trim() : deviceName;

  ChatPeer copyWith({
    String? deviceName,
    String? remark,
    bool? isOnline,
    DateTime? lastSeenAt,
    List<String>? capabilities,
    DateTime? updatedAt,
  }) {
    return ChatPeer(
      peerId: peerId,
      networkKey: networkKey,
      virtualIp: virtualIp,
      deviceName: deviceName ?? this.deviceName,
      remark: remark ?? this.remark,
      isOnline: isOnline ?? this.isOnline,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      capabilities: capabilities ?? this.capabilities,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'peer_id': peerId,
      'network_key': networkKey,
      'virtual_ip': virtualIp,
      'device_name': deviceName,
      'remark': remark,
      'is_online': isOnline ? 1 : 0,
      'last_seen_at': lastSeenAt.millisecondsSinceEpoch,
      'capabilities_json': jsonEncode(capabilities),
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ChatPeer.fromMap(Map<String, Object?> map) {
    return ChatPeer(
      peerId: map['peer_id'] as String,
      networkKey: map['network_key'] as String,
      virtualIp: map['virtual_ip'] as String,
      deviceName: (map['device_name'] as String?) ?? '',
      remark: (map['remark'] as String?) ?? '',
      isOnline: ((map['is_online'] as int?) ?? 0) == 1,
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
        (map['last_seen_at'] as int?) ?? 0,
      ),
      capabilities: ((jsonDecode((map['capabilities_json'] as String?) ?? '[]')
              as List<dynamic>))
          .cast<String>(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatFriend {
  final String peerId;
  final ChatFriendStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ChatFriend({
    required this.peerId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() {
    return {
      'peer_id': peerId,
      'status': status.name,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ChatFriend.fromMap(Map<String, Object?> map) {
    return ChatFriend(
      peerId: map['peer_id'] as String,
      status: ChatFriendStatus.values.byName(
        (map['status'] as String?) ?? ChatFriendStatus.stranger.name,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatChannel {
  final String channelId;
  final String networkKey;
  final String name;
  final String ownerPeerId;
  final bool isPrivate;
  final bool joined;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ChatChannel({
    required this.channelId,
    required this.networkKey,
    required this.name,
    required this.ownerPeerId,
    required this.isPrivate,
    required this.joined,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
  });

  ChatChannel copyWith({
    String? name,
    bool? joined,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return ChatChannel(
      channelId: channelId,
      networkKey: networkKey,
      name: name ?? this.name,
      ownerPeerId: ownerPeerId,
      isPrivate: isPrivate,
      joined: joined ?? this.joined,
      archived: archived ?? this.archived,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'channel_id': channelId,
      'network_key': networkKey,
      'name': name,
      'owner_peer_id': ownerPeerId,
      'is_private': isPrivate ? 1 : 0,
      'joined': joined ? 1 : 0,
      'archived': archived ? 1 : 0,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ChatChannel.fromMap(Map<String, Object?> map) {
    return ChatChannel(
      channelId: map['channel_id'] as String,
      networkKey: map['network_key'] as String,
      name: map['name'] as String,
      ownerPeerId: map['owner_peer_id'] as String,
      isPrivate: ((map['is_private'] as int?) ?? 0) == 1,
      joined: ((map['joined'] as int?) ?? 0) == 1,
      archived: ((map['archived'] as int?) ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatChannelMember {
  final String channelId;
  final String peerId;
  final String role;
  final DateTime joinedAt;
  final DateTime updatedAt;

  const ChatChannelMember({
    required this.channelId,
    required this.peerId,
    required this.role,
    required this.joinedAt,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() {
    return {
      'channel_id': channelId,
      'peer_id': peerId,
      'role': role,
      'joined_at': joinedAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ChatChannelMember.fromMap(Map<String, Object?> map) {
    return ChatChannelMember(
      channelId: map['channel_id'] as String,
      peerId: map['peer_id'] as String,
      role: (map['role'] as String?) ?? 'member',
      joinedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['joined_at'] as int?) ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatConversationSummary {
  final String conversationId;
  final String networkKey;
  final ChatConversationType type;
  final String title;
  final String? peerId;
  final String? channelId;
  final int unreadCount;
  final String lastPreview;
  final DateTime? lastMessageAt;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ChatConversationSummary({
    required this.conversationId,
    required this.networkKey,
    required this.type,
    required this.title,
    this.peerId,
    this.channelId,
    required this.unreadCount,
    required this.lastPreview,
    this.lastMessageAt,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
  });

  ChatConversationSummary copyWith({
    String? title,
    int? unreadCount,
    String? lastPreview,
    DateTime? lastMessageAt,
    bool? archived,
    DateTime? updatedAt,
  }) {
    return ChatConversationSummary(
      conversationId: conversationId,
      networkKey: networkKey,
      type: type,
      title: title ?? this.title,
      peerId: peerId,
      channelId: channelId,
      unreadCount: unreadCount ?? this.unreadCount,
      lastPreview: lastPreview ?? this.lastPreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      archived: archived ?? this.archived,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'conversation_id': conversationId,
      'network_key': networkKey,
      'type': type.name,
      'title': title,
      'peer_id': peerId,
      'channel_id': channelId,
      'unread_count': unreadCount,
      'last_preview': lastPreview,
      'last_message_at': lastMessageAt?.millisecondsSinceEpoch,
      'archived': archived ? 1 : 0,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ChatConversationSummary.fromMap(Map<String, Object?> map) {
    return ChatConversationSummary(
      conversationId: map['conversation_id'] as String,
      networkKey: map['network_key'] as String,
      type: ChatConversationType.values.byName(map['type'] as String),
      title: (map['title'] as String?) ?? '',
      peerId: map['peer_id'] as String?,
      channelId: map['channel_id'] as String?,
      unreadCount: (map['unread_count'] as int?) ?? 0,
      lastPreview: (map['last_preview'] as String?) ?? '',
      lastMessageAt: map['last_message_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['last_message_at'] as int),
      archived: ((map['archived'] as int?) ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updated_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatAttachment {
  final String attachmentId;
  final String messageId;
  final String direction;
  final String type;
  final String fileName;
  final String mimeType;
  final int size;
  final String sha256;
  final String localPath;
  final String remotePath;
  final ChatMessageStatus offerStatus;
  final ChatMessageStatus transferStatus;
  final DateTime createdAt;
  final DateTime? expiresAt;

  const ChatAttachment({
    required this.attachmentId,
    required this.messageId,
    required this.direction,
    required this.type,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.sha256,
    required this.localPath,
    this.remotePath = '',
    required this.offerStatus,
    required this.transferStatus,
    required this.createdAt,
    this.expiresAt,
  });

  ChatAttachment copyWith({
    String? localPath,
    String? remotePath,
    ChatMessageStatus? offerStatus,
    ChatMessageStatus? transferStatus,
    DateTime? expiresAt,
  }) {
    return ChatAttachment(
      attachmentId: attachmentId,
      messageId: messageId,
      direction: direction,
      type: type,
      fileName: fileName,
      mimeType: mimeType,
      size: size,
      sha256: sha256,
      localPath: localPath ?? this.localPath,
      remotePath: remotePath ?? this.remotePath,
      offerStatus: offerStatus ?? this.offerStatus,
      transferStatus: transferStatus ?? this.transferStatus,
      createdAt: createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'attachment_id': attachmentId,
      'message_id': messageId,
      'direction': direction,
      'type': type,
      'file_name': fileName,
      'mime_type': mimeType,
      'size': size,
      'sha256': sha256,
      'local_path': localPath,
      'remote_path': remotePath,
      'offer_status': offerStatus.name,
      'transfer_status': transferStatus.name,
      'created_at': createdAt.millisecondsSinceEpoch,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
    };
  }

  factory ChatAttachment.fromMap(Map<String, Object?> map) {
    return ChatAttachment(
      attachmentId: map['attachment_id'] as String,
      messageId: map['message_id'] as String,
      direction: (map['direction'] as String?) ?? 'incoming',
      type: (map['type'] as String?) ?? 'file',
      fileName: (map['file_name'] as String?) ?? '',
      mimeType: (map['mime_type'] as String?) ?? 'application/octet-stream',
      size: (map['size'] as int?) ?? 0,
      sha256: (map['sha256'] as String?) ?? '',
      localPath: (map['local_path'] as String?) ?? '',
      remotePath: (map['remote_path'] as String?) ?? '',
      offerStatus: ChatMessageStatus.values.byName(
        (map['offer_status'] as String?) ?? ChatMessageStatus.pending.name,
      ),
      transferStatus: ChatMessageStatus.values.byName(
        (map['transfer_status'] as String?) ?? ChatMessageStatus.pending.name,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
      expiresAt: map['expires_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['expires_at'] as int),
    );
  }
}

class ChatMessage {
  final String messageId;
  final String conversationId;
  final String networkKey;
  final String senderPeerId;
  final ChatMessageKind kind;
  final ChatMessageDirection direction;
  final ChatMessageStatus status;
  final String text;
  final String? attachmentId;
  final String? peerId;
  final String? channelId;
  final Map<String, dynamic> metadata;
  final DateTime sentAt;
  final DateTime receivedAt;
  final DateTime createdAt;

  const ChatMessage({
    required this.messageId,
    required this.conversationId,
    required this.networkKey,
    required this.senderPeerId,
    required this.kind,
    required this.direction,
    required this.status,
    required this.text,
    this.attachmentId,
    this.peerId,
    this.channelId,
    this.metadata = const {},
    required this.sentAt,
    required this.receivedAt,
    required this.createdAt,
  });

  ChatMessage copyWith({
    ChatMessageStatus? status,
    String? text,
    String? attachmentId,
    Map<String, dynamic>? metadata,
    DateTime? receivedAt,
  }) {
    return ChatMessage(
      messageId: messageId,
      conversationId: conversationId,
      networkKey: networkKey,
      senderPeerId: senderPeerId,
      kind: kind,
      direction: direction,
      status: status ?? this.status,
      text: text ?? this.text,
      attachmentId: attachmentId ?? this.attachmentId,
      peerId: peerId,
      channelId: channelId,
      metadata: metadata ?? this.metadata,
      sentAt: sentAt,
      receivedAt: receivedAt ?? this.receivedAt,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'message_id': messageId,
      'conversation_id': conversationId,
      'network_key': networkKey,
      'sender_peer_id': senderPeerId,
      'kind': kind.name,
      'direction': direction.name,
      'status': status.name,
      'text': text,
      'attachment_id': attachmentId,
      'peer_id': peerId,
      'channel_id': channelId,
      'metadata_json': jsonEncode(metadata),
      'sent_at': sentAt.millisecondsSinceEpoch,
      'received_at': receivedAt.millisecondsSinceEpoch,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    return ChatMessage(
      messageId: map['message_id'] as String,
      conversationId: map['conversation_id'] as String,
      networkKey: map['network_key'] as String,
      senderPeerId: map['sender_peer_id'] as String,
      kind: ChatMessageKind.values.byName(map['kind'] as String),
      direction: ChatMessageDirection.values.byName(map['direction'] as String),
      status: ChatMessageStatus.values.byName(map['status'] as String),
      text: (map['text'] as String?) ?? '',
      attachmentId: map['attachment_id'] as String?,
      peerId: map['peer_id'] as String?,
      channelId: map['channel_id'] as String?,
      metadata: Map<String, dynamic>.from(
        jsonDecode((map['metadata_json'] as String?) ?? '{}') as Map,
      ),
      sentAt: DateTime.fromMillisecondsSinceEpoch(
        (map['sent_at'] as int?) ?? 0,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['received_at'] as int?) ?? 0,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['created_at'] as int?) ?? 0,
      ),
    );
  }
}

class ChatCallLog {
  final String callId;
  final String conversationId;
  final String networkKey;
  final ChatCallType type;
  final String? peerId;
  final String? channelId;
  final ChatCallState state;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Map<String, dynamic> metadata;

  const ChatCallLog({
    required this.callId,
    required this.conversationId,
    required this.networkKey,
    required this.type,
    this.peerId,
    this.channelId,
    required this.state,
    required this.startedAt,
    this.endedAt,
    this.metadata = const {},
  });

  Map<String, Object?> toMap() {
    return {
      'call_id': callId,
      'conversation_id': conversationId,
      'network_key': networkKey,
      'type': type.name,
      'peer_id': peerId,
      'channel_id': channelId,
      'state': state.name,
      'started_at': startedAt.millisecondsSinceEpoch,
      'ended_at': endedAt?.millisecondsSinceEpoch,
      'metadata_json': jsonEncode(metadata),
    };
  }
}

class ChatEnvelope {
  final String messageId;
  final ChatEnvelopeType type;
  final String fromVirtualIp;
  final String fromDeviceName;
  final String? toVirtualIp;
  final String? conversationId;
  final String? channelId;
  final int sentAt;
  final Map<String, dynamic> payload;

  const ChatEnvelope({
    required this.messageId,
    required this.type,
    required this.fromVirtualIp,
    required this.fromDeviceName,
    this.toVirtualIp,
    this.conversationId,
    this.channelId,
    required this.sentAt,
    this.payload = const {},
  });

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'type': type.name,
      'fromVirtualIp': fromVirtualIp,
      'fromDeviceName': fromDeviceName,
      'toVirtualIp': toVirtualIp,
      'conversationId': conversationId,
      'channelId': channelId,
      'sentAt': sentAt,
      'payload': payload,
    };
  }

  factory ChatEnvelope.fromJson(Map<String, dynamic> json) {
    return ChatEnvelope(
      messageId: json['messageId'] as String,
      type: ChatEnvelopeType.values.byName(json['type'] as String),
      fromVirtualIp: json['fromVirtualIp'] as String,
      fromDeviceName: (json['fromDeviceName'] as String?) ?? '',
      toVirtualIp: json['toVirtualIp'] as String?,
      conversationId: json['conversationId'] as String?,
      channelId: json['channelId'] as String?,
      sentAt: (json['sentAt'] as num?)?.toInt() ?? 0,
      payload: Map<String, dynamic>.from(
        (json['payload'] as Map?) ?? const {},
      ),
    );
  }
}

class ChatCallSession {
  final String callId;
  final String networkKey;
  final ChatCallType type;
  final ChatCallState state;
  final String? peerId;
  final String? channelId;
  final bool isIncoming;
  final bool joinedVoice;
  final String? speakerPeerId;
  final List<String> participants;
  final DateTime startedAt;

  const ChatCallSession({
    required this.callId,
    required this.networkKey,
    required this.type,
    required this.state,
    this.peerId,
    this.channelId,
    required this.isIncoming,
    required this.joinedVoice,
    this.speakerPeerId,
    this.participants = const [],
    required this.startedAt,
  });

  ChatCallSession copyWith({
    ChatCallState? state,
    bool? joinedVoice,
    String? speakerPeerId,
    List<String>? participants,
  }) {
    return ChatCallSession(
      callId: callId,
      networkKey: networkKey,
      type: type,
      state: state ?? this.state,
      peerId: peerId,
      channelId: channelId,
      isIncoming: isIncoming,
      joinedVoice: joinedVoice ?? this.joinedVoice,
      speakerPeerId: speakerPeerId ?? this.speakerPeerId,
      participants: participants ?? this.participants,
      startedAt: startedAt,
    );
  }
}

class RemoteAssistSession {
  final String sessionId;
  final String networkKey;
  final String peerId;
  final String peerVirtualIp;
  final String controllerPeerId;
  final String controlledPeerId;
  final String controllerVirtualIp;
  final String controlledVirtualIp;
  final RemoteAssistMode mode;
  final int listenPort;
  final String sessionToken;
  final RemoteAssistState state;
  final bool isIncoming;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RemoteAssistSession({
    required this.sessionId,
    required this.networkKey,
    required this.peerId,
    required this.peerVirtualIp,
    required this.controllerPeerId,
    required this.controlledPeerId,
    required this.controllerVirtualIp,
    required this.controlledVirtualIp,
    required this.mode,
    required this.listenPort,
    required this.sessionToken,
    required this.state,
    required this.isIncoming,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isControllerLocal => isIncoming
      ? mode == RemoteAssistMode.inviteControl
      : mode == RemoteAssistMode.requestControl;

  bool get isControlledLocal => !isControllerLocal;

  RemoteAssistSession copyWith({
    RemoteAssistState? state,
    DateTime? updatedAt,
  }) {
    return RemoteAssistSession(
      sessionId: sessionId,
      networkKey: networkKey,
      peerId: peerId,
      peerVirtualIp: peerVirtualIp,
      controllerPeerId: controllerPeerId,
      controlledPeerId: controlledPeerId,
      controllerVirtualIp: controllerVirtualIp,
      controlledVirtualIp: controlledVirtualIp,
      mode: mode,
      listenPort: listenPort,
      sessionToken: sessionToken,
      state: state ?? this.state,
      isIncoming: isIncoming,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

import 'dart:convert';

enum ChatConversationType { hall, direct, room }

enum ChatMessageDirection { incoming, outgoing }

enum ChatMessageContentType { text, image, video, file, voice }

enum ChatMessageStatus { sending, sent, failed, missingAttachment }

enum ChatAttachmentTransferPhase { preparing, uploading }

enum ChatMainTab { hall, rooms, online, direct }

class ChatAttachmentTransferSample {
  const ChatAttachmentTransferSample({
    required this.totalBytes,
    required this.transferredBytes,
    required this.bytesPerSecond,
  });

  final int totalBytes;
  final int transferredBytes;
  final int bytesPerSecond;
}

ChatAttachmentTransferSample calculateAttachmentTransferSample({
  required int fileBytes,
  required int recipientIndex,
  required int recipientCount,
  required int recipientSentBytes,
  required int elapsedMilliseconds,
}) {
  final safeFileBytes = fileBytes < 0 ? 0 : fileBytes;
  final safeRecipientCount = recipientCount < 1 ? 1 : recipientCount;
  final safeRecipientIndex = recipientIndex
      .clamp(0, safeRecipientCount - 1)
      .toInt();
  final safeRecipientSentBytes = recipientSentBytes
      .clamp(0, safeFileBytes)
      .toInt();
  final transferredBytes =
      safeFileBytes * safeRecipientIndex + safeRecipientSentBytes;
  return ChatAttachmentTransferSample(
    totalBytes: safeFileBytes * safeRecipientCount,
    transferredBytes: transferredBytes,
    bytesPerSecond: elapsedMilliseconds <= 0
        ? 0
        : transferredBytes * 1000 ~/ elapsedMilliseconds,
  );
}

bool shouldPublishAttachmentProgress({
  required int sentBytes,
  required int totalBytes,
  required int elapsedMilliseconds,
  required int lastPublishedElapsedMilliseconds,
  required Duration minimumInterval,
}) {
  return sentBytes >= totalBytes ||
      lastPublishedElapsedMilliseconds < 0 ||
      elapsedMilliseconds - lastPublishedElapsedMilliseconds >=
          minimumInterval.inMilliseconds;
}

class ChatAttachmentTransferProgress {
  const ChatAttachmentTransferProgress({
    required this.messageId,
    required this.totalBytes,
    required this.transferredBytes,
    required this.bytesPerSecond,
    required this.startedAtEpochMs,
    required this.phase,
  });

  final String messageId;
  final int totalBytes;
  final int transferredBytes;
  final int bytesPerSecond;
  final int startedAtEpochMs;
  final ChatAttachmentTransferPhase phase;

  int get progressPercent {
    if (totalBytes <= 0) {
      return 0;
    }
    return ((transferredBytes * 100) / totalBytes).clamp(0, 100).round();
  }

  double get progress => progressPercent / 100;

  bool get isActive =>
      phase == ChatAttachmentTransferPhase.preparing ||
      phase == ChatAttachmentTransferPhase.uploading;

  ChatAttachmentTransferProgress copyWith({
    int? transferredBytes,
    int? bytesPerSecond,
    ChatAttachmentTransferPhase? phase,
  }) {
    return ChatAttachmentTransferProgress(
      messageId: messageId,
      totalBytes: totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      startedAtEpochMs: startedAtEpochMs,
      phase: phase ?? this.phase,
    );
  }
}

class ChatSendResult {
  const ChatSendResult({
    required this.conversationId,
    required this.attemptedRecipients,
    required this.deliveredRecipients,
    required this.failedRecipients,
    required this.finalStatus,
  });

  final String conversationId;
  final int attemptedRecipients;
  final int deliveredRecipients;
  final int failedRecipients;
  final ChatMessageStatus finalStatus;

  bool get isSuccess =>
      attemptedRecipients > 0 &&
      deliveredRecipients == attemptedRecipients &&
      finalStatus == ChatMessageStatus.sent;

  bool get isPartialSuccess =>
      deliveredRecipients > 0 && deliveredRecipients < attemptedRecipients;

  bool get isFailure => finalStatus == ChatMessageStatus.failed;

  bool get hadNoRecipients => attemptedRecipients == 0;
}

String _enumName(Object value) => value.toString().split('.').last;

String chatEnumName(Object value) => _enumName(value);

String buildHallId({
  required String connectServer,
  required String virtualNetwork,
  String virtualNetmask = '',
}) {
  return 'hall:${normalizeChatConnectServer(connectServer)}|${normalizeChatVirtualNetwork(virtualNetwork, virtualNetmask)}';
}

String normalizeChatVirtualNetwork(String value, [String netmask = '']) {
  final address = value.trim().split('/').first;
  final addressParts = address.split('.').map(int.tryParse).toList();
  final maskParts = netmask.trim().split('.').map(int.tryParse).toList();
  final validAddress = addressParts.length == 4 &&
      addressParts.every((part) => part != null && part >= 0 && part <= 255);
  final validMask = maskParts.length == 4 &&
      maskParts.every((part) => part != null && part >= 0 && part <= 255);
  if (!validAddress || !validMask) {
    return value.trim().toLowerCase();
  }
  return List<String>.generate(
    4,
    (index) => (addressParts[index]! & maskParts[index]!).toString(),
  ).join('.');
}

String buildLegacyChatHallId({
  required String connectServer,
  required String virtualNetwork,
}) {
  final server =
      connectServer.trim().isEmpty ? 'unknown' : connectServer.trim();
  return 'hall:$server|${virtualNetwork.trim()}';
}

List<String> buildLegacyChatHallIdCandidates({
  required String connectServer,
  required String virtualNetwork,
}) {
  final trimmed = connectServer.trim();
  final body = _chatConnectServerBody(connectServer);
  final servers = <String>{};
  if (trimmed.isNotEmpty) {
    servers.add(trimmed);
  }
  if (body.isNotEmpty) {
    servers
      ..add(body)
      ..add('quic://$body')
      ..add('udp://$body')
      ..add('tcp://$body')
      ..add('wss://$body')
      ..add('ws://$body')
      ..add('dynamic://$body')
      ..add('txt:$body');
  }
  if (servers.isEmpty) {
    servers.add('unknown');
  }
  return servers
      .map(
        (server) => buildLegacyChatHallId(
          connectServer: server,
          virtualNetwork: virtualNetwork,
        ),
      )
      .toList(growable: false);
}

String _chatConnectServerBody(String connectServer) {
  var normalized = connectServer.trim();
  if (normalized.isEmpty) {
    return '';
  }
  final lower = normalized.toLowerCase();
  if (lower.startsWith('txt:')) {
    normalized = normalized.substring('txt:'.length);
  } else {
    final schemeIndex = normalized.indexOf('://');
    if (schemeIndex > 0) {
      normalized = normalized.substring(schemeIndex + 3);
    }
  }
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.trim();
}

String normalizeChatConnectServer(String connectServer) {
  final normalized = _chatConnectServerBody(connectServer);
  if (normalized.isEmpty) {
    return 'unknown';
  }
  return normalized.toLowerCase();
}

String normalizeChatHallId(String hallId) {
  final trimmed = hallId.trim();
  if (!trimmed.startsWith('hall:')) {
    return trimmed;
  }
  final body = trimmed.substring('hall:'.length);
  final separatorIndex = body.lastIndexOf('|');
  if (separatorIndex <= 0 || separatorIndex == body.length - 1) {
    return trimmed;
  }
  return buildHallId(
    connectServer: body.substring(0, separatorIndex),
    virtualNetwork: body.substring(separatorIndex + 1),
  );
}

String normalizeChatVirtualIp(String virtualIp) {
  var normalized = virtualIp.trim().toLowerCase();
  if (normalized.length > 2 &&
      normalized.startsWith('[') &&
      normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  return normalized;
}

String buildDirectConversationId({
  required String hallId,
  required String firstVirtualIp,
  required String secondVirtualIp,
}) {
  final ips = [
    normalizeChatVirtualIp(firstVirtualIp),
    normalizeChatVirtualIp(secondVirtualIp),
  ]..sort();
  return 'dm:${normalizeChatHallId(hallId)}:${ips[0]}|${ips[1]}';
}

String buildLegacyDirectConversationId({
  required String hallId,
  required String firstVirtualIp,
  required String secondVirtualIp,
}) {
  final ips = [firstVirtualIp, secondVirtualIp]..sort();
  return 'dm:$hallId:${ips[0]}|${ips[1]}';
}

String buildRoomId({
  required String hallId,
  required String creatorVirtualIp,
  required String roomToken,
}) {
  return 'room:${normalizeChatHallId(hallId)}:$creatorVirtualIp:$roomToken';
}

String buildLegacyRoomId({
  required String hallId,
  required String creatorVirtualIp,
  required String roomToken,
}) {
  return 'room:$hallId:$creatorVirtualIp:$roomToken';
}

String buildPresencePeerKey({
  required String hallId,
  required String virtualIp,
}) {
  return '${normalizeChatHallId(hallId)}|$virtualIp';
}

T _parseEnum<T>(List<T> values, String raw, T fallback) {
  for (final value in values) {
    if (_enumName(value as Object) == raw) {
      return value;
    }
  }
  return fallback;
}

class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.type,
    required this.hallId,
    required this.title,
    required this.unreadCount,
    required this.lastReadAtEpochMs,
    required this.lastMessageAtEpochMs,
    required this.updatedAtEpochMs,
    required this.metadataJson,
    this.peerVirtualIp,
    this.peerDisplayName,
    this.roomId,
  });

  final String id;
  final ChatConversationType type;
  final String hallId;
  final String title;
  final String? peerVirtualIp;
  final String? peerDisplayName;
  final String? roomId;
  final int unreadCount;
  final int lastReadAtEpochMs;
  final int lastMessageAtEpochMs;
  final int updatedAtEpochMs;
  final String metadataJson;

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'type': _enumName(type),
      'hall_id': hallId,
      'title': title,
      'peer_virtual_ip': peerVirtualIp,
      'peer_display_name': peerDisplayName,
      'room_id': roomId,
      'unread_count': unreadCount,
      'last_read_at': lastReadAtEpochMs,
      'last_message_at': lastMessageAtEpochMs,
      'updated_at': updatedAtEpochMs,
      'metadata_json': metadataJson,
    };
  }

  factory ChatConversation.fromDbMap(Map<String, Object?> map) {
    return ChatConversation(
      id: (map['id'] ?? '').toString(),
      type: _parseEnum(
        ChatConversationType.values,
        (map['type'] ?? '').toString(),
        ChatConversationType.hall,
      ),
      hallId: (map['hall_id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      peerVirtualIp: map['peer_virtual_ip']?.toString(),
      peerDisplayName: map['peer_display_name']?.toString(),
      roomId: map['room_id']?.toString(),
      unreadCount: int.tryParse('${map['unread_count']}') ?? 0,
      lastReadAtEpochMs: int.tryParse('${map['last_read_at']}') ?? 0,
      lastMessageAtEpochMs: int.tryParse('${map['last_message_at']}') ?? 0,
      updatedAtEpochMs: int.tryParse('${map['updated_at']}') ?? 0,
      metadataJson: (map['metadata_json'] ?? '{}').toString(),
    );
  }

  ChatConversation copyWith({
    String? title,
    String? peerVirtualIp,
    String? peerDisplayName,
    String? roomId,
    int? unreadCount,
    int? lastReadAtEpochMs,
    int? lastMessageAtEpochMs,
    int? updatedAtEpochMs,
    String? metadataJson,
  }) {
    return ChatConversation(
      id: id,
      type: type,
      hallId: hallId,
      title: title ?? this.title,
      peerVirtualIp: peerVirtualIp ?? this.peerVirtualIp,
      peerDisplayName: peerDisplayName ?? this.peerDisplayName,
      roomId: roomId ?? this.roomId,
      unreadCount: unreadCount ?? this.unreadCount,
      lastReadAtEpochMs: lastReadAtEpochMs ?? this.lastReadAtEpochMs,
      lastMessageAtEpochMs: lastMessageAtEpochMs ?? this.lastMessageAtEpochMs,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
      metadataJson: metadataJson ?? this.metadataJson,
    );
  }
}

class ChatAttachmentRecord {
  const ChatAttachmentRecord({
    required this.id,
    required this.messageId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.relativePath,
    required this.autoSyncEligible,
    required this.payloadAvailable,
    required this.needsManualResend,
    required this.createdAtEpochMs,
    this.durationMs,
    this.metadataJson = '{}',
  });

  final String id;
  final String messageId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String relativePath;
  final int? durationMs;
  final bool autoSyncEligible;
  final bool payloadAvailable;
  final bool needsManualResend;
  final int createdAtEpochMs;
  final String metadataJson;

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'message_id': messageId,
      'file_name': fileName,
      'mime_type': mimeType,
      'size_bytes': sizeBytes,
      'relative_path': relativePath,
      'duration_ms': durationMs,
      'auto_sync_eligible': autoSyncEligible ? 1 : 0,
      'payload_available': payloadAvailable ? 1 : 0,
      'needs_manual_resend': needsManualResend ? 1 : 0,
      'created_at': createdAtEpochMs,
      'metadata_json': metadataJson,
    };
  }

  factory ChatAttachmentRecord.fromDbMap(Map<String, Object?> map) {
    return ChatAttachmentRecord(
      id: (map['id'] ?? '').toString(),
      messageId: (map['message_id'] ?? '').toString(),
      fileName: (map['file_name'] ?? '').toString(),
      mimeType: (map['mime_type'] ?? '').toString(),
      sizeBytes: int.tryParse('${map['size_bytes']}') ?? 0,
      relativePath: (map['relative_path'] ?? '').toString(),
      durationMs: map['duration_ms'] == null
          ? null
          : int.tryParse('${map['duration_ms']}'),
      autoSyncEligible:
          (int.tryParse('${map['auto_sync_eligible']}') ?? 0) == 1,
      payloadAvailable: (int.tryParse('${map['payload_available']}') ?? 0) == 1,
      needsManualResend:
          (int.tryParse('${map['needs_manual_resend']}') ?? 0) == 1,
      createdAtEpochMs: int.tryParse('${map['created_at']}') ?? 0,
      metadataJson: (map['metadata_json'] ?? '{}').toString(),
    );
  }

  Map<String, dynamic> toTransportJson() {
    return {
      'id': id,
      'messageId': messageId,
      'fileName': fileName,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'relativePath': relativePath,
      'durationMs': durationMs,
      'autoSyncEligible': autoSyncEligible,
      'payloadAvailable': payloadAvailable,
      'needsManualResend': needsManualResend,
      'createdAtEpochMs': createdAtEpochMs,
      'metadataJson': metadataJson,
    };
  }

  factory ChatAttachmentRecord.fromTransportJson(Map<String, dynamic> map) {
    return ChatAttachmentRecord(
      id: (map['id'] ?? '').toString(),
      messageId: (map['messageId'] ?? '').toString(),
      fileName: (map['fileName'] ?? '').toString(),
      mimeType: (map['mimeType'] ?? '').toString(),
      sizeBytes: int.tryParse('${map['sizeBytes']}') ?? 0,
      relativePath: (map['relativePath'] ?? '').toString(),
      durationMs: map['durationMs'] == null
          ? null
          : int.tryParse('${map['durationMs']}'),
      autoSyncEligible: map['autoSyncEligible'] == true,
      payloadAvailable: map['payloadAvailable'] == true,
      needsManualResend: map['needsManualResend'] == true,
      createdAtEpochMs: int.tryParse('${map['createdAtEpochMs']}') ?? 0,
      metadataJson: (map['metadataJson'] ?? '{}').toString(),
    );
  }

  ChatAttachmentRecord copyWith({
    String? fileName,
    String? mimeType,
    int? sizeBytes,
    String? relativePath,
    int? durationMs,
    bool? autoSyncEligible,
    bool? payloadAvailable,
    bool? needsManualResend,
    int? createdAtEpochMs,
    String? metadataJson,
  }) {
    return ChatAttachmentRecord(
      id: id,
      messageId: messageId,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      relativePath: relativePath ?? this.relativePath,
      durationMs: durationMs ?? this.durationMs,
      autoSyncEligible: autoSyncEligible ?? this.autoSyncEligible,
      payloadAvailable: payloadAvailable ?? this.payloadAvailable,
      needsManualResend: needsManualResend ?? this.needsManualResend,
      createdAtEpochMs: createdAtEpochMs ?? this.createdAtEpochMs,
      metadataJson: metadataJson ?? this.metadataJson,
    );
  }
}

class ChatMessageRecord {
  const ChatMessageRecord({
    required this.id,
    required this.conversationId,
    required this.hallId,
    required this.conversationType,
    required this.senderVirtualIp,
    required this.senderName,
    required this.senderSeq,
    required this.direction,
    required this.contentType,
    required this.status,
    required this.text,
    required this.isSyncMessage,
    required this.isRead,
    required this.sentAtEpochMs,
    required this.createdAtEpochMs,
    required this.metadataJson,
    this.peerVirtualIp,
    this.roomId,
    this.attachmentId,
    this.attachment,
  });

  final String id;
  final String conversationId;
  final String hallId;
  final ChatConversationType conversationType;
  final String senderVirtualIp;
  final String senderName;
  final int senderSeq;
  final ChatMessageDirection direction;
  final ChatMessageContentType contentType;
  final ChatMessageStatus status;
  final String text;
  final String? peerVirtualIp;
  final String? roomId;
  final String? attachmentId;
  final ChatAttachmentRecord? attachment;
  final bool isSyncMessage;
  final bool isRead;
  final int sentAtEpochMs;
  final int createdAtEpochMs;
  final String metadataJson;

  bool get hasAttachment => attachmentId != null && attachmentId!.isNotEmpty;

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'hall_id': hallId,
      'conversation_type': _enumName(conversationType),
      'sender_virtual_ip': senderVirtualIp,
      'sender_name': senderName,
      'sender_seq': senderSeq,
      'direction': _enumName(direction),
      'content_type': _enumName(contentType),
      'status': _enumName(status),
      'text': text,
      'peer_virtual_ip': peerVirtualIp,
      'room_id': roomId,
      'attachment_id': attachmentId,
      'is_sync_message': isSyncMessage ? 1 : 0,
      'is_read': isRead ? 1 : 0,
      'sent_at': sentAtEpochMs,
      'created_at': createdAtEpochMs,
      'metadata_json': metadataJson,
    };
  }

  factory ChatMessageRecord.fromDbMap(
    Map<String, Object?> map, {
    ChatAttachmentRecord? attachment,
  }) {
    return ChatMessageRecord(
      id: (map['id'] ?? '').toString(),
      conversationId: (map['conversation_id'] ?? '').toString(),
      hallId: (map['hall_id'] ?? '').toString(),
      conversationType: _parseEnum(
        ChatConversationType.values,
        (map['conversation_type'] ?? '').toString(),
        ChatConversationType.hall,
      ),
      senderVirtualIp: (map['sender_virtual_ip'] ?? '').toString(),
      senderName: (map['sender_name'] ?? '').toString(),
      senderSeq: int.tryParse('${map['sender_seq']}') ?? 0,
      direction: _parseEnum(
        ChatMessageDirection.values,
        (map['direction'] ?? '').toString(),
        ChatMessageDirection.incoming,
      ),
      contentType: _parseEnum(
        ChatMessageContentType.values,
        (map['content_type'] ?? '').toString(),
        ChatMessageContentType.text,
      ),
      status: _parseEnum(
        ChatMessageStatus.values,
        (map['status'] ?? '').toString(),
        ChatMessageStatus.sent,
      ),
      text: (map['text'] ?? '').toString(),
      peerVirtualIp: map['peer_virtual_ip']?.toString(),
      roomId: map['room_id']?.toString(),
      attachmentId: map['attachment_id']?.toString(),
      attachment: attachment,
      isSyncMessage: (int.tryParse('${map['is_sync_message']}') ?? 0) == 1,
      isRead: (int.tryParse('${map['is_read']}') ?? 0) == 1,
      sentAtEpochMs: int.tryParse('${map['sent_at']}') ?? 0,
      createdAtEpochMs: int.tryParse('${map['created_at']}') ?? 0,
      metadataJson: (map['metadata_json'] ?? '{}').toString(),
    );
  }

  Map<String, dynamic> toTransportJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'hallId': hallId,
      'conversationType': _enumName(conversationType),
      'senderVirtualIp': senderVirtualIp,
      'senderName': senderName,
      'senderSeq': senderSeq,
      'direction': _enumName(direction),
      'contentType': _enumName(contentType),
      'status': _enumName(status),
      'text': text,
      'peerVirtualIp': peerVirtualIp,
      'roomId': roomId,
      'attachmentId': attachmentId,
      'isSyncMessage': isSyncMessage,
      'isRead': isRead,
      'sentAtEpochMs': sentAtEpochMs,
      'createdAtEpochMs': createdAtEpochMs,
      'metadataJson': metadataJson,
      'attachment': attachment?.toTransportJson(),
    };
  }

  factory ChatMessageRecord.fromTransportJson(Map<String, dynamic> map) {
    final attachmentMap = map['attachment'];
    return ChatMessageRecord(
      id: (map['id'] ?? '').toString(),
      conversationId: (map['conversationId'] ?? '').toString(),
      hallId: (map['hallId'] ?? '').toString(),
      conversationType: _parseEnum(
        ChatConversationType.values,
        (map['conversationType'] ?? '').toString(),
        ChatConversationType.hall,
      ),
      senderVirtualIp: (map['senderVirtualIp'] ?? '').toString(),
      senderName: (map['senderName'] ?? '').toString(),
      senderSeq: int.tryParse('${map['senderSeq']}') ?? 0,
      direction: _parseEnum(
        ChatMessageDirection.values,
        (map['direction'] ?? '').toString(),
        ChatMessageDirection.incoming,
      ),
      contentType: _parseEnum(
        ChatMessageContentType.values,
        (map['contentType'] ?? '').toString(),
        ChatMessageContentType.text,
      ),
      status: _parseEnum(
        ChatMessageStatus.values,
        (map['status'] ?? '').toString(),
        ChatMessageStatus.sent,
      ),
      text: (map['text'] ?? '').toString(),
      peerVirtualIp: map['peerVirtualIp']?.toString(),
      roomId: map['roomId']?.toString(),
      attachmentId: map['attachmentId']?.toString(),
      attachment: attachmentMap is Map<String, dynamic>
          ? ChatAttachmentRecord.fromTransportJson(attachmentMap)
          : null,
      isSyncMessage: map['isSyncMessage'] == true,
      isRead: map['isRead'] == true,
      sentAtEpochMs: int.tryParse('${map['sentAtEpochMs']}') ?? 0,
      createdAtEpochMs: int.tryParse('${map['createdAtEpochMs']}') ?? 0,
      metadataJson: (map['metadataJson'] ?? '{}').toString(),
    );
  }

  ChatMessageRecord copyWith({
    ChatMessageStatus? status,
    bool? isRead,
    ChatAttachmentRecord? attachment,
    String? attachmentId,
    String? metadataJson,
  }) {
    return ChatMessageRecord(
      id: id,
      conversationId: conversationId,
      hallId: hallId,
      conversationType: conversationType,
      senderVirtualIp: senderVirtualIp,
      senderName: senderName,
      senderSeq: senderSeq,
      direction: direction,
      contentType: contentType,
      status: status ?? this.status,
      text: text,
      peerVirtualIp: peerVirtualIp,
      roomId: roomId,
      attachmentId: attachmentId ?? this.attachmentId,
      attachment: attachment ?? this.attachment,
      isSyncMessage: isSyncMessage,
      isRead: isRead ?? this.isRead,
      sentAtEpochMs: sentAtEpochMs,
      createdAtEpochMs: createdAtEpochMs,
      metadataJson: metadataJson ?? this.metadataJson,
    );
  }
}

class ChatRoomDescriptor {
  const ChatRoomDescriptor({
    required this.roomId,
    required this.hallId,
    required this.roomName,
    required this.creatorVirtualIp,
    required this.locallyJoined,
    required this.isActive,
    required this.lastSeenAtEpochMs,
    required this.updatedAtEpochMs,
    this.metadataJson = '{}',
  });

  final String roomId;
  final String hallId;
  final String roomName;
  final String creatorVirtualIp;
  final bool locallyJoined;
  final bool isActive;
  final int lastSeenAtEpochMs;
  final int updatedAtEpochMs;
  final String metadataJson;

  Map<String, Object?> toDbMap() {
    return {
      'room_id': roomId,
      'hall_id': hallId,
      'room_name': roomName,
      'creator_virtual_ip': creatorVirtualIp,
      'locally_joined': locallyJoined ? 1 : 0,
      'is_active': isActive ? 1 : 0,
      'last_seen_at': lastSeenAtEpochMs,
      'updated_at': updatedAtEpochMs,
      'metadata_json': metadataJson,
    };
  }

  factory ChatRoomDescriptor.fromDbMap(Map<String, Object?> map) {
    return ChatRoomDescriptor(
      roomId: (map['room_id'] ?? '').toString(),
      hallId: (map['hall_id'] ?? '').toString(),
      roomName: (map['room_name'] ?? '').toString(),
      creatorVirtualIp: (map['creator_virtual_ip'] ?? '').toString(),
      locallyJoined: (int.tryParse('${map['locally_joined']}') ?? 0) == 1,
      isActive: (int.tryParse('${map['is_active']}') ?? 0) == 1,
      lastSeenAtEpochMs: int.tryParse('${map['last_seen_at']}') ?? 0,
      updatedAtEpochMs: int.tryParse('${map['updated_at']}') ?? 0,
      metadataJson: (map['metadata_json'] ?? '{}').toString(),
    );
  }

  Map<String, dynamic> toTransportJson() {
    return {
      'roomId': roomId,
      'hallId': hallId,
      'roomName': roomName,
      'creatorVirtualIp': creatorVirtualIp,
      'metadataJson': metadataJson,
    };
  }

  factory ChatRoomDescriptor.fromTransportJson(Map<String, dynamic> map) {
    return ChatRoomDescriptor(
      roomId: (map['roomId'] ?? '').toString(),
      hallId: (map['hallId'] ?? '').toString(),
      roomName: (map['roomName'] ?? '').toString(),
      creatorVirtualIp: (map['creatorVirtualIp'] ?? '').toString(),
      locallyJoined: false,
      isActive: true,
      lastSeenAtEpochMs: 0,
      updatedAtEpochMs: 0,
      metadataJson: (map['metadataJson'] ?? '{}').toString(),
    );
  }

  ChatRoomDescriptor copyWith({
    bool? locallyJoined,
    bool? isActive,
    int? lastSeenAtEpochMs,
    int? updatedAtEpochMs,
    String? metadataJson,
  }) {
    return ChatRoomDescriptor(
      roomId: roomId,
      hallId: hallId,
      roomName: roomName,
      creatorVirtualIp: creatorVirtualIp,
      locallyJoined: locallyJoined ?? this.locallyJoined,
      isActive: isActive ?? this.isActive,
      lastSeenAtEpochMs: lastSeenAtEpochMs ?? this.lastSeenAtEpochMs,
      updatedAtEpochMs: updatedAtEpochMs ?? this.updatedAtEpochMs,
      metadataJson: metadataJson ?? this.metadataJson,
    );
  }
}

class ChatHall {
  const ChatHall({
    required this.id,
    required this.title,
    required this.networkName,
    required this.connectServer,
    required this.localVirtualIp,
    required this.peerVirtualIps,
  });

  final String id;
  final String title;
  final String networkName;
  final String connectServer;
  final String localVirtualIp;
  final List<String> peerVirtualIps;
}

class ChatPeerPresence {
  const ChatPeerPresence({
    required this.key,
    required this.hallId,
    required this.hallTitle,
    required this.displayName,
    required this.virtualIp,
    required this.isOnline,
    required this.rooms,
    required this.sentAtEpochMs,
  });

  final String key;
  final String hallId;
  final String hallTitle;
  final String displayName;
  final String virtualIp;
  final bool isOnline;
  final List<ChatRoomDescriptor> rooms;
  final int sentAtEpochMs;
}

class ChatPresenceContext {
  const ChatPresenceContext({
    required this.hallId,
    required this.hallTitle,
    required this.displayName,
    required this.virtualIp,
    required this.peerVirtualIps,
    required this.rooms,
  });

  final String hallId;
  final String hallTitle;
  final String displayName;
  final String virtualIp;
  final List<String> peerVirtualIps;
  final List<ChatRoomDescriptor> rooms;
}

class ChatPresenceAnnouncement {
  const ChatPresenceAnnouncement({
    required this.hallId,
    required this.hallTitle,
    required this.displayName,
    required this.virtualIp,
    required this.rooms,
    required this.sentAtEpochMs,
  });

  final String hallId;
  final String hallTitle;
  final String displayName;
  final String virtualIp;
  final List<ChatRoomDescriptor> rooms;
  final int sentAtEpochMs;

  Map<String, dynamic> toJson() {
    return {
      'type': 'vnt_chat_presence_v1',
      'hallId': hallId,
      'hallTitle': hallTitle,
      'displayName': displayName,
      'virtualIp': virtualIp,
      'rooms': rooms.map((room) => room.toTransportJson()).toList(),
      'sentAtEpochMs': sentAtEpochMs,
    };
  }

  factory ChatPresenceAnnouncement.fromJson(Map<String, dynamic> map) {
    final rawRooms = map['rooms'];
    final rooms = <ChatRoomDescriptor>[];
    if (rawRooms is List) {
      for (final item in rawRooms) {
        if (item is Map<String, dynamic>) {
          rooms.add(ChatRoomDescriptor.fromTransportJson(item));
        } else if (item is Map) {
          rooms.add(ChatRoomDescriptor.fromTransportJson(
            item.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          ));
        }
      }
    }
    return ChatPresenceAnnouncement(
      hallId: (map['hallId'] ?? '').toString(),
      hallTitle: (map['hallTitle'] ?? '').toString(),
      displayName: (map['displayName'] ?? '').toString(),
      virtualIp: (map['virtualIp'] ?? '').toString(),
      rooms: rooms,
      sentAtEpochMs: int.tryParse('${map['sentAtEpochMs']}') ?? 0,
    );
  }
}

class ChatSyncRequestPayload {
  const ChatSyncRequestPayload({
    required this.hallId,
    required this.requesterVirtualIp,
    required this.requesterName,
    required this.joinedRoomIds,
    required this.summary,
  });

  final String hallId;
  final String requesterVirtualIp;
  final String requesterName;
  final List<String> joinedRoomIds;
  final Map<String, Map<String, int>> summary;

  Map<String, dynamic> toJson() {
    return {
      'hallId': hallId,
      'requesterVirtualIp': requesterVirtualIp,
      'requesterName': requesterName,
      'joinedRoomIds': joinedRoomIds,
      'summary': summary,
    };
  }

  factory ChatSyncRequestPayload.fromJson(Map<String, dynamic> map) {
    final summary = <String, Map<String, int>>{};
    final rawSummary = map['summary'];
    if (rawSummary is Map) {
      for (final entry in rawSummary.entries) {
        final inner = <String, int>{};
        if (entry.value is Map) {
          for (final innerEntry in (entry.value as Map).entries) {
            inner[innerEntry.key.toString()] =
                int.tryParse('${innerEntry.value}') ?? 0;
          }
        }
        summary[entry.key.toString()] = inner;
      }
    }

    final joinedRoomIds = <String>[];
    final rawJoined = map['joinedRoomIds'];
    if (rawJoined is List) {
      for (final item in rawJoined) {
        final value = item.toString();
        if (value.isNotEmpty) {
          joinedRoomIds.add(value);
        }
      }
    }

    return ChatSyncRequestPayload(
      hallId: (map['hallId'] ?? '').toString(),
      requesterVirtualIp: (map['requesterVirtualIp'] ?? '').toString(),
      requesterName: (map['requesterName'] ?? '').toString(),
      joinedRoomIds: joinedRoomIds,
      summary: summary,
    );
  }
}

class ChatTransportPacket {
  const ChatTransportPacket({
    required this.type,
    this.message,
    this.syncRequest,
    this.replyPort,
    this.transferOffset,
  });

  final String type;
  final ChatMessageRecord? message;
  final ChatSyncRequestPayload? syncRequest;
  final int? replyPort;
  final int? transferOffset;

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'message': message?.toTransportJson(),
      'syncRequest': syncRequest?.toJson(),
      'replyPort': replyPort,
      'transferOffset': transferOffset,
    };
  }

  factory ChatTransportPacket.fromJson(Map<String, dynamic> map) {
    final messageMap = map['message'];
    final syncMap = map['syncRequest'];
    return ChatTransportPacket(
      type: (map['type'] ?? '').toString(),
      message: messageMap is Map<String, dynamic>
          ? ChatMessageRecord.fromTransportJson(messageMap)
          : (messageMap is Map
              ? ChatMessageRecord.fromTransportJson(
                  messageMap.map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                )
              : null),
      syncRequest: syncMap is Map<String, dynamic>
          ? ChatSyncRequestPayload.fromJson(syncMap)
          : (syncMap is Map
              ? ChatSyncRequestPayload.fromJson(
                  syncMap.map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                )
              : null),
      replyPort:
          map['replyPort'] == null ? null : int.tryParse('${map['replyPort']}'),
      transferOffset: map['transferOffset'] == null
          ? null
          : int.tryParse('${map['transferOffset']}'),
    );
  }

  String toJsonLine() => jsonEncode(toJson());
}

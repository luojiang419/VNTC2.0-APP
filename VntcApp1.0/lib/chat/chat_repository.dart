import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'chat_models.dart';

class ChatRepository {
  ChatRepository._();

  static final ChatRepository instance = ChatRepository._();

  static const Duration defaultRetention = Duration(days: 30);
  static const Uuid _uuid = Uuid();

  Database? _database;
  Directory? _baseDir;
  String? _dbPath;

  Future<void> init() async {
    if (_database != null) {
      return;
    }
    _baseDir = await _resolveBaseDirectory();
    final dbPath = path.join(_baseDir!.path, 'chat.db');
    _dbPath = dbPath;
    _database = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );
  }

  Future<Database> get _db async {
    await init();
    return _database!;
  }

  Future<Directory> _resolveBaseDirectory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(path.join(root.path, 'chat'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final attachmentsDir = Directory(path.join(dir.path, 'attachments'));
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }
    final outgoingDir = Directory(path.join(attachmentsDir.path, 'outgoing'));
    if (!await outgoingDir.exists()) {
      await outgoingDir.create(recursive: true);
    }
    final incomingDir = Directory(path.join(attachmentsDir.path, 'incoming'));
    if (!await incomingDir.exists()) {
      await incomingDir.create(recursive: true);
    }
    final tempDir = Directory(path.join(dir.path, 'temp'));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE peers (
        peer_id TEXT PRIMARY KEY,
        network_key TEXT NOT NULL,
        virtual_ip TEXT NOT NULL,
        device_name TEXT NOT NULL,
        remark TEXT NOT NULL DEFAULT '',
        is_online INTEGER NOT NULL DEFAULT 0,
        last_seen_at INTEGER NOT NULL,
        capabilities_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE friends (
        peer_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE channels (
        channel_id TEXT PRIMARY KEY,
        network_key TEXT NOT NULL,
        name TEXT NOT NULL,
        owner_peer_id TEXT NOT NULL,
        is_private INTEGER NOT NULL DEFAULT 0,
        joined INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE channel_members (
        channel_id TEXT NOT NULL,
        peer_id TEXT NOT NULL,
        role TEXT NOT NULL,
        joined_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (channel_id, peer_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE conversations (
        conversation_id TEXT PRIMARY KEY,
        network_key TEXT NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        peer_id TEXT,
        channel_id TEXT,
        unread_count INTEGER NOT NULL DEFAULT 0,
        last_preview TEXT NOT NULL DEFAULT '',
        last_message_at INTEGER,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        message_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        network_key TEXT NOT NULL,
        sender_peer_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        attachment_id TEXT,
        peer_id TEXT,
        channel_id TEXT,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        sent_at INTEGER NOT NULL,
        received_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE attachments (
        attachment_id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        direction TEXT NOT NULL,
        type TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        local_path TEXT NOT NULL DEFAULT '',
        remote_path TEXT NOT NULL DEFAULT '',
        offer_status TEXT NOT NULL,
        transfer_status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE call_logs (
        call_id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        network_key TEXT NOT NULL,
        type TEXT NOT NULL,
        peer_id TEXT,
        channel_id TEXT,
        state TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        metadata_json TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_peers_network_key ON peers (network_key, is_online)',
    );
    await db.execute(
      'CREATE INDEX idx_conversations_network_key ON conversations (network_key, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_conversation_id ON messages (conversation_id, received_at)',
    );
  }

  Future<Directory> get attachmentsDirectory async {
    await init();
    return Directory(path.join(_baseDir!.path, 'attachments'));
  }

  Future<String> get databasePath async {
    await init();
    return _dbPath ?? '';
  }

  Future<String> get baseDirectoryPath async {
    await init();
    return _baseDir?.path ?? '';
  }

  Future<Directory> get tempDirectory async {
    await init();
    return Directory(path.join(_baseDir!.path, 'temp'));
  }

  Future<void> purgeExpiredData({
    Duration retention = defaultRetention,
  }) async {
    final db = await _db;
    final cutoff = DateTime.now().subtract(retention).millisecondsSinceEpoch;
    final oldAttachments = await db.query(
      'attachments',
      columns: ['local_path'],
      where: 'created_at < ?',
      whereArgs: [cutoff],
    );
    for (final row in oldAttachments) {
      final localPath = row['local_path'] as String? ?? '';
      if (localPath.isNotEmpty) {
        final file = File(localPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    await db.delete(
      'attachments',
      where: 'created_at < ?',
      whereArgs: [cutoff],
    );
    await db.delete(
      'messages',
      where: 'created_at < ?',
      whereArgs: [cutoff],
    );
  }

  Future<void> clearAllChatData() async {
    final db = await _db;
    await db.delete('attachments');
    await db.delete('messages');
    await db.delete('conversations');
    await db.delete('channel_members');
    await db.delete('channels');
    await db.delete('friends');
    await db.delete('peers');
    await db.delete('call_logs');

    final attachments = await attachmentsDirectory;
    if (await attachments.exists()) {
      await attachments.delete(recursive: true);
      await attachments.create(recursive: true);
      await Directory(path.join(attachments.path, 'outgoing'))
          .create(recursive: true);
      await Directory(path.join(attachments.path, 'incoming'))
          .create(recursive: true);
    }

    final temp = await tempDirectory;
    if (await temp.exists()) {
      await temp.delete(recursive: true);
      await temp.create(recursive: true);
    }
  }

  Future<void> markNetworkPeersOffline(String networkKey) async {
    final db = await _db;
    await db.update(
      'peers',
      {
        'is_online': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'network_key = ?',
      whereArgs: [networkKey],
    );
  }

  Future<void> upsertPeer(ChatPeer peer) async {
    final db = await _db;
    await db.insert(
      'peers',
      peer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatPeer?> getPeer(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'peers',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatPeer.fromMap(rows.first);
  }

  Future<List<ChatPeer>> listPeers({
    String? networkKey,
    bool onlineOnly = false,
    bool excludeLocal = false,
    String? localPeerId,
  }) async {
    final db = await _db;
    final clauses = <String>[];
    final args = <Object?>[];
    if (networkKey != null) {
      clauses.add('network_key = ?');
      args.add(networkKey);
    }
    if (onlineOnly) {
      clauses.add('is_online = 1');
    }
    if (excludeLocal && localPeerId != null) {
      clauses.add('peer_id != ?');
      args.add(localPeerId);
    }
    final rows = await db.query(
      'peers',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'is_online DESC, updated_at DESC, virtual_ip ASC',
    );
    return rows.map(ChatPeer.fromMap).toList();
  }

  Future<void> setPeerRemark(String peerId, String remark) async {
    final db = await _db;
    await db.update(
      'peers',
      {
        'remark': remark.trim(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  Future<void> upsertFriend(ChatFriend friend) async {
    final db = await _db;
    await db.insert(
      'friends',
      friend.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatFriend?> getFriend(String peerId) async {
    final db = await _db;
    final rows = await db.query(
      'friends',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatFriend.fromMap(rows.first);
  }

  Future<List<ChatFriend>> listFriends() async {
    final db = await _db;
    final rows = await db.query(
      'friends',
      orderBy: 'updated_at DESC',
    );
    return rows.map(ChatFriend.fromMap).toList();
  }

  Future<void> upsertChannel(ChatChannel channel) async {
    final db = await _db;
    await db.insert(
      'channels',
      channel.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatChannel?> getChannel(String channelId) async {
    final db = await _db;
    final rows = await db.query(
      'channels',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatChannel.fromMap(rows.first);
  }

  Future<List<ChatChannel>> listChannels({String? networkKey}) async {
    final db = await _db;
    final rows = await db.query(
      'channels',
      where: networkKey == null ? null : 'network_key = ?',
      whereArgs: networkKey == null ? null : [networkKey],
      orderBy: 'joined DESC, archived ASC, updated_at DESC',
    );
    return rows.map(ChatChannel.fromMap).toList();
  }

  Future<void> upsertChannelMember(ChatChannelMember member) async {
    final db = await _db;
    await db.insert(
      'channel_members',
      member.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeChannelMember(String channelId, String peerId) async {
    final db = await _db;
    await db.delete(
      'channel_members',
      where: 'channel_id = ? AND peer_id = ?',
      whereArgs: [channelId, peerId],
    );
  }

  Future<List<ChatChannelMember>> listChannelMembers(String channelId) async {
    final db = await _db;
    final rows = await db.query(
      'channel_members',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'role ASC, joined_at ASC',
    );
    return rows.map(ChatChannelMember.fromMap).toList();
  }

  Future<void> upsertConversation(ChatConversationSummary conversation) async {
    final db = await _db;
    await db.insert(
      'conversations',
      conversation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatConversationSummary?> getConversation(
      String conversationId) async {
    final db = await _db;
    final rows = await db.query(
      'conversations',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatConversationSummary.fromMap(rows.first);
  }

  Future<List<ChatConversationSummary>> listConversations() async {
    final db = await _db;
    final rows = await db.query(
      'conversations',
      where: 'archived = 0',
      orderBy: 'COALESCE(last_message_at, updated_at) DESC',
    );
    return rows.map(ChatConversationSummary.fromMap).toList();
  }

  Future<void> markConversationRead(String conversationId) async {
    final db = await _db;
    await db.update(
      'conversations',
      {
        'unread_count': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<void> upsertMessage(ChatMessage message) async {
    final db = await _db;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> replaceMessage(ChatMessage message) async {
    final db = await _db;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatMessage?> getMessage(String messageId) async {
    final db = await _db;
    final rows = await db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatMessage.fromMap(rows.first);
  }

  Future<List<ChatMessage>> listMessages(String conversationId) async {
    final db = await _db;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'received_at ASC, created_at ASC',
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> upsertAttachment(ChatAttachment attachment) async {
    final db = await _db;
    await db.insert(
      'attachments',
      attachment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatAttachment?> getAttachment(String attachmentId) async {
    final db = await _db;
    final rows = await db.query(
      'attachments',
      where: 'attachment_id = ?',
      whereArgs: [attachmentId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatAttachment.fromMap(rows.first);
  }

  Future<void> upsertCallLog(ChatCallLog log) async {
    final db = await _db;
    await db.insert(
      'call_logs',
      log.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<File> importOutgoingFile(
    String sourcePath, {
    String? preferredExtension,
  }) async {
    final attachmentsDir = await attachmentsDirectory;
    final outgoingDir = Directory(path.join(attachmentsDir.path, 'outgoing'));
    final extension =
        preferredExtension ?? path.extension(sourcePath).trim().toLowerCase();
    final target = File(
      path.join(
        outgoingDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}$extension',
      ),
    );
    await File(sourcePath).copy(target.path);
    return target;
  }

  Future<File> createIncomingFile(String fileName) async {
    final attachmentsDir = await attachmentsDirectory;
    final incomingDir = Directory(path.join(attachmentsDir.path, 'incoming'));
    final target = File(
      path.join(
        incomingDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}_${path.basename(fileName)}',
      ),
    );
    return target;
  }

  Future<String> computeSha256(String filePath) async {
    final digest = await sha256.bind(File(filePath).openRead()).first;
    return digest.toString();
  }

  Future<String> ensureTemporaryVoiceFile({String extension = '.wav'}) async {
    final dir = await tempDirectory;
    return path.join(
      dir.path,
      '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4()}$extension',
    );
  }

  Future<void> deleteFileIfExists(String filePath) async {
    if (filePath.isEmpty) {
      return;
    }
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  String buildPreview(ChatMessageKind kind, String text, {String? fileName}) {
    switch (kind) {
      case ChatMessageKind.text:
        return text;
      case ChatMessageKind.image:
        return '[图片] ${fileName ?? ''}'.trim();
      case ChatMessageKind.file:
        return '[文件] ${fileName ?? ''}'.trim();
      case ChatMessageKind.voiceNote:
        return '[语音消息]';
      case ChatMessageKind.system:
        return text;
    }
  }

  Future<void> touchConversation({
    required String conversationId,
    required String networkKey,
    required ChatConversationType type,
    required String title,
    String? peerId,
    String? channelId,
    required String preview,
    required DateTime messageTime,
    required bool incrementUnread,
  }) async {
    final existing = await getConversation(conversationId);
    final now = DateTime.now();
    final summary = (existing ??
            ChatConversationSummary(
              conversationId: conversationId,
              networkKey: networkKey,
              type: type,
              title: title,
              peerId: peerId,
              channelId: channelId,
              unreadCount: 0,
              lastPreview: '',
              lastMessageAt: null,
              archived: false,
              createdAt: now,
              updatedAt: now,
            ))
        .copyWith(
      title: title,
      unreadCount: incrementUnread
          ? (existing?.unreadCount ?? 0) + 1
          : (existing?.unreadCount ?? 0),
      lastPreview: preview,
      lastMessageAt: messageTime,
      updatedAt: now,
    );
    await upsertConversation(summary);
  }

  Future<List<ChatAttachment>> listPendingAttachments() async {
    final db = await _db;
    final rows = await db.query(
      'attachments',
      where: 'offer_status IN (?, ?) OR transfer_status IN (?, ?)',
      whereArgs: [
        ChatMessageStatus.awaitingAccept.name,
        ChatMessageStatus.accepted.name,
        ChatMessageStatus.pending.name,
        ChatMessageStatus.accepted.name,
      ],
    );
    return rows.map(ChatAttachment.fromMap).toList();
  }

  Future<void> deleteConversation(String conversationId) async {
    final db = await _db;
    final messages = await listMessages(conversationId);
    for (final message in messages) {
      if (message.attachmentId != null) {
        final attachment = await getAttachment(message.attachmentId!);
        if (attachment != null) {
          await deleteFileIfExists(attachment.localPath);
        }
      }
    }
    await db.delete(
      'attachments',
      where:
          'message_id IN (SELECT message_id FROM messages WHERE conversation_id = ?)',
      whereArgs: [conversationId],
    );
    await db.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    await db.delete(
      'conversations',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  @visibleForTesting
  Future<void> resetForTests() async {
    final db = await _db;
    await db.delete('attachments');
    await db.delete('messages');
    await db.delete('conversations');
    await db.delete('channel_members');
    await db.delete('channels');
    await db.delete('friends');
    await db.delete('peers');
    await db.delete('call_logs');
  }
}

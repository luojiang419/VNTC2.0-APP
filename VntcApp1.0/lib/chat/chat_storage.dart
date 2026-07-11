import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

class ChatStorage {
  ChatStorage({
    String? databasePath,
    String? attachmentsDirectoryPath,
  })  : _databasePath = databasePath,
        _attachmentsDirectoryPath = attachmentsDirectoryPath;

  final String? _databasePath;
  final String? _attachmentsDirectoryPath;
  final Uuid _uuid = const Uuid();
  Database? _db;

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null) {
      await db.close();
    }
  }

  Future<void> init() async {
    final db = await _ensureDatabase();
    final attachmentsDirectory = await ensureAttachmentsDirectory();
    await _repairLegacyAbsoluteAttachmentPaths(db, attachmentsDirectory);
  }

  Future<Database> _ensureDatabase() async {
    if (_db != null) {
      return _db!;
    }

    final dbPath = _databasePath ?? await _resolveDefaultDatabasePath();
    final dbFile = File(dbPath);
    final parent = dbFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  hall_id TEXT NOT NULL,
  title TEXT NOT NULL,
  peer_virtual_ip TEXT,
  peer_display_name TEXT,
  room_id TEXT,
  unread_count INTEGER NOT NULL DEFAULT 0,
  last_read_at INTEGER NOT NULL DEFAULT 0,
  last_message_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  metadata_json TEXT NOT NULL DEFAULT '{}'
)
''');
        await db.execute('''
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  hall_id TEXT NOT NULL,
  conversation_type TEXT NOT NULL,
  sender_virtual_ip TEXT NOT NULL,
  sender_name TEXT NOT NULL,
  sender_seq INTEGER NOT NULL,
  direction TEXT NOT NULL,
  content_type TEXT NOT NULL,
  status TEXT NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  peer_virtual_ip TEXT,
  room_id TEXT,
  attachment_id TEXT,
  is_sync_message INTEGER NOT NULL DEFAULT 0,
  is_read INTEGER NOT NULL DEFAULT 0,
  sent_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE(conversation_id, sender_virtual_ip, sender_seq)
)
''');
        await db.execute('''
CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL UNIQUE,
  file_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  relative_path TEXT NOT NULL,
  duration_ms INTEGER,
  auto_sync_eligible INTEGER NOT NULL DEFAULT 0,
  payload_available INTEGER NOT NULL DEFAULT 0,
  needs_manual_resend INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
)
''');
        await db.execute('''
CREATE TABLE room_membership_cache (
  room_id TEXT PRIMARY KEY,
  hall_id TEXT NOT NULL,
  room_name TEXT NOT NULL,
  creator_virtual_ip TEXT NOT NULL,
  locally_joined INTEGER NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  metadata_json TEXT NOT NULL DEFAULT '{}'
)
''');
        await db.execute('''
CREATE TABLE sync_checkpoints (
  peer_key TEXT PRIMARY KEY,
  hall_id TEXT NOT NULL,
  last_sync_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
)
''');
        await db.execute(
          'CREATE INDEX idx_messages_conversation_sent_at ON messages(conversation_id, sent_at)',
        );
        await db.execute(
          'CREATE INDEX idx_messages_hall_sender_seq ON messages(hall_id, sender_virtual_ip, sender_seq)',
        );
      },
    );
    return _db!;
  }

  Future<String> _resolveDefaultDatabasePath() async {
    return path.join(
      await _resolveDefaultChatRootDirectoryPath(),
      'chat.db',
    );
  }

  Future<String> ensureAttachmentsDirectory() async {
    final directoryPath = _attachmentsDirectoryPath ??
        path.join(
          await _resolveDefaultChatRootDirectoryPath(),
          'attachments',
        );
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  }

  Future<String> _resolveDefaultChatRootDirectoryPath() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final supportDirectory = await getApplicationSupportDirectory();
      return resolveDefaultChatRootDirectoryPathForPlatform(
        useApplicationSupportDirectory: true,
        applicationSupportDirectoryPath: supportDirectory.path,
        configDirectoryPath: '',
      );
    }

    return resolveDefaultChatRootDirectoryPathForPlatform(
      useApplicationSupportDirectory: false,
      applicationSupportDirectoryPath: '',
      configDirectoryPath: RuntimeStoragePaths.resolveConfigDirectoryPathSync(),
    );
  }

  @visibleForTesting
  static String resolveDefaultChatRootDirectoryPathForPlatform({
    required bool useApplicationSupportDirectory,
    required String applicationSupportDirectoryPath,
    required String configDirectoryPath,
  }) {
    final rootPath = useApplicationSupportDirectory
        ? applicationSupportDirectoryPath
        : configDirectoryPath;
    return path.join(rootPath, 'chat');
  }

  Future<List<ChatConversation>> loadConversations() async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'conversations',
      orderBy: 'last_message_at DESC, updated_at DESC',
    );
    return rows.map(ChatConversation.fromDbMap).toList(growable: false);
  }

  Future<List<ChatConversation>> loadConversationsByType(
    ChatConversationType type,
  ) async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'conversations',
      where: 'type = ?',
      whereArgs: [chatEnumName(type)],
      orderBy: 'last_message_at DESC, updated_at DESC',
    );
    return rows.map(ChatConversation.fromDbMap).toList(growable: false);
  }

  Future<void> upsertConversation(ChatConversation conversation) async {
    final db = await _ensureDatabase();
    await db.insert(
      'conversations',
      conversation.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ChatConversation?> getConversation(String conversationId) async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return ChatConversation.fromDbMap(rows.first);
  }

  Future<void> mergeConversationAlias({
    required String sourceConversationId,
    required ChatConversation targetConversation,
  }) async {
    if (sourceConversationId == targetConversation.id) {
      return;
    }
    final db = await _ensureDatabase();
    await db.transaction((txn) async {
      final sourceRows = await txn.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [sourceConversationId],
        limit: 1,
      );
      if (sourceRows.isEmpty) {
        return;
      }
      final source = ChatConversation.fromDbMap(sourceRows.first);
      final targetRows = await txn.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [targetConversation.id],
        limit: 1,
      );
      final existingTarget = targetRows.isEmpty
          ? null
          : ChatConversation.fromDbMap(targetRows.first);

      final sourceMessages = await txn.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [sourceConversationId],
      );
      for (final row in sourceMessages) {
        final messageId = (row['id'] ?? '').toString();
        final updated = await txn.update(
          'messages',
          {
            'conversation_id': targetConversation.id,
            'hall_id': targetConversation.hallId,
          },
          where: 'id = ?',
          whereArgs: [messageId],
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (updated == 0) {
          await txn.delete(
            'messages',
            where: 'id = ?',
            whereArgs: [messageId],
          );
          await txn.delete(
            'attachments',
            where: 'message_id = ?',
            whereArgs: [messageId],
          );
        }
      }
      await txn.delete(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [sourceConversationId],
      );

      final unreadRows = await txn.rawQuery('''
SELECT COUNT(*) AS total
FROM messages
WHERE conversation_id = ? AND direction = ? AND is_read = 0
''', [
        targetConversation.id,
        chatEnumName(ChatMessageDirection.incoming),
      ]);
      final unreadCount = unreadRows.isEmpty
          ? 0
          : int.tryParse('${unreadRows.first['total']}') ?? 0;
      final preferred = existingTarget ?? source;
      await txn.insert(
        'conversations',
        ChatConversation(
          id: targetConversation.id,
          type: targetConversation.type,
          hallId: targetConversation.hallId,
          title: preferred.title.isEmpty
              ? targetConversation.title
              : preferred.title,
          unreadCount: unreadCount,
          lastReadAtEpochMs: [
            source.lastReadAtEpochMs,
            existingTarget?.lastReadAtEpochMs ?? 0,
          ].reduce((left, right) => left > right ? left : right),
          lastMessageAtEpochMs: [
            source.lastMessageAtEpochMs,
            existingTarget?.lastMessageAtEpochMs ?? 0,
          ].reduce((left, right) => left > right ? left : right),
          updatedAtEpochMs: [
            source.updatedAtEpochMs,
            existingTarget?.updatedAtEpochMs ?? 0,
            targetConversation.updatedAtEpochMs,
          ].reduce((left, right) => left > right ? left : right),
          metadataJson: preferred.metadataJson,
          peerVirtualIp: targetConversation.peerVirtualIp,
          peerDisplayName:
              targetConversation.peerDisplayName ?? preferred.peerDisplayName,
          roomId: targetConversation.roomId ?? preferred.roomId,
        ).toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'conversations',
        where: 'id = ?',
        whereArgs: [sourceConversationId],
      );
    });
  }

  Future<List<ChatRoomDescriptor>> loadRoomDescriptors({
    String? hallId,
  }) async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'room_membership_cache',
      where: hallId == null ? null : 'hall_id = ?',
      whereArgs: hallId == null ? null : [hallId],
      orderBy: 'is_active DESC, locally_joined DESC, updated_at DESC',
    );
    return rows.map(ChatRoomDescriptor.fromDbMap).toList(growable: false);
  }

  Future<void> upsertRoomDescriptor(ChatRoomDescriptor room) async {
    final db = await _ensureDatabase();
    await db.insert(
      'room_membership_cache',
      room.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessageRecord>> loadMessages(
    String conversationId, {
    int limit = 200,
  }) async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'sent_at ASC, created_at ASC',
      limit: limit,
    );

    final attachmentIds = rows
        .map((row) => row['attachment_id']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final attachments = await _loadAttachmentsByIds(attachmentIds);

    return rows
        .map(
          (row) => ChatMessageRecord.fromDbMap(
            row,
            attachment: attachments[row['attachment_id']?.toString()],
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, ChatAttachmentRecord>> _loadAttachmentsByIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) {
      return const {};
    }
    final db = await _ensureDatabase();
    final rows = await db.query(
      'attachments',
      where: 'id IN (${List<String>.filled(ids.length, '?').join(', ')})',
      whereArgs: ids,
    );
    final result = <String, ChatAttachmentRecord>{};
    for (final row in rows) {
      final attachment = ChatAttachmentRecord.fromDbMap(row);
      result[attachment.id] = attachment;
    }
    return result;
  }

  Future<void> upsertMessage(
    ChatMessageRecord message, {
    ChatAttachmentRecord? attachment,
    bool incrementUnread = false,
  }) async {
    final db = await _ensureDatabase();
    await db.transaction((txn) async {
      final existingMessage = await txn.query(
        'messages',
        where: 'id = ?',
        whereArgs: [message.id],
        limit: 1,
      );
      await txn.insert(
        'messages',
        message.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (attachment != null) {
        await txn.insert(
          'attachments',
          attachment.toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      final conversation = await txn.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [message.conversationId],
        limit: 1,
      );
      if (conversation.isEmpty) {
        await txn.insert(
          'conversations',
          ChatConversation(
            id: message.conversationId,
            type: message.conversationType,
            hallId: message.hallId,
            title: message.conversationId,
            unreadCount: incrementUnread && existingMessage.isEmpty ? 1 : 0,
            lastReadAtEpochMs: 0,
            lastMessageAtEpochMs: message.sentAtEpochMs,
            updatedAtEpochMs: message.createdAtEpochMs,
            metadataJson: '{}',
            peerVirtualIp: message.peerVirtualIp,
            roomId: message.roomId,
          ).toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        final currentUnread =
            int.tryParse('${conversation.first['unread_count']}') ?? 0;
        await txn.update(
          'conversations',
          {
            'last_message_at': message.sentAtEpochMs,
            'updated_at': message.createdAtEpochMs,
            'unread_count': incrementUnread && existingMessage.isEmpty
                ? currentUnread + 1
                : currentUnread,
          },
          where: 'id = ?',
          whereArgs: [message.conversationId],
        );
      }
    });
  }

  Future<void> markConversationRead(
    String conversationId, {
    int? readAtEpochMs,
  }) async {
    final db = await _ensureDatabase();
    final timestamp = readAtEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'conversations',
        {
          'unread_count': 0,
          'last_read_at': timestamp,
          'updated_at': timestamp,
        },
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      await txn.update(
        'messages',
        {'is_read': 1},
        where: 'conversation_id = ? AND direction = ?',
        whereArgs: [
          conversationId,
          chatEnumName(ChatMessageDirection.incoming)
        ],
      );
    });
  }

  Future<int> loadPrivateUnreadTotal() async {
    final db = await _ensureDatabase();
    final rows = await db.rawQuery('''
SELECT SUM(unread_count) AS total
FROM conversations
WHERE type = ?
''', [chatEnumName(ChatConversationType.direct)]);
    if (rows.isEmpty) {
      return 0;
    }
    return int.tryParse('${rows.first['total']}') ?? 0;
  }

  Future<int> nextSenderSequence(
    String conversationId,
    String senderVirtualIp,
  ) async {
    final db = await _ensureDatabase();
    final rows = await db.rawQuery('''
SELECT MAX(sender_seq) AS max_seq
FROM messages
WHERE conversation_id = ? AND sender_virtual_ip = ?
''', [conversationId, senderVirtualIp]);
    final current =
        rows.isEmpty ? 0 : int.tryParse('${rows.first['max_seq']}') ?? 0;
    return current + 1;
  }

  Future<Map<String, Map<String, int>>> buildSummaryForConversations({
    required Iterable<String> conversationIds,
  }) async {
    final db = await _ensureDatabase();
    final result = <String, Map<String, int>>{};
    for (final conversationId in conversationIds.toSet()) {
      final rows = await db.rawQuery('''
SELECT sender_virtual_ip, MAX(sender_seq) AS max_seq
FROM messages
WHERE conversation_id = ?
GROUP BY sender_virtual_ip
''', [conversationId]);
      final senderMap = <String, int>{};
      for (final row in rows) {
        senderMap[(row['sender_virtual_ip'] ?? '').toString()] =
            int.tryParse('${row['max_seq']}') ?? 0;
      }
      result[conversationId] = senderMap;
    }
    return result;
  }

  Future<void> syncRoomActivityForHall({
    required String hallId,
    required Set<String> activeRoomIds,
    required int timestampEpochMs,
  }) async {
    final db = await _ensureDatabase();
    final rows = await db.query(
      'room_membership_cache',
      where: 'hall_id = ?',
      whereArgs: [hallId],
    );
    for (final row in rows) {
      final roomId = (row['room_id'] ?? '').toString();
      final locallyJoined =
          (int.tryParse('${row['locally_joined']}') ?? 0) == 1;
      final shouldBeActive = activeRoomIds.contains(roomId);
      await db.update(
        'room_membership_cache',
        {
          'is_active': shouldBeActive ? 1 : 0,
          'last_seen_at': shouldBeActive
              ? timestampEpochMs
              : int.tryParse('${row['last_seen_at']}') ?? 0,
          'updated_at': timestampEpochMs,
          'locally_joined': locallyJoined ? 1 : 0,
        },
        where: 'room_id = ?',
        whereArgs: [roomId],
      );
    }
  }

  Future<List<ChatMessageRecord>> loadMissingMessages({
    required Iterable<String> conversationIds,
    required Map<String, Map<String, int>> remoteSummary,
  }) async {
    final missing = <ChatMessageRecord>[];
    for (final conversationId in conversationIds) {
      final localMessages = await loadMessages(conversationId, limit: 1000);
      final summary = remoteSummary[conversationId] ?? const <String, int>{};
      for (final message in localMessages) {
        final knownSeq = summary[message.senderVirtualIp] ?? 0;
        if (message.senderSeq > knownSeq) {
          missing.add(message);
        }
      }
    }
    return missing;
  }

  Future<String> importAttachmentFile(
    String sourceFilePath, {
    required String messageId,
  }) async {
    final attachmentsDir = await ensureAttachmentsDirectory();
    final source = File(sourceFilePath);
    final extension = path.extension(source.path);
    final fileName = '$messageId$extension';
    final target = File(path.join(attachmentsDir, fileName));
    await source.copy(target.path);
    return fileName;
  }

  Future<String> createIncomingAttachmentPath({
    required String originalFileName,
  }) async {
    await ensureAttachmentsDirectory();
    final extension = path.extension(originalFileName);
    return '${_uuid.v4()}$extension';
  }

  Future<void> _repairLegacyAbsoluteAttachmentPaths(
    Database db,
    String attachmentsDirectory,
  ) async {
    final rows = await db.query(
      'attachments',
      columns: <String>['id', 'relative_path'],
    );
    final root = path.canonicalize(path.absolute(attachmentsDirectory));
    for (final row in rows) {
      final value = (row['relative_path'] ?? '').toString();
      if (!path.isAbsolute(value) &&
          !path.windows.isAbsolute(value) &&
          !path.posix.isAbsolute(value)) {
        continue;
      }
      final candidate = path.canonicalize(path.absolute(value));
      final isInside = path.isWithin(root, candidate);
      final replacement = isInside
          ? path.relative(candidate, from: root)
          : '${row['id']}${path.extension(value)}';
      await db.update(
        'attachments',
        <String, Object?>{
          'relative_path': replacement,
          if (!isInside) 'payload_available': 0,
          if (!isInside) 'needs_manual_resend': 1,
        },
        where: 'id = ?',
        whereArgs: <Object?>[row['id']],
      );
    }
  }

  Future<String> resolveAttachmentPath(String relativePath) async {
    final attachmentsDir = await ensureAttachmentsDirectory();
    return _resolveAttachmentPathInsideDirectory(
      attachmentsDir: attachmentsDir,
      relativePath: relativePath,
    );
  }

  Future<void> writeAttachmentBytes(
    String relativePath,
    List<int> bytes,
  ) async {
    final target = File(await resolveAttachmentPath(relativePath));
    final parent = target.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    await target.writeAsBytes(bytes, flush: true);
  }

  String _resolveAttachmentPathInsideDirectory({
    required String attachmentsDir,
    required String relativePath,
  }) {
    final segments = _validateAttachmentRelativePath(relativePath);
    final rootPath = path.canonicalize(path.absolute(attachmentsDir));
    final targetPath = path.normalize(path.joinAll(<String>[
      rootPath,
      ...segments,
    ]));
    final relativeToRoot = path.relative(targetPath, from: rootPath);
    if (relativeToRoot == '.' ||
        relativeToRoot.startsWith('..${path.separator}') ||
        relativeToRoot == '..' ||
        path.isAbsolute(relativeToRoot)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        '附件路径必须位于聊天附件目录内',
      );
    }
    return targetPath;
  }

  List<String> _validateAttachmentRelativePath(String relativePath) {
    final value = relativePath.trim();
    if (value.isEmpty ||
        value.contains('\u0000') ||
        path.isAbsolute(value) ||
        path.windows.isAbsolute(value) ||
        path.posix.isAbsolute(value)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        '附件路径必须是非空相对路径',
      );
    }

    final normalizedSeparators = value.replaceAll('\\', '/');
    final segments = normalizedSeparators.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains(':'),
    )) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        '附件路径包含非法片段',
      );
    }
    return segments;
  }

  Future<void> recordSyncCheckpoint({
    required String peerKey,
    required String hallId,
    int? timestampEpochMs,
  }) async {
    final db = await _ensureDatabase();
    final timestamp = timestampEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'sync_checkpoints',
      {
        'peer_key': peerKey,
        'hall_id': hallId,
        'last_sync_at': timestamp,
        'updated_at': timestamp,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, int>> loadSyncCheckpoints() async {
    final db = await _ensureDatabase();
    final rows = await db.query('sync_checkpoints');
    final result = <String, int>{};
    for (final row in rows) {
      result[(row['peer_key'] ?? '').toString()] =
          int.tryParse('${row['last_sync_at']}') ?? 0;
    }
    return result;
  }
}

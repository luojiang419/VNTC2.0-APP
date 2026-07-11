import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;
  late String attachmentDirPath;
  final openedStorages = <ChatStorage>[];

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('vnt_chat_storage_test_');
    dbPath = path.join(tempDir.path, 'chat.db');
    attachmentDirPath = path.join(tempDir.path, 'attachments');
  });

  tearDown(() async {
    for (final storage in openedStorages) {
      await storage.close();
    }
    openedStorages.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('会话、消息、房间记录可持久化恢复', () async {
    final storage = ChatStorage(
      databasePath: dbPath,
      attachmentsDirectoryPath: attachmentDirPath,
    );
    openedStorages.add(storage);
    await storage.init();

    const conversation = ChatConversation(
      id: 'dm:hall:test:10.0.0.2',
      type: ChatConversationType.direct,
      hallId: 'hall:test',
      title: '测试私聊',
      unreadCount: 0,
      lastReadAtEpochMs: 0,
      lastMessageAtEpochMs: 1717286400000,
      updatedAtEpochMs: 1717286400000,
      metadataJson: '{}',
      peerVirtualIp: '10.0.0.2',
      peerDisplayName: '设备 B',
    );
    await storage.upsertConversation(conversation);

    const room = ChatRoomDescriptor(
      roomId: 'room:hall:test:10.0.0.1:abc',
      hallId: 'hall:test',
      roomName: '临时会议室',
      creatorVirtualIp: '10.0.0.1',
      locallyJoined: true,
      isActive: true,
      lastSeenAtEpochMs: 1717286400000,
      updatedAtEpochMs: 1717286400000,
    );
    await storage.upsertRoomDescriptor(room);

    const message = ChatMessageRecord(
      id: 'msg-1',
      conversationId: 'dm:hall:test:10.0.0.2',
      hallId: 'hall:test',
      conversationType: ChatConversationType.direct,
      senderVirtualIp: '10.0.0.2',
      senderName: '设备 B',
      senderSeq: 1,
      direction: ChatMessageDirection.incoming,
      contentType: ChatMessageContentType.text,
      status: ChatMessageStatus.sent,
      text: '你好',
      isSyncMessage: false,
      isRead: false,
      sentAtEpochMs: 1717286401000,
      createdAtEpochMs: 1717286401000,
      metadataJson: '{}',
      peerVirtualIp: '10.0.0.2',
    );
    await storage.upsertMessage(message, incrementUnread: true);

    final reopened = ChatStorage(
      databasePath: dbPath,
      attachmentsDirectoryPath: attachmentDirPath,
    );
    openedStorages.add(reopened);
    await reopened.init();

    final conversations = await reopened.loadConversations();
    final rooms = await reopened.loadRoomDescriptors();
    final messages = await reopened.loadMessages(message.conversationId);
    final unread = await reopened.loadPrivateUnreadTotal();

    expect(conversations, hasLength(1));
    expect(conversations.first.title, '测试私聊');
    expect(conversations.first.unreadCount, 1);
    expect(rooms, hasLength(1));
    expect(rooms.first.roomName, '临时会议室');
    expect(messages, hasLength(1));
    expect(messages.first.text, '你好');
    expect(unread, 1);

    await reopened.markConversationRead(message.conversationId);

    final afterRead = await reopened.getConversation(message.conversationId);
    final unreadAfterRead = await reopened.loadPrivateUnreadTotal();
    expect(afterRead?.unreadCount, 0);
    expect(unreadAfterRead, 0);
  });

  test('重复私聊会话可合并到规范会话并保留消息', () async {
    final storage = ChatStorage(
      databasePath: dbPath,
      attachmentsDirectoryPath: attachmentDirPath,
    );
    openedStorages.add(storage);
    await storage.init();

    const legacyId = 'dm:hall:tcp://server:2225|net:10.0.0.1|10.0.0.2';
    const canonicalId = 'dm:hall:server:2225|net:10.0.0.1|10.0.0.2';
    const legacyConversation = ChatConversation(
      id: legacyId,
      type: ChatConversationType.direct,
      hallId: 'hall:tcp://server:2225|net',
      title: '设备 B',
      unreadCount: 1,
      lastReadAtEpochMs: 0,
      lastMessageAtEpochMs: 1717286401000,
      updatedAtEpochMs: 1717286401000,
      metadataJson: '{}',
      peerVirtualIp: '10.0.0.2',
      peerDisplayName: '设备 B',
    );
    await storage.upsertConversation(legacyConversation);
    await storage.upsertMessage(
      const ChatMessageRecord(
        id: 'legacy-msg',
        conversationId: legacyId,
        hallId: 'hall:tcp://server:2225|net',
        conversationType: ChatConversationType.direct,
        senderVirtualIp: '10.0.0.2',
        senderName: '设备 B',
        senderSeq: 1,
        direction: ChatMessageDirection.incoming,
        contentType: ChatMessageContentType.text,
        status: ChatMessageStatus.sent,
        text: '回复消息',
        isSyncMessage: false,
        isRead: false,
        sentAtEpochMs: 1717286401000,
        createdAtEpochMs: 1717286401000,
        metadataJson: '{}',
        peerVirtualIp: '10.0.0.2',
      ),
      incrementUnread: true,
    );

    await storage.mergeConversationAlias(
      sourceConversationId: legacyId,
      targetConversation: const ChatConversation(
        id: canonicalId,
        type: ChatConversationType.direct,
        hallId: 'hall:server:2225|net',
        title: '设备 B',
        unreadCount: 0,
        lastReadAtEpochMs: 0,
        lastMessageAtEpochMs: 0,
        updatedAtEpochMs: 1717286402000,
        metadataJson: '{}',
        peerVirtualIp: '10.0.0.2',
        peerDisplayName: '设备 B',
      ),
    );

    expect(await storage.getConversation(legacyId), isNull);
    final merged = await storage.getConversation(canonicalId);
    expect(merged, isNotNull);
    expect(merged?.unreadCount, 1);
    final messages = await storage.loadMessages(canonicalId);
    expect(messages.map((message) => message.text), contains('回复消息'));
    expect(messages.single.hallId, 'hall:server:2225|net');
  });

  test('附件路径必须限制在附件目录内', () async {
    final storage = ChatStorage(
      databasePath: dbPath,
      attachmentsDirectoryPath: attachmentDirPath,
    );
    openedStorages.add(storage);
    await storage.init();

    await expectLater(
      storage.resolveAttachmentPath('../outside.txt'),
      throwsArgumentError,
    );
    await expectLater(
      storage.resolveAttachmentPath(r'..\outside.txt'),
      throwsArgumentError,
    );
    await expectLater(
      storage.resolveAttachmentPath(path.join(tempDir.path, 'outside.txt')),
      throwsArgumentError,
    );
    await expectLater(
      storage.writeAttachmentBytes('../outside.txt', <int>[1, 2, 3]),
      throwsArgumentError,
    );

    final outsideFile = File(path.join(tempDir.path, 'outside.txt'));
    expect(await outsideFile.exists(), isFalse);
  });

  test('合法附件路径仍可写入并解析到附件目录内', () async {
    final storage = ChatStorage(
      databasePath: dbPath,
      attachmentsDirectoryPath: attachmentDirPath,
    );
    openedStorages.add(storage);
    await storage.init();

    await storage.writeAttachmentBytes('nested/sample.txt', <int>[1, 2, 3]);

    final resolved = await storage.resolveAttachmentPath('nested/sample.txt');
    expect(path.isWithin(attachmentDirPath, resolved), isTrue);
    expect(await File(resolved).readAsBytes(), <int>[1, 2, 3]);
  });

  group('默认聊天室存储目录', () {
    test('macOS 类平台使用应用支持目录，避免写入根目录 /config', () {
      final resolved =
          ChatStorage.resolveDefaultChatRootDirectoryPathForPlatform(
        useApplicationSupportDirectory: true,
        applicationSupportDirectoryPath:
            path.join('/Users/test/Library/Application Support', 'vnt_app'),
        configDirectoryPath: path.join(path.separator, 'config'),
      );

      expect(
        resolved,
        path.join(
          '/Users/test/Library/Application Support',
          'vnt_app',
          'chat',
        ),
      );
      expect(resolved, isNot(path.join(path.separator, 'config', 'chat')));
    });

    test('Windows 便携式场景继续使用 config 目录', () {
      final resolved =
          ChatStorage.resolveDefaultChatRootDirectoryPathForPlatform(
        useApplicationSupportDirectory: false,
        applicationSupportDirectoryPath:
            path.join('/Users/test/Library/Application Support', 'vnt_app'),
        configDirectoryPath: path.windows.join(
          r'C:\Apps\VNT App 2.0',
          'config',
        ),
      );

      expect(
        resolved,
        path.join(path.windows.join(r'C:\Apps\VNT App 2.0', 'config'), 'chat'),
      );
    });
  });
}

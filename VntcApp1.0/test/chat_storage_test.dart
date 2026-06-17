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
}

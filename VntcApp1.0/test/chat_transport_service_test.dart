import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_security.dart';
import 'package:vnt_app/chat/chat_transport_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('私聊会话ID在双方视角下保持一致', () {
    final left = buildDirectConversationId(
      hallId: 'hall:test',
      firstVirtualIp: '10.0.0.1',
      secondVirtualIp: '10.0.0.2',
    );
    final right = buildDirectConversationId(
      hallId: 'hall:test',
      firstVirtualIp: '10.0.0.2',
      secondVirtualIp: '10.0.0.1',
    );

    expect(left, right);
  });

  test('私聊会话ID会归一化虚拟IP格式差异', () {
    final left = buildDirectConversationId(
      hallId: 'hall:test',
      firstVirtualIp: ' 10.0.0.1 ',
      secondVirtualIp: '[FD00::2]',
    );
    final right = buildDirectConversationId(
      hallId: 'hall:test',
      firstVirtualIp: 'fd00::2',
      secondVirtualIp: '10.0.0.1',
    );

    expect(left, right);
  });

  test('聊天身份校验要求远端地址与声明虚拟IP一致', () {
    expect(
      isChatRemoteAddressConsistent(
        remoteAddress: '10.0.0.2',
        declaredVirtualIp: '10.0.0.2',
      ),
      isTrue,
    );
    expect(
      isChatRemoteAddressConsistent(
        remoteAddress: '10.0.0.3',
        declaredVirtualIp: '10.0.0.2',
      ),
      isFalse,
    );
    expect(
      isChatRemoteAddressConsistent(
        remoteAddress: '10.0.0.3',
        declaredVirtualIp: '',
      ),
      isFalse,
    );
  });

  test('聊天室大厅ID忽略传输协议差异', () {
    final tcpHallId = buildHallId(
      connectServer: 'tcp://115.231.35.105:2225',
      virtualNetwork: '10.10.10.0',
    );
    final quicHallId = buildHallId(
      connectServer: 'quic://115.231.35.105:2225',
      virtualNetwork: '10.10.10.0',
    );

    expect(tcpHallId, quicHallId);
    expect(tcpHallId, 'hall:115.231.35.105:2225|10.10.10.0');
  });

  test('动态地址与txt前缀会归一化到同一大厅ID', () {
    final txtHallId = buildHallId(
      connectServer: 'txt:115.231.35.105:2225',
      virtualNetwork: '10.10.10.0',
    );
    final dynamicHallId = buildHallId(
      connectServer: 'dynamic://115.231.35.105:2225',
      virtualNetwork: '10.10.10.0',
    );

    expect(txtHallId, dynamicHallId);
    expect(txtHallId, 'hall:115.231.35.105:2225|10.10.10.0');
  });

  test('旧大厅ID可归一化为跨平台稳定ID', () {
    expect(
      normalizeChatHallId('hall:tcp://115.231.35.105:2225|10.10.10.0'),
      'hall:115.231.35.105:2225|10.10.10.0',
    );
    expect(
      normalizeChatHallId('hall:quic://115.231.35.105:2225|10.10.10.0'),
      'hall:115.231.35.105:2225|10.10.10.0',
    );
    expect(
      buildDirectConversationId(
        hallId: 'hall:quic://115.231.35.105:2225|10.10.10.0',
        firstVirtualIp: '10.10.10.6',
        secondVirtualIp: '10.10.10.2',
      ),
      'dm:hall:115.231.35.105:2225|10.10.10.0:10.10.10.2|10.10.10.6',
    );
    expect(
      buildLegacyDirectConversationId(
        hallId: 'hall:quic://115.231.35.105:2225|10.10.10.0',
        firstVirtualIp: '10.10.10.6',
        secondVirtualIp: '10.10.10.2',
      ),
      'dm:hall:quic://115.231.35.105:2225|10.10.10.0:10.10.10.2|10.10.10.6',
    );
    expect(
      buildLegacyRoomId(
        hallId: 'hall:quic://115.231.35.105:2225|10.10.10.0',
        creatorVirtualIp: '10.10.10.6',
        roomToken: 'room-token',
      ),
      'room:hall:quic://115.231.35.105:2225|10.10.10.0:10.10.10.6:room-token',
    );
  });

  test('旧版大厅兼容候选覆盖常见协议别名', () {
    final candidates = buildLegacyChatHallIdCandidates(
      connectServer: 'quic://115.231.35.105:2225',
      virtualNetwork: '10.10.10.0',
    );

    expect(
      candidates,
      contains('hall:quic://115.231.35.105:2225|10.10.10.0'),
    );
    expect(
      candidates,
      contains('hall:tcp://115.231.35.105:2225|10.10.10.0'),
    );
    expect(
      candidates,
      contains('hall:udp://115.231.35.105:2225|10.10.10.0'),
    );
    expect(
      candidates,
      contains('hall:wss://115.231.35.105:2225|10.10.10.0'),
    );
    expect(
      candidates,
      contains('hall:dynamic://115.231.35.105:2225|10.10.10.0'),
    );
    expect(
      candidates,
      contains('hall:txt:115.231.35.105:2225|10.10.10.0'),
    );
  });

  test('聊天TCP传输服务可以收发文本消息', () async {
    final service = ChatTransportService();
    final completer = Completer<ChatTransportPacket>();

    await service.start(
      onPacket: (packet, remoteAddress) async {
        if (!completer.isCompleted) {
          completer.complete(packet);
        }
      },
      listenPort: 0,
    );
    final port = service.listeningPort;
    expect(port, isNotNull);

    const packet = ChatTransportPacket(
      type: 'message',
      message: ChatMessageRecord(
        id: 'msg-transport-1',
        conversationId: 'hall:test',
        hallId: 'hall:test',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '127.0.0.1',
        senderName: '本机',
        senderSeq: 1,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.text,
        status: ChatMessageStatus.sent,
        text: 'transport ok',
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1717286401000,
        createdAtEpochMs: 1717286401000,
        metadataJson: '{}',
      ),
    );

    try {
      await service.sendPacket(
        targetIp: InternetAddress.loopbackIPv4.address,
        packet: packet,
        port: port,
      );
      final received =
          await completer.future.timeout(const Duration(seconds: 3));
      expect(received.type, 'message');
      expect(received.message?.text, 'transport ok');
    } finally {
      await service.stop();
    }
  });

  test('聊天TCP传输服务可以携带附件负载', () async {
    final service = ChatTransportService();
    final completer = Completer<ChatTransportPacket>();

    await service.start(
      onPacket: (packet, remoteAddress) async {
        if (!completer.isCompleted) {
          completer.complete(packet);
        }
      },
      listenPort: 0,
    );
    final port = service.listeningPort;
    expect(port, isNotNull);

    const packet = ChatTransportPacket(
      type: 'message',
      message: ChatMessageRecord(
        id: 'msg-transport-attachment',
        conversationId: 'hall:test',
        hallId: 'hall:test',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '127.0.0.1',
        senderName: '本机',
        senderSeq: 2,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.file,
        status: ChatMessageStatus.sent,
        text: 'sample.txt',
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1717286402000,
        createdAtEpochMs: 1717286402000,
        metadataJson: '{}',
        attachmentId: 'att-1',
        attachment: ChatAttachmentRecord(
          id: 'att-1',
          messageId: 'msg-transport-attachment',
          fileName: 'sample.txt',
          mimeType: 'text/plain',
          sizeBytes: 11,
          relativePath: 'sample.txt',
          autoSyncEligible: true,
          payloadAvailable: true,
          needsManualResend: false,
          createdAtEpochMs: 1717286402000,
        ),
      ),
      attachmentBase64: 'aGVsbG8gd29ybGQ=',
    );

    try {
      await service.sendPacket(
        targetIp: InternetAddress.loopbackIPv4.address,
        packet: packet,
        port: port,
      );
      final received =
          await completer.future.timeout(const Duration(seconds: 3));
      expect(received.message?.attachment?.fileName, 'sample.txt');
      expect(received.attachmentBase64, 'aGVsbG8gd29ybGQ=');
    } finally {
      await service.stop();
    }
  });

  test('聊天TCP传输服务拒绝超过上限的报文', () async {
    final service = ChatTransportService(maxPacketBytes: 128);
    var handled = false;

    await service.start(
      onPacket: (packet, remoteAddress) async {
        handled = true;
      },
      listenPort: 0,
    );
    final port = service.listeningPort;
    expect(port, isNotNull);

    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port!);
      final oversizedPacket = ChatTransportPacket(
        type: 'message',
        message: ChatMessageRecord(
          id: 'msg-oversized',
          conversationId: 'hall:test',
          hallId: 'hall:test',
          conversationType: ChatConversationType.hall,
          senderVirtualIp: '127.0.0.1',
          senderName: '本机',
          senderSeq: 3,
          direction: ChatMessageDirection.outgoing,
          contentType: ChatMessageContentType.text,
          status: ChatMessageStatus.sent,
          text: List<String>.filled(256, 'x').join(),
          isSyncMessage: false,
          isRead: true,
          sentAtEpochMs: 1717286403000,
          createdAtEpochMs: 1717286403000,
          metadataJson: '{}',
        ),
      );
      socket.add(utf8.encode(oversizedPacket.toJsonLine()));
      await socket.flush();
      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(handled, isFalse);
    } finally {
      socket?.destroy();
      await service.stop();
    }
  });

  test('聊天TCP传输服务会关闭读取超时的连接', () async {
    final service = ChatTransportService(
      readTimeout: const Duration(milliseconds: 100),
    );
    var handled = false;

    await service.start(
      onPacket: (packet, remoteAddress) async {
        handled = true;
      },
      listenPort: 0,
    );
    final port = service.listeningPort;
    expect(port, isNotNull);

    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port!);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(handled, isFalse);
    } finally {
      socket?.destroy();
      await service.stop();
    }
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';
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
      final received = await completer.future.timeout(const Duration(seconds: 3));
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
      final received = await completer.future.timeout(const Duration(seconds: 3));
      expect(received.message?.attachment?.fileName, 'sample.txt');
      expect(received.attachmentBase64, 'aGVsbG8gd29ybGQ=');
    } finally {
      await service.stop();
    }
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test('同一服务器和同一子网忽略本机地址与配置名称差异', () {
    final firstHallId = buildHallId(
      connectServer: 'quic://115.231.35.105:2225',
      virtualNetwork: '10.10.10.4',
      virtualNetmask: '255.255.255.0',
    );
    final secondHallId = buildHallId(
      connectServer: 'tcp://115.231.35.105:2225',
      virtualNetwork: '10.10.10.200',
      virtualNetmask: '255.255.255.0',
    );

    expect(firstHallId, secondHallId);
    expect(firstHallId, 'hall:115.231.35.105:2225|10.10.10.0');
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

  test('聊天TCP传输服务会分块回报发送进度', () async {
    final service = ChatTransportService();
    final completer = Completer<ChatTransportPacket>();
    final progressUpdates = <({int sentBytes, int totalBytes})>[];

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

    final packet = ChatTransportPacket(
      type: 'message',
      message: ChatMessageRecord(
        id: 'msg-transport-progress',
        conversationId: 'hall:test',
        hallId: 'hall:test',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '127.0.0.1',
        senderName: '本机',
        senderSeq: 2,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.text,
        status: ChatMessageStatus.sent,
        text: List<String>.filled(256 * 1024, 'x').join(),
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1717286402000,
        createdAtEpochMs: 1717286402000,
        metadataJson: '{}',
      ),
    );

    try {
      await service.sendPacket(
        targetIp: InternetAddress.loopbackIPv4.address,
        packet: packet,
        port: port,
        onProgress: (sentBytes, totalBytes) {
          progressUpdates.add((
            sentBytes: sentBytes,
            totalBytes: totalBytes,
          ));
        },
      );
      await completer.future.timeout(const Duration(seconds: 3));

      expect(progressUpdates.length, greaterThan(1));
      expect(progressUpdates.last.sentBytes, progressUpdates.last.totalBytes);
    } finally {
      await service.stop();
    }
  });

  test('聊天TCP传输服务可以直接传输二进制附件流', () async {
    final service = ChatTransportService();
    final completer = Completer<ChatTransportPacket>();
    final streamClosed = Completer<void>();
    final receivedBytes = BytesBuilder(copy: false)..add(<int>[0, 1]);

    await service.start(
      onPacket: (packet, remoteAddress) async {
        if (!completer.isCompleted) {
          completer.complete(packet);
        }
      },
      onAttachmentStream: (packet, remoteAddress) async {
        if (!completer.isCompleted) {
          completer.complete(packet);
        }
        return _MemoryAttachmentStreamSink(
          receivedBytes,
          resumeOffset: 2,
          onClose: () => streamClosed.complete(),
        );
      },
      listenPort: 0,
    );
    final port = service.listeningPort;
    expect(port, isNotNull);

    const packet = ChatTransportPacket(
      type: 'attachment_stream',
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
          sizeBytes: 5,
          relativePath: 'sample.txt',
          autoSyncEligible: true,
          payloadAvailable: true,
          needsManualResend: false,
          createdAtEpochMs: 1717286402000,
        ),
      ),
    );

    try {
      await service.sendAttachmentStream(
        targetIp: InternetAddress.loopbackIPv4.address,
        packet: packet,
        sourceFactory: (startOffset) {
          expect(startOffset, 2);
          return Stream<List<int>>.value(<int>[2, 3, 255]);
        },
        totalBytes: 5,
        port: port,
      );
      final received =
          await completer.future.timeout(const Duration(seconds: 3));
      await streamClosed.future.timeout(const Duration(seconds: 3));
      expect(received.message?.attachment?.fileName, 'sample.txt');
      expect(receivedBytes.toBytes(), <int>[0, 1, 2, 3, 255]);
    } finally {
      await service.stop();
    }
  });

  test('同一目标和消息的并发附件发送会复用同一个传输任务', () async {
    final service = ChatTransportService();
    var receivedTransferCount = 0;
    await service.start(
      onPacket: (packet, remoteAddress) async {},
      onAttachmentStream: (packet, remoteAddress) async {
        receivedTransferCount += 1;
        return _MemoryAttachmentStreamSink(
          BytesBuilder(copy: false),
          resumeOffset: 0,
          onClose: () {},
        );
      },
      listenPort: 0,
    );
    final port = service.listeningPort!;
    const packet = ChatTransportPacket(
      type: 'attachment_stream',
      message: ChatMessageRecord(
        id: 'same-message',
        conversationId: 'hall:test',
        hallId: 'hall:test',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '127.0.0.1',
        senderName: '本机',
        senderSeq: 3,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.file,
        status: ChatMessageStatus.sent,
        text: 'sample.bin',
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1717286403000,
        createdAtEpochMs: 1717286403000,
        metadataJson: '{}',
        attachmentId: 'same-attachment',
        attachment: ChatAttachmentRecord(
          id: 'same-attachment',
          messageId: 'same-message',
          fileName: 'sample.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 3,
          relativePath: 'sample.bin',
          autoSyncEligible: true,
          payloadAvailable: true,
          needsManualResend: false,
          createdAtEpochMs: 1717286403000,
        ),
      ),
    );

    try {
      await Future.wait(<Future<void>>[
        service.sendAttachmentStream(
          targetIp: InternetAddress.loopbackIPv4.address,
          packet: packet,
          sourceFactory: (_) => Stream<List<int>>.value(<int>[1, 2, 3]),
          totalBytes: 3,
          port: port,
        ),
        service.sendAttachmentStream(
          targetIp: InternetAddress.loopbackIPv4.address,
          packet: packet,
          sourceFactory: (_) => Stream<List<int>>.value(<int>[1, 2, 3]),
          totalBytes: 3,
          port: port,
        ),
      ]);
      expect(receivedTransferCount, 1);
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

class _MemoryAttachmentStreamSink implements ChatAttachmentStreamSink {
  _MemoryAttachmentStreamSink(
    this._bytes, {
    required this.resumeOffset,
    required this.onClose,
  });

  final BytesBuilder _bytes;
  final void Function() onClose;

  @override
  final int resumeOffset;

  @override
  Future<void> abort() async {}

  @override
  Future<void> add(List<int> bytes) async {
    _bytes.add(bytes);
  }

  @override
  Future<void> close() async => onClose();
}

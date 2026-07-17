import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_constants.dart';
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

  test('聊天传输服务会并行探测候选端口并缓存可用端口', () async {
    final receiver = ChatTransportService();
    await receiver.start(
      onPacket: (packet, remoteAddress) async {},
      listenPort: 0,
    );
    final availablePort = receiver.listeningPort!;
    final temporaryListener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final unavailablePort = temporaryListener.port;
    await temporaryListener.close();
    final resolver = ChatTransportService(
      connectTimeout: const Duration(milliseconds: 200),
      transportPortCandidates: <int>[unavailablePort, availablePort],
    );

    try {
      final resolvedPort = await resolver.resolveTransportPort(
        targetIp: InternetAddress.loopbackIPv4.address,
      );

      expect(resolvedPort, availablePort);
      expect(
        resolver.cachedTransportPortFor(
          InternetAddress.loopbackIPv4.address,
        ),
        availablePort,
      );
    } finally {
      await receiver.stop();
    }
  });

  test('聊天传输端口缓存只接受受支持的候选端口', () {
    final service = ChatTransportService(
      transportPortCandidates: const <int>[61019, 50019],
    );

    service.rememberTransportPort('10.0.0.2', 12345);
    expect(service.cachedTransportPortFor('10.0.0.2'), isNull);

    service.rememberTransportPort('10.0.0.2', 50019);
    expect(service.cachedTransportPortFor('10.0.0.2'), 50019);
    service.invalidateTransportPort('10.0.0.2', 50019);
    expect(service.cachedTransportPortFor('10.0.0.2'), isNull);
  });

  test('失败端口进入冷却且用户发送可以强制快速复探', () async {
    final firstTemporaryListener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final firstUnavailablePort = firstTemporaryListener.port;
    await firstTemporaryListener.close();
    final secondTemporaryListener = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final recoveredPort = secondTemporaryListener.port;
    await secondTemporaryListener.close();
    final service = ChatTransportService(
      connectTimeout: const Duration(milliseconds: 200),
      probeRetryDelay: const Duration(minutes: 1),
      transportPortCandidates: <int>[
        firstUnavailablePort,
        recoveredPort,
      ],
    );

    expect(
      await service.resolveTransportPort(
        targetIp: InternetAddress.loopbackIPv4.address,
      ),
      isNull,
    );
    expect(
      service.isTransportProbeCoolingDown(
        InternetAddress.loopbackIPv4.address,
      ),
      isTrue,
    );

    final receiver = ChatTransportService();
    await receiver.start(
      onPacket: (packet, remoteAddress) async {},
      listenPort: recoveredPort,
    );
    try {
      expect(
        await service.resolveTransportPort(
          targetIp: InternetAddress.loopbackIPv4.address,
        ),
        isNull,
      );
      expect(
        await service.resolveTransportPort(
          targetIp: InternetAddress.loopbackIPv4.address,
          retryUnavailable: true,
        ),
        recoveredPort,
      );
    } finally {
      await receiver.stop();
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

  test('附件测速按全部接收方的实际网络字节计算', () {
    final sample = calculateAttachmentTransferSample(
      fileBytes: 1024 * 1024,
      recipientIndex: 2,
      recipientCount: 5,
      recipientSentBytes: 512 * 1024,
      elapsedMilliseconds: 2500,
    );

    expect(sample.totalBytes, 5 * 1024 * 1024);
    expect(sample.transferredBytes, 2 * 1024 * 1024 + 512 * 1024);
    expect(sample.bytesPerSecond, 1024 * 1024);
  });

  test('附件测速在私聊中保持单连接吞吐', () {
    final sample = calculateAttachmentTransferSample(
      fileBytes: 1024 * 1024,
      recipientIndex: 0,
      recipientCount: 1,
      recipientSentBytes: 1024 * 1024,
      elapsedMilliseconds: 2000,
    );

    expect(sample.totalBytes, 1024 * 1024);
    expect(sample.transferredBytes, 1024 * 1024);
    expect(sample.bytesPerSecond, 512 * 1024);
  });

  test('附件进度限制刷新频率但不会延迟最终进度', () {
    expect(
      shouldPublishAttachmentProgress(
        sentBytes: 64 * 1024,
        totalBytes: 1024 * 1024,
        elapsedMilliseconds: 199,
        lastPublishedElapsedMilliseconds: 0,
        minimumInterval: ChatConstants.attachmentProgressUpdateInterval,
      ),
      isFalse,
    );
    expect(
      shouldPublishAttachmentProgress(
        sentBytes: 128 * 1024,
        totalBytes: 1024 * 1024,
        elapsedMilliseconds: 200,
        lastPublishedElapsedMilliseconds: 0,
        minimumInterval: ChatConstants.attachmentProgressUpdateInterval,
      ),
      isTrue,
    );
    expect(
      shouldPublishAttachmentProgress(
        sentBytes: 1024 * 1024,
        totalBytes: 1024 * 1024,
        elapsedMilliseconds: 1,
        lastPublishedElapsedMilliseconds: 0,
        minimumInterval: ChatConstants.attachmentProgressUpdateInterval,
      ),
      isTrue,
    );
  });

  test('大附件在本机TCP链路保持高吞吐', () async {
    const totalBytes = 8 * 1024 * 1024;
    const chunkBytes = 256 * 1024;
    final service = ChatTransportService();
    final sink = _CountingAttachmentStreamSink();
    await service.start(
      onPacket: (packet, remoteAddress) async {},
      onAttachmentStream: (packet, remoteAddress) async => sink,
      listenPort: 0,
    );
    const packet = ChatTransportPacket(
      type: 'attachment_stream',
      message: ChatMessageRecord(
        id: 'large-throughput-message',
        conversationId: 'hall:test',
        hallId: 'hall:test',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '127.0.0.1',
        senderName: '本机',
        senderSeq: 4,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.file,
        status: ChatMessageStatus.sent,
        text: 'large.bin',
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1717286404000,
        createdAtEpochMs: 1717286404000,
        metadataJson: '{}',
      ),
    );
    final chunk = Uint8List(chunkBytes);
    final chunks = List<List<int>>.filled(totalBytes ~/ chunkBytes, chunk);
    final stopwatch = Stopwatch()..start();

    try {
      await service.sendAttachmentStream(
        targetIp: InternetAddress.loopbackIPv4.address,
        packet: packet,
        sourceFactory: (_) => Stream<List<int>>.fromIterable(chunks),
        totalBytes: totalBytes,
        port: service.listeningPort,
      );
      stopwatch.stop();
      final bytesPerSecond =
          totalBytes * 1000 ~/ stopwatch.elapsedMilliseconds.clamp(1, 1 << 31);

      expect(sink.receivedBytes, totalBytes);
      expect(
        bytesPerSecond,
        greaterThan(1024 * 1024),
        reason: '本机附件流吞吐过低: $bytesPerSecond B/s',
      );
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

class _CountingAttachmentStreamSink implements ChatAttachmentStreamSink {
  int receivedBytes = 0;

  @override
  int get resumeOffset => 0;

  @override
  Future<void> abort() async {}

  @override
  Future<void> add(List<int> bytes) async {
    receivedBytes += bytes.length;
  }

  @override
  Future<void> close() async {}
}

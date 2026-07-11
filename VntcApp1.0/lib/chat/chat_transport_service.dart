import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vnt_app/chat/chat_log.dart';
import 'package:vnt_app/chat/chat_constants.dart';
import 'package:vnt_app/chat/chat_models.dart';

typedef ChatPacketHandler = Future<void> Function(
  ChatTransportPacket packet,
  InternetAddress remoteAddress,
);

typedef ChatPacketProgressCallback = void Function(
  int sentBytes,
  int totalBytes,
);

abstract interface class ChatAttachmentStreamSink {
  int get resumeOffset;
  Future<void> add(List<int> bytes);
  Future<void> close();
  Future<void> abort();
}

typedef ChatAttachmentStreamHandler = Future<ChatAttachmentStreamSink?>
    Function(
  ChatTransportPacket packet,
  InternetAddress remoteAddress,
);

class ChatTransportService {
  ChatTransportService({
    int? maxPacketBytes,
    Duration? readTimeout,
  })  : _maxPacketBytes =
            maxPacketBytes ?? ChatConstants.maxTransportPacketBytes,
        _readTimeout = readTimeout ?? ChatConstants.transportReadTimeout;

  final int _maxPacketBytes;
  final Duration _readTimeout;
  ServerSocket? _server;
  ChatPacketHandler? _handler;
  ChatAttachmentStreamHandler? _attachmentStreamHandler;
  final Map<String, _AttachmentAcknowledgementWaiter>
      _attachmentAcknowledgements = {};
  final Map<String, Future<void>> _attachmentTransfers = {};

  bool get isRunning => _server != null;
  int? get listeningPort => _server?.port;

  String _attachmentAcknowledgementKey(String targetIp, String messageId) =>
      '$targetIp|$messageId';

  Future<void> start({
    required ChatPacketHandler onPacket,
    ChatAttachmentStreamHandler? onAttachmentStream,
    int? listenPort,
  }) async {
    _handler = onPacket;
    _attachmentStreamHandler = onAttachmentStream;
    if (_server != null) {
      return;
    }
    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        listenPort ?? ChatConstants.transportPort,
        shared: true,
      );
      await ChatLog.write(
        '聊天 TCP 监听已启动 address=${_server!.address.address} port=${_server!.port}',
      );
      _server!.listen(_handleClient);
    } catch (error) {
      await ChatLog.write('聊天 TCP 监听启动失败: $error');
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
    await ChatLog.write('聊天 TCP 监听已停止');
  }

  Future<void> sendPacket({
    required String targetIp,
    required ChatTransportPacket packet,
    int? port,
    ChatPacketProgressCallback? onProgress,
  }) async {
    await ChatLog.write(
      '发送聊天报文 type=${packet.type} target=$targetIp port=${port ?? ChatConstants.transportPort}',
    );
    final payload = utf8.encode(packet.toJsonLine());
    final socket = await Socket.connect(
      targetIp,
      port ?? ChatConstants.transportPort,
    );
    try {
      var sentBytes = 0;
      const writeChunkBytes = 64 * 1024;
      while (sentBytes < payload.length) {
        final nextOffset = (sentBytes + writeChunkBytes)
            .clamp(
              0,
              payload.length,
            )
            .toInt();
        socket.add(payload.sublist(sentBytes, nextOffset));
        await socket.flush();
        sentBytes = nextOffset;
        onProgress?.call(sentBytes, payload.length);
      }
    } finally {
      await socket.close();
    }
  }

  Future<void> sendAttachmentStream({
    required String targetIp,
    required ChatTransportPacket packet,
    required Stream<List<int>> Function(int startOffset) sourceFactory,
    required int totalBytes,
    int? port,
    ChatPacketProgressCallback? onProgress,
  }) async {
    if (packet.type != 'attachment_stream') {
      throw ArgumentError.value(packet.type, 'packet.type', '必须是附件流报文');
    }
    final messageId = packet.message?.id;
    if (messageId == null || messageId.isEmpty) {
      throw ArgumentError('附件流缺少消息 ID');
    }
    final acknowledgementKey =
        _attachmentAcknowledgementKey(targetIp, messageId);
    final existingTransfer = _attachmentTransfers[acknowledgementKey];
    if (existingTransfer != null) {
      return existingTransfer;
    }
    final transfer = _sendAttachmentStreamOnce(
      targetIp: targetIp,
      packet: packet,
      sourceFactory: sourceFactory,
      totalBytes: totalBytes,
      port: port,
      onProgress: onProgress,
      acknowledgementKey: acknowledgementKey,
    );
    _attachmentTransfers[acknowledgementKey] = transfer;
    try {
      await transfer;
    } finally {
      if (_attachmentTransfers[acknowledgementKey] == transfer) {
        _attachmentTransfers.remove(acknowledgementKey);
      }
    }
  }

  Future<void> _sendAttachmentStreamOnce({
    required String targetIp,
    required ChatTransportPacket packet,
    required Stream<List<int>> Function(int startOffset) sourceFactory,
    required int totalBytes,
    required String acknowledgementKey,
    int? port,
    ChatPacketProgressCallback? onProgress,
  }) async {
    final acknowledgement = _AttachmentAcknowledgementWaiter();
    _attachmentAcknowledgements[acknowledgementKey] = acknowledgement;
    await ChatLog.write(
      '发送二进制附件流 target=$targetIp port=${port ?? ChatConstants.transportPort} bytes=$totalBytes',
    );
    Socket? socket;
    try {
      socket = await Socket.connect(
        targetIp,
        port ?? ChatConstants.transportPort,
      );
      final streamHeader = ChatTransportPacket(
        type: packet.type,
        message: packet.message,
        syncRequest: packet.syncRequest,
        replyPort: listeningPort ?? ChatConstants.transportPort,
      );
      socket.add(utf8.encode('${streamHeader.toJsonLine()}\n'));
      await socket.flush();
      final startOffset = await acknowledgement.resumeOffset.future.timeout(
        _readTimeout,
      );
      if (startOffset < 0 || startOffset > totalBytes) {
        throw StateError('附件续传偏移量无效 offset=$startOffset total=$totalBytes');
      }
      var sentBytes = startOffset;
      await for (final chunk in sourceFactory(startOffset)) {
        socket.add(chunk);
        await socket.flush();
        sentBytes += chunk.length;
        onProgress?.call(sentBytes, totalBytes);
      }
      if (sentBytes != totalBytes) {
        throw StateError('附件流长度不匹配 expected=$totalBytes actual=$sentBytes');
      }
      await socket.close();
      await acknowledgement.completed.future.timeout(_readTimeout);
    } finally {
      if (_attachmentAcknowledgements[acknowledgementKey] == acknowledgement) {
        _attachmentAcknowledgements.remove(acknowledgementKey);
      }
      socket?.destroy();
    }
  }

  void _handleClient(Socket socket) {
    final remoteAddress = socket.remoteAddress;
    final remoteEndpoint = '${remoteAddress.address}:${socket.remotePort}';
    final bytes = <int>[];
    Timer? readTimer;
    StreamSubscription<List<int>>? subscription;
    ChatAttachmentStreamSink? attachmentSink;
    ChatTransportPacket? attachmentStreamPacket;
    var attachmentStreamStarted = false;
    Future<void> pendingWork = Future<void>.value();
    var closedByGuard = false;

    void closeByGuard(String reason) {
      if (closedByGuard) {
        return;
      }
      closedByGuard = true;
      readTimer?.cancel();
      unawaited(subscription?.cancel());
      socket.destroy();
      unawaited(
        ChatLog.write(
          '聊天连接已关闭 remote=$remoteEndpoint reason=$reason bytes=${bytes.length}',
        ),
      );
    }

    void resetReadTimer() {
      readTimer?.cancel();
      readTimer = Timer(
        _readTimeout,
        () => closeByGuard('read_timeout'),
      );
    }

    Future<void> startAttachmentStream(int headerEndOffset) async {
      final header = utf8.decode(bytes.sublist(0, headerEndOffset));
      final decoded = jsonDecode(header);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('附件流头部不是 JSON 对象');
      }
      final packet = ChatTransportPacket.fromJson(decoded);
      if (packet.type != 'attachment_stream' || packet.message == null) {
        throw const FormatException('附件流头部无效');
      }
      final handler = _attachmentStreamHandler;
      if (handler == null) {
        throw StateError('附件流处理器未就绪');
      }
      attachmentStreamStarted = true;
      attachmentStreamPacket = packet;
      final sink = await handler(packet, remoteAddress);
      if (sink == null) {
        throw StateError('附件流被接收端拒绝');
      }
      attachmentSink = sink;
      await sendPacket(
        targetIp: remoteAddress.address,
        packet: ChatTransportPacket(
          type: 'attachment_resume',
          message: packet.message,
          transferOffset: sink.resumeOffset,
        ),
        port: packet.replyPort,
      );
      final remainingBytes = bytes.sublist(headerEndOffset + 1);
      bytes.clear();
      if (remainingBytes.isNotEmpty) {
        await attachmentSink?.add(remainingBytes);
      }
    }

    Future<void> processChunk(List<int> chunk) async {
      if (attachmentStreamStarted) {
        await attachmentSink?.add(chunk);
        return;
      }
      if (bytes.length + chunk.length > _maxPacketBytes) {
        closeByGuard('packet_too_large');
        return;
      }
      bytes.addAll(chunk);
      final headerEndOffset = bytes.indexOf(10);
      if (headerEndOffset >= 0) {
        await startAttachmentStream(headerEndOffset);
      }
    }

    resetReadTimer();
    subscription = socket.listen(
      (chunk) {
        resetReadTimer();
        pendingWork = pendingWork.then((_) => processChunk(chunk));
      },
      onDone: () async {
        readTimer?.cancel();
        try {
          await pendingWork;
          if (closedByGuard) {
            await attachmentSink?.abort();
            return;
          }
          if (attachmentStreamStarted) {
            await attachmentSink?.close();
            final acknowledgement = ChatTransportPacket(
              type: 'attachment_ack',
              message: attachmentStreamPacket?.message,
            );
            await sendPacket(
              targetIp: remoteAddress.address,
              packet: acknowledgement,
              port: attachmentStreamPacket?.replyPort,
            );
            await ChatLog.write(
              '收到二进制附件流 remote=$remoteEndpoint',
            );
            return;
          }
          final payload = utf8.decode(bytes, allowMalformed: true).trim();
          if (payload.isEmpty) {
            return;
          }
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) {
            return;
          }
          final packet = ChatTransportPacket.fromJson(decoded);
          if ((packet.type == 'attachment_resume' ||
                  packet.type == 'attachment_ack') &&
              packet.message?.id != null) {
            final acknowledgementKey = _attachmentAcknowledgementKey(
              remoteAddress.address,
              packet.message!.id,
            );
            final acknowledgement =
                _attachmentAcknowledgements[acknowledgementKey];
            if (packet.type == 'attachment_resume') {
              acknowledgement?.resumeOffset
                  .complete(packet.transferOffset ?? 0);
            } else {
              acknowledgement?.completed.complete();
            }
            return;
          }
          final handler = _handler;
          if (handler != null) {
            await ChatLog.write(
              '收到聊天报文 type=${packet.type} remote=$remoteEndpoint',
            );
            await handler(packet, remoteAddress);
          }
        } catch (error) {
          await attachmentSink?.abort();
          await ChatLog.write(
            '聊天报文解码失败 remote=$remoteEndpoint error=$error bytes=${bytes.length}',
          );
        } finally {
          await socket.close();
        }
      },
      onError: (error) async {
        readTimer?.cancel();
        await attachmentSink?.abort();
        await ChatLog.write(
          '聊天连接读取失败 remote=$remoteEndpoint error=$error',
        );
      },
      cancelOnError: true,
    );
  }
}

class _AttachmentAcknowledgementWaiter {
  final Completer<int> resumeOffset = Completer<int>();
  final Completer<void> completed = Completer<void>();
}

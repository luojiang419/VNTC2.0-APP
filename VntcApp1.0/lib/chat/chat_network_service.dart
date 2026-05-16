import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

import 'chat_logger.dart';
import 'chat_models.dart';

abstract class ChatNetworkDelegate {
  Future<void> onEnvelopeReceived({
    required String networkKey,
    required String remoteIp,
    required ChatEnvelope envelope,
  });

  Future<String?> prepareIncomingAttachmentPath({
    required String networkKey,
    required Map<String, dynamic> header,
  });

  Future<void> onAttachmentReceived({
    required String networkKey,
    required Map<String, dynamic> header,
    required String localPath,
    required int bytesReceived,
  });

  Future<void> onAttachmentFailed({
    required String networkKey,
    required Map<String, dynamic>? header,
    required Object error,
  });

  Future<void> onMediaPacketReceived({
    required String networkKey,
    required String remoteIp,
    required Map<String, dynamic> packet,
  });

  void onNetworkWarning(String networkKey, Object error,
      [StackTrace? stackTrace]);
}

class ChatBroadcastResult {
  const ChatBroadcastResult({
    required this.attemptedCount,
    required this.successCount,
    required this.failedIps,
  });

  const ChatBroadcastResult.empty()
      : attemptedCount = 0,
        successCount = 0,
        failedIps = const [];

  final int attemptedCount;
  final int successCount;
  final List<String> failedIps;

  bool get hasSuccess => successCount > 0;

  bool get hasFailures => failedIps.isNotEmpty;

  bool get allFailed => attemptedCount > 0 && successCount == 0;
}

class ChatNetworkService {
  ChatNetworkService({
    required this.networkKey,
    required this.vntBox,
    required this.delegate,
  });

  static const int controlPort = 23100;
  static const int attachmentPort = 23101;
  static const int mediaPort = 23102;
  static const Duration helloInterval = Duration(seconds: 8);

  final String networkKey;
  final VntBox vntBox;
  final ChatNetworkDelegate delegate;

  ServerSocket? _controlServer;
  ServerSocket? _attachmentServer;
  RawDatagramSocket? _mediaSocket;
  bool _started = false;
  final Map<String, DateTime> _lastHelloAt = {};
  int _mediaSentPackets = 0;
  int _mediaReceivedPackets = 0;

  String get localVirtualIp =>
      vntBox.currentDevice()['virtualIp'] as String? ?? '';

  String get localDeviceName =>
      vntBox.getNetConfig()?.deviceName ?? localVirtualIp;

  bool get isStarted => _started;

  int get mediaSentPackets => _mediaSentPackets;

  int get mediaReceivedPackets => _mediaReceivedPackets;

  static bool isRetryableStartError(Object error) {
    if (error is! SocketException) {
      return false;
    }
    final code = error.osError?.errorCode;
    if (code == 10049 || code == 99) {
      return true;
    }
    final lower =
        '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    return lower.contains('cannot assign requested address') ||
        lower.contains('requested address is not valid') ||
        lower.contains('address not available') ||
        lower.contains('请求的地址无效');
  }

  Future<void> start() async {
    if (_started || localVirtualIp.isEmpty) {
      return;
    }
    try {
      _controlServer = await ServerSocket.bind(
        InternetAddress(localVirtualIp),
        controlPort,
        shared: true,
      );
      _controlServer!.listen(_handleControlSocket);

      _attachmentServer = await ServerSocket.bind(
        InternetAddress(localVirtualIp),
        attachmentPort,
        shared: true,
      );
      _attachmentServer!.listen(_handleAttachmentSocket);

      _mediaSocket = await RawDatagramSocket.bind(
        InternetAddress(localVirtualIp),
        mediaPort,
        reuseAddress: true,
        reusePort: true,
      );
      _mediaSocket!.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = _mediaSocket!.receive();
        if (datagram == null) {
          return;
        }
        try {
          _mediaReceivedPackets++;
          final payload = utf8.decode(datagram.data);
          final packet = Map<String, dynamic>.from(
            jsonDecode(payload) as Map,
          );
          if (_mediaReceivedPackets == 1 || _mediaReceivedPackets % 25 == 0) {
            unawaited(
              ChatLogger.instance.info(
                'network.media',
                '收到语音数据包',
                networkKey: networkKey,
                extra: {
                  'remoteIp': datagram.address.address,
                  'packetCount': _mediaReceivedPackets,
                  'callId': packet['callId'],
                  'type': packet['type'],
                },
              ),
            );
          }
          unawaited(
            delegate.onMediaPacketReceived(
              networkKey: networkKey,
              remoteIp: datagram.address.address,
              packet: packet,
            ),
          );
        } catch (error, stackTrace) {
          delegate.onNetworkWarning(networkKey, error, stackTrace);
        }
      });
      _started = true;
      await ChatLogger.instance.info(
        'network.start',
        '聊天室网络监听已启动',
        networkKey: networkKey,
        extra: {
          'localVirtualIp': localVirtualIp,
          'controlPort': controlPort,
          'attachmentPort': attachmentPort,
          'mediaPort': mediaPort,
        },
      );
    } catch (_) {
      await _closeSockets();
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _closeSockets();
    _lastHelloAt.clear();
    await ChatLogger.instance.info(
      'network.stop',
      '聊天室网络监听已停止',
      networkKey: networkKey,
      extra: {
        'mediaSentPackets': _mediaSentPackets,
        'mediaReceivedPackets': _mediaReceivedPackets,
      },
    );
    _mediaSentPackets = 0;
    _mediaReceivedPackets = 0;
  }

  Future<void> _closeSockets() async {
    _started = false;
    await _controlServer?.close();
    await _attachmentServer?.close();
    _mediaSocket?.close();
    _controlServer = null;
    _attachmentServer = null;
    _mediaSocket = null;
  }

  void resetDiscoveryState() {
    _lastHelloAt.clear();
  }

  Future<void> refreshPeers(List<RustPeerClientInfo> peers) async {
    if (!_started) {
      await start();
    }
    final onlineIps = peers
        .where((peer) => peer.status.trim().toLowerCase() == 'online')
        .map((peer) => peer.virtualIp)
        .where((ip) => ip != localVirtualIp)
        .toSet();
    final now = DateTime.now();
    _lastHelloAt.removeWhere((ip, _) => !onlineIps.contains(ip));
    for (final peerIp in onlineIps) {
      final lastAt = _lastHelloAt[peerIp];
      if (lastAt == null || now.difference(lastAt) >= helloInterval) {
        _lastHelloAt[peerIp] = now;
        await sendEnvelope(
          remoteIp: peerIp,
          envelope: ChatEnvelope(
            messageId: '${networkKey}_${now.microsecondsSinceEpoch}_hello',
            type: ChatEnvelopeType.hello,
            fromVirtualIp: localVirtualIp,
            fromDeviceName: localDeviceName,
            sentAt: now.millisecondsSinceEpoch,
            payload: {
              'capabilities': const [
                'text',
                'image',
                'file',
                'voice_note',
                'voice_call',
                'channels',
              ],
            },
          ),
        );
        await ChatLogger.instance.info(
          'network.discovery',
          '发送 hello',
          networkKey: networkKey,
          extra: {
            'remoteIp': peerIp,
          },
        );
      }
    }
  }

  Future<void> sendEnvelope({
    required String remoteIp,
    required ChatEnvelope envelope,
  }) async {
    final socket = await Socket.connect(
      InternetAddress(remoteIp),
      controlPort,
      sourceAddress: localVirtualIp,
      timeout: const Duration(seconds: 5),
    );
    try {
      final payload = utf8.encode(jsonEncode(envelope.toJson()));
      socket.add(_frameBytes(payload));
      await socket.flush();
      await ChatLogger.instance.info(
        'network.control',
        '发送控制消息',
        networkKey: networkKey,
        extra: {
          'remoteIp': remoteIp,
          'type': envelope.type.name,
          'messageId': envelope.messageId,
          'conversationId': envelope.conversationId,
          'channelId': envelope.channelId,
        },
      );
    } finally {
      await socket.close();
    }
  }

  Future<ChatBroadcastResult> broadcastEnvelope({
    required Iterable<String> remoteIps,
    required ChatEnvelope envelope,
  }) async {
    final targetIps = remoteIps.toSet().where((ip) => ip != localVirtualIp);
    if (targetIps.isEmpty) {
      return const ChatBroadcastResult.empty();
    }

    var successCount = 0;
    final failedIps = <String>[];
    for (final ip in targetIps) {
      try {
        await sendEnvelope(remoteIp: ip, envelope: envelope);
        successCount++;
      } catch (error, stackTrace) {
        failedIps.add(ip);
        await ChatLogger.instance.warn(
          'network.broadcast',
          '广播控制消息发送失败',
          networkKey: networkKey,
          extra: {
            'remoteIp': ip,
            'type': envelope.type.name,
            'messageId': envelope.messageId,
            'conversationId': envelope.conversationId,
            'channelId': envelope.channelId,
            'error': error.toString(),
            'stackTrace': stackTrace.toString(),
          },
        );
      }
    }
    return ChatBroadcastResult(
      attemptedCount: targetIps.length,
      successCount: successCount,
      failedIps: failedIps,
    );
  }

  Future<void> sendAttachment({
    required String remoteIp,
    required Map<String, dynamic> header,
    required String filePath,
  }) async {
    final socket = await Socket.connect(
      InternetAddress(remoteIp),
      attachmentPort,
      sourceAddress: localVirtualIp,
      timeout: const Duration(seconds: 10),
    );
    try {
      final headerBytes = utf8.encode(jsonEncode(header));
      socket.add(_frameBytes(headerBytes));
      await socket.flush();
      await ChatLogger.instance.info(
        'network.attachment',
        '开始发送附件',
        networkKey: networkKey,
        extra: {
          'remoteIp': remoteIp,
          'attachmentId': header['attachmentId'],
          'messageId': header['messageId'],
          'filePath': filePath,
          'size': header['size'],
        },
      );
      await for (final chunk in File(filePath).openRead()) {
        socket.add(chunk);
      }
      await socket.flush();
      await ChatLogger.instance.info(
        'network.attachment',
        '附件发送完成',
        networkKey: networkKey,
        extra: {
          'remoteIp': remoteIp,
          'attachmentId': header['attachmentId'],
          'messageId': header['messageId'],
        },
      );
    } finally {
      await socket.close();
    }
  }

  Future<void> sendMediaPacket({
    required String remoteIp,
    required Map<String, dynamic> packet,
  }) async {
    if (_mediaSocket == null) {
      await start();
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet)));
    _mediaSocket?.send(bytes, InternetAddress(remoteIp), mediaPort);
    _mediaSentPackets++;
    if (_mediaSentPackets == 1 || _mediaSentPackets % 25 == 0) {
      await ChatLogger.instance.info(
        'network.media',
        '发送语音数据包',
        networkKey: networkKey,
        extra: {
          'remoteIp': remoteIp,
          'packetCount': _mediaSentPackets,
          'callId': packet['callId'],
          'type': packet['type'],
        },
      );
    }
  }

  Uint8List _frameBytes(List<int> payload) {
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    final bytes = BytesBuilder(copy: false);
    bytes.add(header.buffer.asUint8List());
    bytes.add(payload);
    return bytes.toBytes();
  }

  Future<void> _handleControlSocket(Socket socket) async {
    try {
      final bytes = await socket.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, data) {
          builder.add(data);
          return builder;
        },
      );
      final all = bytes.toBytes();
      if (all.length < 4) {
        return;
      }
      final header = ByteData.sublistView(all, 0, 4);
      final length = header.getUint32(0, Endian.big);
      if (all.length < 4 + length) {
        return;
      }
      final payload = utf8.decode(all.sublist(4, 4 + length));
      final envelope = ChatEnvelope.fromJson(
        Map<String, dynamic>.from(jsonDecode(payload) as Map),
      );
      await ChatLogger.instance.info(
        'network.control',
        '收到控制消息',
        networkKey: networkKey,
        extra: {
          'remoteIp': socket.remoteAddress.address,
          'type': envelope.type.name,
          'messageId': envelope.messageId,
          'conversationId': envelope.conversationId,
          'channelId': envelope.channelId,
        },
      );
      await delegate.onEnvelopeReceived(
        networkKey: networkKey,
        remoteIp: socket.remoteAddress.address,
        envelope: envelope,
      );
    } catch (error, stackTrace) {
      delegate.onNetworkWarning(networkKey, error, stackTrace);
    } finally {
      await socket.close();
    }
  }

  Future<void> _handleAttachmentSocket(Socket socket) async {
    Map<String, dynamic>? header;
    IOSink? sink;
    String? localPath;
    int? headerLength;
    final buffer = BytesBuilder(copy: false);
    int receivedBytes = 0;

    Future<void> flushBufferToSink() async {
      if (sink == null) {
        return;
      }
      final bytes = buffer.takeBytes();
      if (bytes.isEmpty) {
        return;
      }
      sink.add(bytes);
      receivedBytes += bytes.length;
    }

    try {
      await for (final chunk in socket) {
        buffer.add(chunk);
        while (true) {
          final snapshot = buffer.toBytes();
          if (headerLength == null) {
            if (snapshot.length < 4) {
              break;
            }
            final data = ByteData.sublistView(snapshot, 0, 4);
            headerLength = data.getUint32(0, Endian.big);
            final remainder = snapshot.sublist(4);
            buffer.clear();
            buffer.add(remainder);
            continue;
          }
          if (header == null) {
            if (snapshot.length < headerLength) {
              break;
            }
            header = Map<String, dynamic>.from(
              jsonDecode(utf8.decode(snapshot.sublist(0, headerLength))) as Map,
            );
            localPath = await delegate.prepareIncomingAttachmentPath(
              networkKey: networkKey,
              header: header,
            );
            if (localPath == null) {
              throw StateError('无法为附件创建本地路径');
            }
            sink = File(localPath).openWrite();
            final remainder = snapshot.sublist(headerLength);
            buffer.clear();
            buffer.add(remainder);
            continue;
          }
          await flushBufferToSink();
          break;
        }
      }
      await flushBufferToSink();
      await sink?.flush();
      await sink?.close();
      if (header != null && localPath != null) {
        await ChatLogger.instance.info(
          'network.attachment',
          '附件接收完成',
          networkKey: networkKey,
          extra: {
            'attachmentId': header['attachmentId'],
            'messageId': header['messageId'],
            'localPath': localPath,
            'bytesReceived': receivedBytes,
            'sha256': header['sha256'],
          },
        );
        await delegate.onAttachmentReceived(
          networkKey: networkKey,
          header: header,
          localPath: localPath,
          bytesReceived: receivedBytes,
        );
      }
    } catch (error) {
      await sink?.close();
      if (localPath != null) {
        final file = File(localPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await delegate.onAttachmentFailed(
        networkKey: networkKey,
        header: header,
        error: error,
      );
    } finally {
      await socket.close();
    }
  }
}

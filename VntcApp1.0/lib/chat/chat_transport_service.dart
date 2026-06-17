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

class ChatTransportService {
  ServerSocket? _server;
  ChatPacketHandler? _handler;

  bool get isRunning => _server != null;
  int? get listeningPort => _server?.port;

  Future<void> start({
    required ChatPacketHandler onPacket,
    int? listenPort,
  }) async {
    _handler = onPacket;
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
  }) async {
    await ChatLog.write(
      '发送聊天报文 type=${packet.type} target=$targetIp port=${port ?? ChatConstants.transportPort}',
    );
    final socket = await Socket.connect(
      targetIp,
      port ?? ChatConstants.transportPort,
    );
    socket.add(utf8.encode(packet.toJsonLine()));
    await socket.flush();
    await socket.close();
  }

  void _handleClient(Socket socket) {
    final bytes = <int>[];
    socket.listen(
      bytes.addAll,
      onDone: () async {
        try {
          final payload = utf8.decode(bytes, allowMalformed: true).trim();
          if (payload.isEmpty) {
            return;
          }
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) {
            return;
          }
          final packet = ChatTransportPacket.fromJson(decoded);
          final handler = _handler;
          if (handler != null) {
            await ChatLog.write(
              '收到聊天报文 type=${packet.type} remote=${socket.remoteAddress.address}:${socket.remotePort}',
            );
            await handler(packet, socket.remoteAddress);
          }
        } catch (error) {
          await ChatLog.write(
            '聊天报文解码失败 remote=${socket.remoteAddress.address}:${socket.remotePort} error=$error bytes=${bytes.length}',
          );
        }
      },
      onError: (error) async {
        await ChatLog.write(
          '聊天连接读取失败 remote=${socket.remoteAddress.address}:${socket.remotePort} error=$error',
        );
      },
      cancelOnError: true,
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_presence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('在线状态UDP报文远端地址与声明身份不一致时会被丢弃', () async {
    final service = ChatPresenceService(listenPort: 0);
    final snapshots = <Map<String, ChatPresenceAnnouncement>>[];
    RawDatagramSocket? sender;

    try {
      await service.updateContexts(
        contexts: const <ChatPresenceContext>[
          ChatPresenceContext(
            hallId: 'hall:test',
            hallTitle: '测试大厅',
            displayName: '本机',
            virtualIp: '127.0.0.2',
            peerVirtualIps: <String>[],
            rooms: <ChatRoomDescriptor>[],
          ),
        ],
        onSnapshot: snapshots.add,
      );
      final port = service.listeningPort;
      expect(port, isNotNull);

      sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final packet = ChatPresenceAnnouncement(
        hallId: 'hall:test',
        hallTitle: '测试大厅',
        displayName: '伪造节点',
        virtualIp: '10.0.0.9',
        rooms: const <ChatRoomDescriptor>[],
        sentAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      ).toJson();
      sender.send(
        utf8.encode(jsonEncode(packet)),
        InternetAddress.loopbackIPv4,
        port!,
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(snapshots.any((snapshot) => snapshot.isNotEmpty), isFalse);
    } finally {
      sender?.close();
      await service.stop();
    }
  });
}

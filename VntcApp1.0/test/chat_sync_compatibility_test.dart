import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';

void main() {
  test('别名大厅的补同步摘要会归一到本地会话', () {
    const localHallId = 'hall:server.example:2225|10.10.10.0';
    const incomingHallId = 'hall:quic://server.example:2225|10.10.10.0';
    const localIp = '10.10.10.8';
    const remoteIp = '10.10.10.4';
    const incomingRoomId =
        'room:hall:quic://server.example:2225|10.10.10.0:10.10.10.4:room-a';
    const canonicalRoomId =
        'room:hall:server.example:2225|10.10.10.0:10.10.10.4:room-a';
    final canonicalDirectId = buildDirectConversationId(
      hallId: localHallId,
      firstVirtualIp: localIp,
      secondVirtualIp: remoteIp,
    );
    final incomingDirectId = buildLegacyDirectConversationId(
      hallId: incomingHallId,
      firstVirtualIp: localIp,
      secondVirtualIp: remoteIp,
    );

    final summary = canonicalizeChatSyncSummary(
      remoteSummary: <String, Map<String, int>>{
        incomingHallId: <String, int>{remoteIp: 3},
        incomingDirectId: <String, int>{remoteIp: 7},
        incomingRoomId: <String, int>{remoteIp: 11},
      },
      incomingHallId: incomingHallId,
      localHallId: localHallId,
      localVirtualIp: localIp,
      remoteVirtualIp: remoteIp,
      incomingRoomIds: const <String>[incomingRoomId],
      canonicalRoomIds: const <String>[canonicalRoomId],
    );

    expect(summary[localHallId], <String, int>{remoteIp: 3});
    expect(summary[canonicalDirectId], <String, int>{remoteIp: 7});
    expect(summary[canonicalRoomId], <String, int>{remoteIp: 11});
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';

void main() {
  group('ChatIds', () {
    test('默认大厅频道ID稳定', () {
      expect(ChatIds.lobbyChannelId('net-a'), 'lobby:net-a');
      expect(
        ChatIds.channelConversationId('net-a', ChatIds.lobbyChannelId('net-a')),
        'channel:net-a:lobby:net-a',
      );
    });
  });

  group('RemoteAssistSession', () {
    test('请求控制时发起方是本地控制端', () {
      final session = RemoteAssistSession(
        sessionId: 's1',
        networkKey: 'net-a',
        peerId: 'peer-b',
        peerVirtualIp: '10.0.0.2',
        controllerPeerId: 'peer-a',
        controlledPeerId: 'peer-b',
        controllerVirtualIp: '10.0.0.1',
        controlledVirtualIp: '10.0.0.2',
        mode: RemoteAssistMode.requestControl,
        listenPort: 21118,
        sessionToken: 'token',
        state: RemoteAssistState.pending,
        isIncoming: false,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      expect(session.isControllerLocal, isTrue);
      expect(session.isControlledLocal, isFalse);
    });

    test('邀请控制时接收方是本地控制端', () {
      final session = RemoteAssistSession(
        sessionId: 's2',
        networkKey: 'net-a',
        peerId: 'peer-a',
        peerVirtualIp: '10.0.0.1',
        controllerPeerId: 'peer-b',
        controlledPeerId: 'peer-a',
        controllerVirtualIp: '10.0.0.2',
        controlledVirtualIp: '10.0.0.1',
        mode: RemoteAssistMode.inviteControl,
        listenPort: 21118,
        sessionToken: 'token',
        state: RemoteAssistState.pending,
        isIncoming: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      expect(session.isControllerLocal, isTrue);
      expect(session.isControlledLocal, isFalse);
    });
  });
}

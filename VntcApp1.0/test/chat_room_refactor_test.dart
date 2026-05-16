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

    test('当前页面网络作用域仅匹配选中的连接', () {
      expect(chatMatchesNetworkScope('net-a', null), isTrue);
      expect(chatMatchesNetworkScope('net-a', ''), isTrue);
      expect(chatMatchesNetworkScope('net-a', 'net-a'), isTrue);
      expect(chatMatchesNetworkScope('net-a', 'net-b'), isFalse);
    });
  });

  group('ChatPeer online freshness', () {
    test('超过新鲜度窗口的在线记录会被视为离线', () {
      final now = DateTime(2026, 5, 7, 12, 0, 0);
      final peer = ChatPeer(
        peerId: 'peer-a',
        networkKey: 'net-a',
        virtualIp: '10.0.0.2',
        deviceName: 'Office-PC',
        isOnline: true,
        lastSeenAt: now.subtract(const Duration(seconds: 30)),
        createdAt: now,
        updatedAt: now,
      );

      expect(chatPeerIsEffectivelyOnline(peer, now: now), isFalse);
      expect(
        chatPeerIsEffectivelyOnline(
          peer.copyWith(lastSeenAt: now.subtract(const Duration(seconds: 3))),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('Public channel handshake sync', () {
    test('仅公开未归档房间参与握手补同步', () {
      final now = DateTime(2026, 5, 7, 12, 0, 0);
      final channels = [
        ChatChannel(
          channelId: 'lobby:net-a',
          networkKey: 'net-a',
          name: '大厅',
          ownerPeerId: 'peer-a',
          isPrivate: false,
          joined: true,
          archived: false,
          createdAt: now,
          updatedAt: now,
        ),
        ChatChannel(
          channelId: 'public-room',
          networkKey: 'net-a',
          name: '公开房间',
          ownerPeerId: 'peer-a',
          isPrivate: false,
          joined: true,
          archived: false,
          createdAt: now,
          updatedAt: now,
        ),
        ChatChannel(
          channelId: 'private-room',
          networkKey: 'net-a',
          name: '私密房间',
          ownerPeerId: 'peer-a',
          isPrivate: true,
          joined: true,
          archived: false,
          createdAt: now,
          updatedAt: now,
        ),
        ChatChannel(
          channelId: 'archived-room',
          networkKey: 'net-a',
          name: '已归档房间',
          ownerPeerId: 'peer-a',
          isPrivate: false,
          joined: true,
          archived: true,
          createdAt: now,
          updatedAt: now,
        ),
      ];

      final syncable =
          channels.where(chatChannelShouldSyncOnHandshake).toList();

      expect(
        syncable.map((channel) => channel.channelId).toList(),
        ['lobby:net-a', 'public-room'],
      );
      expect(
        buildPublicChannelAnnouncementPayload(syncable.last),
        {
          'channelId': 'public-room',
          'name': '公开房间',
          'ownerPeerId': 'peer-a',
          'isPrivate': false,
        },
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

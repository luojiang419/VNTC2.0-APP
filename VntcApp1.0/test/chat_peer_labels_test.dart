import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_peer_labels.dart';

void main() {
  final peer = ChatPeer(
    peerId: 'net-a:10.0.0.2',
    networkKey: 'net-a',
    virtualIp: '10.0.0.2',
    deviceName: 'Office-PC',
    remark: '开发机',
    isOnline: true,
    lastSeenAt: DateTime(2026),
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  test('在线成员主标题固定显示设备名称', () {
    expect(chatPeerPrimaryName(peer), 'Office-PC');
  });

  test('在线成员副标题包含备注、IP、网络和好友状态', () {
    expect(
      buildOnlinePeerSubtitle(
        peer,
        hasMultipleNetworks: true,
        friendStatus: ChatFriendStatus.friend,
      ),
      '备注：开发机 · 10.0.0.2 · net-a · 好友',
    );
  });

  test('成员选择副标题可附加房主标记', () {
    expect(
      buildMemberPeerSubtitle(
        peer,
        hasMultipleNetworks: false,
        suffix: '房主',
      ),
      '备注：开发机 · 10.0.0.2 · 房主',
    );
  });
}

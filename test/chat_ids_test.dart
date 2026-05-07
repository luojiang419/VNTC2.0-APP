import 'package:test/test.dart';
import 'package:vnt_app/chat/chat_models.dart';

void main() {
  group('ChatIds', () {
    test('peerId keeps network and ip scope', () {
      expect(ChatIds.peerId('net-a', '10.0.0.2'), 'net-a:10.0.0.2');
      expect(ChatIds.peerId('net-b', '10.0.0.2'), 'net-b:10.0.0.2');
    });

    test('directConversationId is symmetric', () {
      final left = ChatIds.directConversationId(
        'net-a',
        'net-a:10.0.0.2',
        'net-a:10.0.0.3',
      );
      final right = ChatIds.directConversationId(
        'net-a',
        'net-a:10.0.0.3',
        'net-a:10.0.0.2',
      );
      expect(left, right);
    });

    test('channelConversationId keeps channel scope', () {
      expect(
        ChatIds.channelConversationId('net-a', 'channel-1'),
        'channel:net-a:channel-1',
      );
    });
  });
}

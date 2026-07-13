import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_security.dart';

void main() {
  test('empty room password produces an open room', () {
    final metadata = createChatRoomPasswordMetadata('   ');

    expect(chatRoomRequiresPassword(metadata), isFalse);
  });

  test('protected room stores verifier instead of plaintext password', () {
    const password = 'small-group-secret';
    final metadata = createChatRoomPasswordMetadata(password);

    expect(chatRoomRequiresPassword(metadata), isTrue);
    expect(metadata, isNot(contains(password)));
    expect(verifyChatRoomPassword(password, metadata), isTrue);
    expect(verifyChatRoomPassword('wrong-password', metadata), isFalse);
  });

  test('malformed room password metadata is rejected', () {
    expect(chatRoomRequiresPassword('{broken'), isFalse);
    expect(verifyChatRoomPassword('password', '{broken'), isFalse);
  });
}

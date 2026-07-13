import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_android_permission_service.dart';

void main() {
  test('local network permission issue tells the user how to recover', () {
    final issue = chatAndroidLocalNetworkPermissionIssue();

    expect(issue, contains('附近设备/本地网络'));
    expect(issue, contains('聊天室'));
    expect(issue, isNot(contains('SocketException')));
  });
}

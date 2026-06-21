import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_manager.dart';

void main() {
  test('chat supports Windows and macOS desktop platforms', () {
    expect(
      isChatSupportedPlatform(isWindows: true, isMacOS: false),
      isTrue,
    );
    expect(
      isChatSupportedPlatform(isWindows: false, isMacOS: true),
      isTrue,
    );
    expect(
      isChatSupportedPlatform(isWindows: false, isMacOS: false),
      isFalse,
    );
  });

  test('chat startup issue message is empty when listeners are healthy', () {
    expect(
      buildChatStartupIssueMessage(),
      isNull,
    );
  });

  test('chat startup issue message combines listener failures', () {
    expect(
      buildChatStartupIssueMessage(
        transportError: 'Address already in use',
        presenceError: 'Permission denied',
        refreshError: 'database locked',
      ),
      contains('消息监听未就绪：Address already in use'),
    );
    expect(
      buildChatStartupIssueMessage(
        transportError: 'Address already in use',
        presenceError: 'Permission denied',
        refreshError: 'database locked',
      ),
      contains('在线状态广播未就绪：Permission denied'),
    );
    expect(
      buildChatStartupIssueMessage(
        transportError: 'Address already in use',
        presenceError: 'Permission denied',
        refreshError: 'database locked',
      ),
      contains('大厅刷新未就绪：database locked'),
    );
  });
}

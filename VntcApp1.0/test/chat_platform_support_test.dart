import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_constants.dart';
import 'package:vnt_app/chat/chat_manager.dart';

void main() {
  test('chat supports Windows, macOS, and Android platforms', () {
    expect(
      isChatSupportedPlatform(
        isWindows: true,
        isMacOS: false,
        isAndroid: false,
      ),
      isTrue,
    );
    expect(
      isChatSupportedPlatform(
        isWindows: false,
        isMacOS: true,
        isAndroid: false,
      ),
      isTrue,
    );
    expect(
      isChatSupportedPlatform(
        isWindows: false,
        isMacOS: false,
        isAndroid: true,
      ),
      isTrue,
    );
    expect(
      isChatSupportedPlatform(
        isWindows: false,
        isMacOS: false,
        isAndroid: false,
      ),
      isFalse,
    );
  });

  test('chat startup issue message is empty when listeners are healthy', () {
    expect(
      buildChatStartupIssueMessage(),
      isNull,
    );
  });

  test('chat listeners use private ports outside Android reserved range', () {
    expect(ChatConstants.presencePort, 61018);
    expect(ChatConstants.transportPort, 61019);
    expect(ChatConstants.legacyTransportPort, 50019);
    expect(
      ChatConstants.transportPortCandidates,
      <int>[61019, 50019],
    );
    expect(ChatConstants.presencePort, greaterThanOrEqualTo(49152));
    expect(ChatConstants.transportPort, greaterThanOrEqualTo(49152));
    expect(ChatConstants.chatRuleNameUdp, contains('61018'));
    expect(ChatConstants.chatRuleNameTcp, contains('61019'));
    expect(
      ChatConstants.transportConnectTimeout,
      const Duration(seconds: 1),
    );
  });

  test('text recipients are delivered concurrently and failures are isolated',
      () async {
    final startedRecipients = <String>{};
    final allStarted = Completer<void>();
    final release = Completer<void>();

    final delivery = sendChatRecipientsConcurrently(
      recipients: const <String>['10.0.0.2', '10.0.0.3'],
      sendToRecipient: (recipient) async {
        startedRecipients.add(recipient);
        if (startedRecipients.length == 2 && !allStarted.isCompleted) {
          allStarted.complete();
        }
        await release.future;
        if (recipient == '10.0.0.3') {
          throw StateError('offline');
        }
      },
    );

    await allStarted.future.timeout(const Duration(seconds: 1));
    expect(startedRecipients, <String>{'10.0.0.2', '10.0.0.3'});
    release.complete();
    final outcomes = await delivery;

    expect(outcomes.singleWhere((item) => item.recipient == '10.0.0.2').error,
        isNull);
    expect(outcomes.singleWhere((item) => item.recipient == '10.0.0.3').error,
        isA<StateError>());
  });

  test('text message is persisted as sending before network delivery starts',
      () {
    final source = File('lib/chat/chat_manager.dart').readAsStringSync();
    final sendTextStart = source.indexOf('Future<ChatSendResult> sendText');
    final sendTextEnd = source.indexOf(
      'void _startAttachmentTransfer',
      sendTextStart,
    );
    final sendTextSource = source.substring(sendTextStart, sendTextEnd);

    expect(
      sendTextSource.indexOf('status: ChatMessageStatus.sending'),
      lessThan(sendTextSource.indexOf('sendChatRecipientsConcurrently')),
    );
    expect(
      sendTextSource.indexOf('notifyListeners();'),
      lessThan(sendTextSource.indexOf('sendChatRecipientsConcurrently')),
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

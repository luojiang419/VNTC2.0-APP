import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';

void main() {
  const attachment = ChatAttachmentRecord(
    id: 'attachment-1',
    messageId: 'message-1',
    fileName: 'screenshot.png',
    mimeType: 'image/png',
    sizeBytes: 128,
    relativePath: 'message-1.png',
    autoSyncEligible: true,
    payloadAvailable: true,
    needsManualResend: false,
    createdAtEpochMs: 1,
  );

  ChatMessageRecord imageMessage(String text) => ChatMessageRecord(
        id: 'message-1',
        conversationId: 'hall-1',
        hallId: 'hall-1',
        conversationType: ChatConversationType.hall,
        senderVirtualIp: '10.0.0.1',
        senderName: '测试用户',
        senderSeq: 1,
        direction: ChatMessageDirection.outgoing,
        contentType: ChatMessageContentType.image,
        status: ChatMessageStatus.sent,
        text: text,
        isSyncMessage: false,
        isRead: true,
        sentAtEpochMs: 1,
        createdAtEpochMs: 1,
        metadataJson: '{}',
        attachmentId: attachment.id,
        attachment: attachment,
      );

  test('图片消息可携带独立于文件名的文本说明', () {
    final message = imageMessage('请看这个窗口');

    expect(message.attachmentCaption, '请看这个窗口');
    final restored = ChatMessageRecord.fromTransportJson(
      message.toTransportJson(),
    );
    expect(restored.text, '请看这个窗口');
    expect(restored.attachmentCaption, '请看这个窗口');
  });

  test('旧版图片消息使用文件名时不会被误判为说明文字', () {
    expect(imageMessage('screenshot.png').attachmentCaption, isNull);
    expect(imageMessage('   ').attachmentCaption, isNull);
  });
}

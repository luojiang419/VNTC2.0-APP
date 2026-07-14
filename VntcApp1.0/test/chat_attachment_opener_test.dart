import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_attachment_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.wherewego.vnt/chat_android');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android attachment opener forwards path and MIME type', () async {
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return true;
        });

    final opened = await ChatAttachmentOpener.openAndroidAttachment(
      filePath: '/data/user/0/top.wherewego.vnt_app/files/chat/photo.jpg',
      mimeType: 'image/jpeg',
    );

    expect(opened, isTrue);
    expect(receivedCall?.method, 'openAttachment');
    expect(receivedCall?.arguments, <String, String>{
      'filePath': '/data/user/0/top.wherewego.vnt_app/files/chat/photo.jpg',
      'mimeType': 'image/jpeg',
    });
  });

  test(
    'Android attachment opener treats an empty native result as failure',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);

      final opened = await ChatAttachmentOpener.openAndroidAttachment(
        filePath: '/tmp/file.bin',
        mimeType: 'application/octet-stream',
      );

      expect(opened, isFalse);
    },
  );
}

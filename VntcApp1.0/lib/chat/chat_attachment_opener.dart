import 'package:flutter/services.dart';

class ChatAttachmentOpener {
  ChatAttachmentOpener._();

  static const MethodChannel _channel = MethodChannel(
    'top.wherewego.vnt/chat_android',
  );

  static Future<bool> openAndroidAttachment({
    required String filePath,
    required String mimeType,
  }) async {
    return await _channel.invokeMethod<bool>('openAttachment', <String, String>{
          'filePath': filePath,
          'mimeType': mimeType,
        }) ??
        false;
  }
}

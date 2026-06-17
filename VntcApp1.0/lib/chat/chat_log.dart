import 'dart:io';

import 'package:synchronized/synchronized.dart';
import 'package:vnt_app/utils/log_utils.dart';

class ChatLog {
  ChatLog._();

  static final Lock _lock = Lock();

  static Future<void> write(String message) async {
    try {
      await _lock.synchronized(() async {
        final logDirectory = Directory(await LogUtils.getLogDirectory());
        if (!await logDirectory.exists()) {
          await logDirectory.create(recursive: true);
        }
        final logFile = File('${logDirectory.path}/chat_transport.log');
        await logFile.writeAsString(
          '${DateTime.now().toIso8601String()} | $message\n',
          mode: FileMode.append,
          flush: true,
        );
      });
    } catch (_) {
      // 诊断日志不能影响主流程
    }
  }
}

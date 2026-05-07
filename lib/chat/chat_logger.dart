import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vnt_app/utils/log_utils.dart';

class ChatLogger {
  ChatLogger._();

  static final ChatLogger instance = ChatLogger._();

  File? _file;
  Future<void> _queue = Future<void>.value();

  String get logFilePath => _file?.path ?? '';

  Future<void> init() async {
    if (_file != null) {
      return;
    }
    final logDir = await LogUtils.getLogDirectory();
    final directory = Directory(logDir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _file = File(path.join(directory.path, 'chat-debug.log'));
    if (!await _file!.exists()) {
      await _file!.create(recursive: true);
    }
    await info('logger', '聊天室日志初始化完成', extra: {
      'logFilePath': _file!.path,
    });
  }

  Future<void> clear() async {
    await init();
    _queue = _queue.then((_) async {
      await _file!.writeAsString('');
    });
    await _queue;
  }

  Future<void> info(
    String tag,
    String message, {
    String? networkKey,
    Map<String, Object?> extra = const {},
  }) {
    return _write(
      level: 'INFO',
      tag: tag,
      message: message,
      networkKey: networkKey,
      extra: extra,
    );
  }

  Future<void> warn(
    String tag,
    String message, {
    String? networkKey,
    Map<String, Object?> extra = const {},
  }) {
    return _write(
      level: 'WARN',
      tag: tag,
      message: message,
      networkKey: networkKey,
      extra: extra,
    );
  }

  Future<void> error(
    String tag,
    String message, {
    String? networkKey,
    Map<String, Object?> extra = const {},
  }) {
    return _write(
      level: 'ERROR',
      tag: tag,
      message: message,
      networkKey: networkKey,
      extra: extra,
    );
  }

  Future<void> _write({
    required String level,
    required String tag,
    required String message,
    String? networkKey,
    Map<String, Object?> extra = const {},
  }) async {
    await init();
    final payload = <String, Object?>{
      'time': DateTime.now().toIso8601String(),
      'level': level,
      'tag': tag,
      'networkKey': networkKey,
      'message': message,
      if (extra.isNotEmpty) 'extra': extra,
    };
    final line = '${jsonEncode(payload)}\n';
    _queue = _queue.then((_) async {
      await _file!.writeAsString(line, mode: FileMode.append, flush: true);
    });
    await _queue;
  }
}

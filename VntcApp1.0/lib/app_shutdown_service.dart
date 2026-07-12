import 'package:flutter/foundation.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/remote_assist/remote_assist_manager.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

Future<void> prepareForAppShutdown() async {
  await _runShutdownStep('聊天室', ChatManager.instance.stop);
  await _runShutdownStep('远程协助', RemoteAssistManager.instance.stop);
  await _runShutdownStep('VNT 网络', vntManager.removeAll);
}

Future<void> _runShutdownStep(
  String label,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    debugPrint('$label 退出清理失败: $error');
  }
}

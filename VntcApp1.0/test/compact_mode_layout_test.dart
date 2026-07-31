import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/pages/remote_assist_page.dart';

void main() {
  test('极简模式 Dock 固定包含组网、聊天、远程三个入口', () {
    final source =
        File('lib/pages/main_navigation_shell.dart').readAsStringSync();

    expect(source, contains("ValueKey('compact-mode-bottom-dock')"));
    expect(source, contains("label: '组网'"));
    expect(source, contains("label: '聊天'"));
    expect(source, contains("label: '远程'"));
  });

  test('极简聊天仅暴露文本、截图、文件和发送操作', () {
    final source = File('lib/pages/compact_chat_page.dart').readAsStringSync();

    expect(source, contains("ValueKey('compact-chat-text-input')"));
    expect(source, contains("ValueKey('compact-chat-screenshot-button')"));
    expect(source, contains("ValueKey('compact-chat-file-button')"));
    expect(source, contains("ValueKey('compact-chat-send-button')"));
    expect(source, isNot(contains('ChatMainTab.direct')));
    expect(source, isNot(contains('hallPeers(')));
  });

  test('Windows 截图使用全虚拟屏幕原始像素与 PNG 编码', () {
    final runner = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final service = File('lib/screenshot/system_screenshot_service.dart')
        .readAsStringSync();

    expect(runner, contains('SM_CXVIRTUALSCREEN'));
    expect(runner, contains('SM_CYVIRTUALSCREEN'));
    expect(runner, contains('SRCCOPY | CAPTUREBLT'));
    expect(runner, contains('L"image/png"'));
    expect(runner, contains('RegisterHotKey'));
    expect(service, contains("'screenshots'"));
    expect(service, contains("'screenshot_\${_formatTimestamp"));
  });

  test('远程用户卡片会按极简窗口宽度缩放', () {
    expect(remotePeerColumnCount(width: 610, compactMode: true), 1);
    expect(remotePeerColumnCount(width: 980, compactMode: true), 2);
    expect(remotePeerColumnCount(width: 679, compactMode: false), 1);
    expect(remotePeerColumnCount(width: 680, compactMode: false), 2);
    expect(remotePeerColumnCount(width: 1100, compactMode: false), 3);
    expect(usesStackedRemotePeerCard(479), isTrue);
    expect(usesStackedRemotePeerCard(480), isFalse);
  });
}

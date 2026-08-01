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

  test('极简聊天提供大厅清空、截图预览、文件和统一发送操作', () {
    final source = File('lib/pages/compact_chat_page.dart').readAsStringSync();

    expect(source, contains("ValueKey('compact-chat-clear-button')"));
    expect(source, contains("ValueKey('compact-chat-text-input')"));
    expect(source, contains("ValueKey('compact-chat-screenshot-button')"));
    expect(source, contains("ValueKey('compact-chat-screenshot-preview')"));
    expect(
      source,
      contains("ValueKey('compact-chat-remove-screenshot-button')"),
    );
    expect(source, contains("ValueKey('compact-chat-file-button')"));
    expect(source, contains("ValueKey('compact-chat-send-button')"));
    expect(source, contains('captureInteractive()'));
    expect(source, contains('caption: text'));
    expect(source, contains('_manager.clearConversationMessages('));
    expect(source, isNot(contains('_captureAndSend')));
    expect(source, isNot(contains('ChatMainTab.direct')));
    expect(source, isNot(contains('hallPeers(')));
  });

  test('Windows 截图选择器支持自由框选、窗口吸附和键鼠确认', () {
    final runner = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final selector =
        File('windows/runner/screen_capture_selector.cpp').readAsStringSync();
    final service = File('lib/screenshot/system_screenshot_service.dart')
        .readAsStringSync();

    expect(selector, contains('SM_CXVIRTUALSCREEN'));
    expect(selector, contains('SM_CYVIRTUALSCREEN'));
    expect(selector, contains('SRCCOPY | CAPTUREBLT'));
    expect(selector, contains('L"image/png"'));
    expect(selector, contains('DwmGetWindowAttribute'));
    expect(selector, contains('CS_DBLCLKS'));
    expect(selector, contains('WM_LBUTTONDBLCLK'));
    expect(selector, contains('VK_RETURN'));
    expect(selector, contains('VK_ESCAPE'));
    expect(runner, contains('RegisterHotKey'));
    expect(runner, contains('captureRegion'));
    expect(service, contains('captureInteractive()'));
    expect(service, contains('ScreenshotCaptureResult.canceled()'));
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

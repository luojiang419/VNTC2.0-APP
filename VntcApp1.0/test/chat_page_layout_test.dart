import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/pages/chat_page.dart';

void main() {
  test('chat navigation exposes hall rooms online and direct tabs', () {
    expect(ChatMainTab.values, [
      ChatMainTab.hall,
      ChatMainTab.rooms,
      ChatMainTab.online,
      ChatMainTab.direct,
    ]);
  });

  test('chat page keeps room creation in the rooms bottom action', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();
    final headerStart = source.indexOf('Widget _buildHeader(');
    final headerEnd = source.indexOf('Widget _buildDirectTabLabel(');
    final roomsStart = source.indexOf('Widget _buildRoomsTab(');
    final roomsEnd = source.indexOf('Widget _buildStartupIssueBanner(');

    expect(source, contains("const Tab(text: '房间')"));
    expect(source, contains("const Tab(text: '在线')"));
    expect(headerStart, greaterThanOrEqualTo(0));
    expect(headerEnd, greaterThan(headerStart));
    expect(
      source.substring(headerStart, headerEnd),
      isNot(contains('_showCreateRoomDialog')),
    );
    expect(roomsStart, greaterThanOrEqualTo(0));
    expect(roomsEnd, greaterThan(roomsStart));
    expect(
      source.substring(roomsStart, roomsEnd),
      allOf(
        contains('FloatingActionButton.small'),
        contains("heroTag: 'chat-create-room'"),
        contains("tooltip: '创建房间'"),
      ),
    );
  });

  test('compact chat navigation uses the top-right hamburger menu', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();

    expect(source, contains('PopupMenuButton<ChatMainTab>'));
    expect(source, contains("tooltip: '切换聊天页面'"));
    expect(source, contains('if (!compactNavigation)'));
    expect(source, contains('Icons.menu_rounded'));
  });

  test('hall chat content does not render the hall card strip', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();
    final hallContentStart = source.indexOf('Widget _buildHallContent(');
    final hallCardStripStart = source.indexOf('Widget _buildHallCardStrip(');

    expect(hallContentStart, greaterThanOrEqualTo(0));
    expect(hallCardStripStart, greaterThan(hallContentStart));
    expect(
      source.substring(hallContentStart, hallCardStripStart),
      isNot(contains('_buildHallCardStrip(')),
    );
  });

  test('hall and direct conversations expose local history cleanup', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();

    expect(source, contains("tooltip: '清理聊天记录'"));
    expect(source, contains('ChatConversationType.hall'));
    expect(source, contains('ChatConversationType.direct'));
    expect(source, contains('_confirmClearConversationHistory'));
    expect(source, contains('此操作只清理本机记录，且无法撤销。'));
  });

  test('direct conversation cards expose delete and mobile swipe actions', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();

    expect(source, contains("tooltip: '删除会话'"));
    expect(source, contains('Icons.delete_outline_rounded'));
    expect(source, contains('Dismissible('));
    expect(source, contains('DismissDirection.endToStart'));
    expect(source, contains('_confirmDeleteDirectConversation'));
    expect(source, contains('_manager.deleteDirectConversation'));
    expect(source, contains("title: const Text('删除私聊会话')"));
    expect(
      usesMobileDirectConversationSwipe(width: 390, height: 844),
      isTrue,
    );
    expect(
      usesMobileDirectConversationSwipe(width: 1280, height: 720),
      isFalse,
    );
  });

  test('rooms render as responsive cards with visible state badges', () {
    final source = File(
      '${Directory.current.path}/lib/pages/chat_page.dart',
    ).readAsStringSync();
    final roomStripStart = source.indexOf('Widget _buildRoomStrip(');
    final directTabStart = source.indexOf('Widget _buildDirectTab(');

    expect(roomStripStart, greaterThanOrEqualTo(0));
    expect(directTabStart, greaterThan(roomStripStart));
    final roomSection = source.substring(roomStripStart, directTabStart);
    expect(roomSection, contains('LayoutBuilder'));
    expect(roomSection, contains('Widget _buildRoomCard('));
    expect(roomSection, contains("ValueKey('chat-room-card-"));
    expect(roomSection, contains("room.locallyJoined ? '已加入' : '点击加入'"));
    expect(roomSection, contains("requiresPassword ? '密码房' : '公开房'"));
    expect(roomSection, isNot(contains('ActionChip(')));
  });

  test('800x600 Windows chat window uses compact single panel layout', () {
    expect(isCompactChatWindow(width: 800, height: 600), isTrue);
    expect(usesCompactChatNavigation(width: 800, height: 600), isTrue);
    expect(usesSinglePanelChatLayout(width: 800, height: 600), isTrue);
  });

  test('large Windows chat window keeps desktop split panel layout', () {
    expect(isCompactChatWindow(width: 1280, height: 720), isFalse);
    expect(usesCompactChatNavigation(width: 1280, height: 720), isFalse);
    expect(usesSinglePanelChatLayout(width: 1280, height: 720), isFalse);
  });
}

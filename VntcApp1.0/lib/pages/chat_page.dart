import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_security.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/toast_utils.dart';
import 'package:url_launcher/url_launcher.dart';

bool isCompactChatWindow({required double width, required double height}) {
  return width < 900 || height < 700;
}

bool usesCompactChatNavigation({
  required double width,
  required double height,
}) {
  return width < 900 || height < 700;
}

bool usesSinglePanelChatLayout({
  required double width,
  required double height,
}) {
  return width < 980 || height < 620;
}

bool usesMobileDirectConversationSwipe({
  required double width,
  required double height,
}) {
  return (width < height ? width : height) < 600;
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with SingleTickerProviderStateMixin {
  final ChatManager _manager = ChatManager.instance;
  final TextEditingController _textController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _audioRecorder = AudioRecorder();
  late final TabController _tabController;
  int _lastHandledTabIndex = 0;
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  String? _playingAttachmentId;
  final Set<String> _pendingDeletedConversationIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: ChatMainTab.values.length,
      vsync: this,
    );
    _tabController.addListener(() {
      if (_tabController.index != _lastHandledTabIndex) {
        _lastHandledTabIndex = _tabController.index;
        _manager.selectTab(ChatMainTab.values[_tabController.index]);
      }
    });
    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) {
        return;
      }
      if (!state.playing ||
          state.processingState == ProcessingState.completed ||
          state.processingState == ProcessingState.idle) {
        if (_playingAttachmentId != null) {
          setState(() {
            _playingAttachmentId = null;
          });
        }
      }
    });
    _manager.start();
  }

  @override
  void dispose() {
    _textController.dispose();
    _audioRecorder.dispose();
    unawaited(_audioPlayer.dispose());
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final windowSize = MediaQuery.sizeOf(context);
    final compactLayout = isCompactChatWindow(
      width: windowSize.width,
      height: windowSize.height,
    );
    final compactNavigation = usesCompactChatNavigation(
      width: windowSize.width,
      height: windowSize.height,
    );
    final targetTabIndex = _manager.selectedTab.index;
    if (_tabController.index != targetTabIndex) {
      _lastHandledTabIndex = targetTabIndex;
      _tabController.index = targetTabIndex;
    }

    return Scaffold(
      backgroundColor:
          isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _manager,
          builder: (context, _) {
            if (!_manager.supported) {
              return _buildUnsupported(context, isDark);
            }

            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.all(
                    compactLayout ? context.spacingSmall : context.spacingLarge,
                  ),
                  child: _buildHeader(
                    context,
                    isDark,
                    compact: compactLayout,
                    showNavigationMenu: compactNavigation,
                  ),
                ),
                if (!compactNavigation)
                  Container(
                    margin: EdgeInsets.symmetric(
                      horizontal: context.spacingLarge,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TabBar(
                            controller: _tabController,
                            tabAlignment: TabAlignment.fill,
                            labelColor: Theme.of(context).primaryColor,
                            unselectedLabelColor: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                            dividerColor: isDark
                                ? Colors.white.withValues(alpha: 0.05)
                                : Colors.black.withValues(alpha: 0.05),
                            indicatorColor: Theme.of(context).primaryColor,
                            indicatorSize: TabBarIndicatorSize.tab,
                            tabs: [
                              const Tab(text: '大厅'),
                              const Tab(text: '房间'),
                              const Tab(text: '在线'),
                              Tab(
                                child: _buildDirectTabLabel(
                                  context,
                                  isDark,
                                  unreadCount: _manager.privateUnreadTotal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: _manager.loading && _manager.halls.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildHallTab(context, isDark),
                            _buildRoomsTab(context, isDark),
                            _buildOnlineTab(context, isDark),
                            _buildDirectTab(context, isDark),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    bool isDark, {
    required bool compact,
    required bool showNavigationMenu,
  }) {
    final primaryColor = Theme.of(context).primaryColor;
    return Row(
      children: [
        Container(
          width: compact ? context.iconLarge : context.iconXLarge,
          height: compact ? context.iconLarge : context.iconXLarge,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryColor, primaryColor.withValues(alpha: 0.75)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(
              compact ? context.radius(10) : context.cardRadius,
            ),
          ),
          child: Icon(
            Icons.forum,
            color: Colors.white,
            size: compact ? context.iconMedium : context.iconLarge,
          ),
        ),
        SizedBox(width: context.spacingMedium),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '聊天室',
                style: TextStyle(
                  fontSize: context.fontXLarge,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              if (!compact)
                Text(
                  '基于 VNT 虚拟组网的大厅、房间与在线私聊',
                  style: TextStyle(
                    fontSize: context.fontBody,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: _manager.loading
              ? null
              : () async {
                  await _manager.refresh();
                },
          tooltip: '刷新聊天室状态',
          icon: Icon(
            Icons.refresh,
            color:
                isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          ),
        ),
        if (showNavigationMenu) _buildCompactNavigationMenu(context, isDark),
      ],
    );
  }

  Widget _buildCompactNavigationMenu(BuildContext context, bool isDark) {
    final selectedTab = _manager.selectedTab;
    return PopupMenuButton<ChatMainTab>(
      initialValue: selectedTab,
      onSelected: _selectMainTab,
      tooltip: '切换聊天页面',
      icon: Icon(
        Icons.menu_rounded,
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
      ),
      itemBuilder: (context) => ChatMainTab.values.map((tab) {
        final unreadCount =
            tab == ChatMainTab.direct ? _manager.privateUnreadTotal : 0;
        return PopupMenuItem<ChatMainTab>(
          value: tab,
          child: Row(
            children: [
              SizedBox(
                width: context.iconLarge,
                child: Icon(
                  tab == selectedTab ? Icons.check_rounded : _tabIcon(tab),
                  size: context.iconMedium,
                  color: tab == selectedTab
                      ? Theme.of(context).primaryColor
                      : null,
                ),
              ),
              SizedBox(width: context.spacingSmall),
              Expanded(child: Text(_tabLabel(tab))),
              if (unreadCount > 0)
                Text(
                  unreadCount > 99 ? '99+' : '$unreadCount',
                  style: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  void _selectMainTab(ChatMainTab tab) {
    _lastHandledTabIndex = tab.index;
    _manager.selectTab(tab);
    if (_tabController.index != tab.index) {
      _tabController.animateTo(tab.index);
    }
  }

  String _tabLabel(ChatMainTab tab) {
    return switch (tab) {
      ChatMainTab.hall => '大厅',
      ChatMainTab.rooms => '房间',
      ChatMainTab.online => '在线',
      ChatMainTab.direct => '私聊',
    };
  }

  IconData _tabIcon(ChatMainTab tab) {
    return switch (tab) {
      ChatMainTab.hall => Icons.public_rounded,
      ChatMainTab.rooms => Icons.meeting_room_outlined,
      ChatMainTab.online => Icons.people_outline_rounded,
      ChatMainTab.direct => Icons.chat_bubble_outline_rounded,
    };
  }

  Widget _buildDirectTabLabel(
    BuildContext context,
    bool isDark, {
    required int unreadCount,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('私聊'),
        if (unreadCount > 0) ...[
          SizedBox(width: context.spacingXSmall),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.spacingXSmall,
              vertical: context.spacingXXSmall,
            ),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(context.radius(999)),
            ),
            child: Text(
              unreadCount > 99 ? '99+' : '$unreadCount',
              style: TextStyle(
                fontSize: context.fontXSmall,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHallTab(BuildContext context, bool isDark) {
    if (_manager.halls.isEmpty) {
      final hasVntConnection = _manager.hasActiveVntConnections;
      final startupIssue = _manager.chatStartupIssue;
      final baseMessage = hasVntConnection
          ? _manager.lastVntConnectionIssue == null
              ? '已检测到 VNT 连接，正在读取 VNT 大厅和虚拟组网状态。'
              : '已检测到 VNT 连接，但还没有可用于聊天室的虚拟 IP 或网段：${_manager.lastVntConnectionIssue}'
          : '先去连接一个虚拟组网配置，聊天室才会出现公共大厅和在线用户。';
      return _buildEmptyState(
        context,
        isDark,
        title: hasVntConnection ? '正在读取 VNT 大厅' : '尚未连接任何 VNT 大厅',
        message:
            startupIssue == null ? baseMessage : '$baseMessage\n$startupIssue',
        icon: hasVntConnection
            ? Icons.wifi_find_outlined
            : Icons.wifi_off_outlined,
      );
    }

    final selectedHallId = _manager.selectedHallId ?? _manager.halls.first.id;
    final selectedConversation = _resolveHallConversation(selectedHallId);
    final startupIssue = _manager.chatStartupIssue;

    return Column(
      children: [
        if (startupIssue != null)
          _buildStartupIssueBanner(context, isDark, startupIssue),
        Expanded(
          child: _buildHallContent(context, isDark, selectedConversation),
        ),
      ],
    );
  }

  Widget _buildOnlineTab(BuildContext context, bool isDark) {
    if (_manager.halls.isEmpty) {
      return _buildEmptyState(
        context,
        isDark,
        title: '暂无在线用户',
        message: '连接 VNT 虚拟组网后，这里会显示同一大厅内可私聊的用户。',
        icon: Icons.people_outline,
      );
    }
    final selectedHallId = _manager.selectedHallId ?? _manager.halls.first.id;
    return Column(
      children: [
        _buildHallCardStrip(context, isDark, selectedHallId),
        Expanded(child: _buildHallUsersPanel(context, isDark, selectedHallId)),
      ],
    );
  }

  Widget _buildRoomsTab(BuildContext context, bool isDark) {
    if (_manager.halls.isEmpty) {
      return _buildEmptyState(
        context,
        isDark,
        title: '暂无群组房间',
        message: '先连接 VNT 虚拟组网，再使用房间页右下角“＋”创建房间。',
        icon: Icons.meeting_room_outlined,
      );
    }
    final selectedHallId = _manager.selectedHallId ?? _manager.halls.first.id;
    final selected = _manager.selectedConversation;
    final selectedRoom = selected?.hallId == selectedHallId &&
            selected?.type == ChatConversationType.room
        ? selected
        : null;
    final windowSize = MediaQuery.sizeOf(context);
    final compact = usesSinglePanelChatLayout(
      width: windowSize.width,
      height: windowSize.height,
    );
    if (compact && selectedRoom != null) {
      return _buildConversationPanel(
        context,
        isDark,
        selectedRoom,
        emptyTitle: '请选择群组房间',
        emptyMessage: '选择已加入的房间，或加入同一大厅内其他用户创建的房间。',
        onBack: () =>
            _manager.clearSelectedConversation(type: ChatConversationType.room),
      );
    }
    final content = compact
        ? Column(
            children: [
              _buildHallCardStrip(context, isDark, selectedHallId),
              Expanded(
                child: SingleChildScrollView(
                  child: _buildRoomStrip(
                    context,
                    isDark,
                    selectedHallId,
                    selectedRoom,
                  ),
                ),
              ),
            ],
          )
        : Column(
            children: [
              _buildHallCardStrip(context, isDark, selectedHallId),
              _buildRoomStrip(context, isDark, selectedHallId, selectedRoom),
              Expanded(
                child: _buildConversationPanel(
                  context,
                  isDark,
                  selectedRoom,
                  emptyTitle: '请选择群组房间',
                  emptyMessage: '选择已加入的房间，或加入同一大厅内其他用户创建的房间。',
                ),
              ),
            ],
          );
    final actionBottom = selectedRoom == null
        ? context.spacingLarge
        : context.spacingLarge + context.w(88);
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned(
          right: context.spacingLarge,
          bottom: actionBottom,
          child: FloatingActionButton.small(
            heroTag: 'chat-create-room',
            onPressed: () => _showCreateRoomDialog(selectedHallId),
            tooltip: '创建房间',
            child: const Icon(Icons.add_rounded),
          ),
        ),
      ],
    );
  }

  Widget _buildStartupIssueBanner(
    BuildContext context,
    bool isDark,
    String message,
  ) {
    final warningColor = Colors.orange.shade700;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(
        context.spacingLarge,
        context.spacingMedium,
        context.spacingLarge,
        0,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingMedium,
        vertical: context.spacingSmall,
      ),
      decoration: BoxDecoration(
        color: warningColor.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(context.cardRadius),
        border: Border.all(
          color: warningColor.withValues(alpha: isDark ? 0.42 : 0.28),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: warningColor,
            size: context.iconMedium,
          ),
          SizedBox(width: context.spacingSmall),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHallUsersPanel(
    BuildContext context,
    bool isDark,
    String hallId,
  ) {
    final peers = _manager.hallPeers(hallId);
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.spacingLarge,
        context.spacingLarge,
        context.spacingSmall,
        context.spacingLarge,
      ),
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在线用户',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingSmall),
          Text(
            '仅显示可直接聊天的在线节点',
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          Expanded(
            child: peers.isEmpty
                ? Center(
                    child: Text(
                      '当前大厅暂无在线聊天用户',
                      style: TextStyle(
                        fontSize: context.fontBody,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: peers.length,
                    separatorBuilder: (_, __) =>
                        SizedBox(height: context.spacingSmall),
                    itemBuilder: (context, index) {
                      final peer = peers[index];
                      return _buildPeerCard(context, isDark, peer);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerCard(
    BuildContext context,
    bool isDark,
    ChatPeerPresence peer,
  ) {
    final primaryColor = Theme.of(context).primaryColor;
    return GestureDetector(
      onTap: () => _openPeer(peer),
      onSecondaryTapDown: (details) =>
          _showPeerMenu(context, details.globalPosition, peer),
      child: Container(
        padding: EdgeInsets.all(context.spacingMedium),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(context.cardRadius),
          border: Border.all(color: primaryColor.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Container(
              width: context.iconLarge,
              height: context.iconLarge,
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(context.radius(12)),
              ),
              child: Icon(
                Icons.person_outline,
                color: primaryColor,
                size: context.iconMedium,
              ),
            ),
            SizedBox(width: context.spacingSmall),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.displayName,
                    style: TextStyle(
                      fontSize: context.fontMedium,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  SizedBox(height: context.spacingXXSmall),
                  Text(
                    peer.virtualIp,
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: context.w(10),
              height: context.w(10),
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHallContent(
    BuildContext context,
    bool isDark,
    ChatConversation? selectedConversation,
  ) {
    return _buildConversationPanel(
      context,
      isDark,
      selectedConversation,
      emptyTitle: '暂无公共大厅会话',
      emptyMessage: '连接 VNT 虚拟组网后即可进入公共大厅聊天。',
    );
  }

  Widget _buildHallCardStrip(
    BuildContext context,
    bool isDark,
    String selectedHallId,
  ) {
    return SizedBox(
      height: context.w(120),
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
          context.spacingSmall,
          context.spacingLarge,
          context.spacingLarge,
          context.spacingSmall,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: _manager.halls.length,
        separatorBuilder: (_, __) => SizedBox(width: context.spacingSmall),
        itemBuilder: (context, index) {
          final hall = _manager.halls[index];
          final isSelected = hall.id == selectedHallId;
          return InkWell(
            onTap: () => _manager.selectHall(hall.id),
            borderRadius: BorderRadius.circular(context.cardRadius),
            child: Container(
              width: context.w(260),
              padding: EdgeInsets.all(context.cardPadding),
              decoration: BoxDecoration(
                color: isSelected
                    ? Theme.of(context).primaryColor.withValues(alpha: 0.12)
                    : (isDark
                        ? AppTheme.darkCardBackground
                        : AppTheme.lightCardBackground),
                borderRadius: BorderRadius.circular(context.cardRadius),
                border: Border.all(
                  color: isSelected
                      ? Theme.of(context).primaryColor.withValues(alpha: 0.45)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.05)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hall.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fontMedium,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  SizedBox(height: context.spacingXSmall),
                  Text(
                    hall.connectServer.isEmpty
                        ? '未解析服务器地址'
                        : hall.connectServer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  SizedBox(height: context.spacingXSmall),
                  Text(
                    '本机 ${hall.localVirtualIp}',
                    style: TextStyle(
                      fontSize: context.fontXSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRoomStrip(
    BuildContext context,
    bool isDark,
    String selectedHallId,
    ChatConversation? selectedConversation,
  ) {
    final rooms = _manager.hallRooms(selectedHallId);
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.spacingSmall,
        0,
        context.spacingLarge,
        context.spacingSmall,
      ),
      padding: EdgeInsets.all(context.cardPaddingSmall),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rooms.isEmpty)
            Text(
              '暂无房间，请使用右下角“＋”创建。',
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columnCount = constraints.maxWidth >= 900
                    ? 3
                    : constraints.maxWidth >= 560
                        ? 2
                        : 1;
                final cardWidth = (constraints.maxWidth -
                        context.spacingSmall * (columnCount - 1)) /
                    columnCount;
                return Wrap(
                  spacing: context.spacingSmall,
                  runSpacing: context.spacingSmall,
                  children: rooms
                      .map(
                        (room) => SizedBox(
                          width: cardWidth,
                          child: _buildRoomCard(
                            context,
                            isDark,
                            room,
                            isSelected: selectedConversation?.id == room.roomId,
                          ),
                        ),
                      )
                      .toList(growable: false),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildRoomCard(
    BuildContext context,
    bool isDark,
    ChatRoomDescriptor room, {
    required bool isSelected,
  }) {
    final primaryColor = Theme.of(context).primaryColor;
    final requiresPassword = chatRoomRequiresPassword(room.metadataJson);
    return Card(
      key: ValueKey('chat-room-card-${room.roomId}'),
      margin: EdgeInsets.zero,
      elevation: isSelected ? 2 : 0,
      color: isSelected
          ? primaryColor.withValues(alpha: isDark ? 0.16 : 0.08)
          : (isDark
              ? Colors.white.withValues(alpha: 0.035)
              : Colors.black.withValues(alpha: 0.018)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.cardRadius),
        side: BorderSide(
          color: isSelected
              ? primaryColor.withValues(alpha: 0.65)
              : room.isActive
                  ? primaryColor.withValues(alpha: 0.25)
                  : Colors.grey.withValues(alpha: 0.20),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openOrJoinRoom(room),
        child: Padding(
          padding: EdgeInsets.all(context.cardPaddingSmall),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: context.iconXLarge,
                    height: context.iconXLarge,
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(context.radius(12)),
                    ),
                    child: Icon(
                      requiresPassword
                          ? Icons.lock_outline_rounded
                          : Icons.meeting_room_outlined,
                      color: primaryColor,
                    ),
                  ),
                  SizedBox(width: context.spacingSmall),
                  Expanded(
                    child: Text(
                      room.roomName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.fontMedium,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ],
              ),
              SizedBox(height: context.spacingSmall),
              Text(
                '创建者 ${room.creatorVirtualIp}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
              SizedBox(height: context.spacingSmall),
              Wrap(
                spacing: context.spacingXSmall,
                runSpacing: context.spacingXSmall,
                children: [
                  _buildRoomStatusBadge(
                    context,
                    icon: room.locallyJoined
                        ? Icons.check_circle_outline_rounded
                        : Icons.login_rounded,
                    label: room.locallyJoined ? '已加入' : '点击加入',
                    color: room.locallyJoined ? Colors.green : primaryColor,
                  ),
                  _buildRoomStatusBadge(
                    context,
                    icon: room.isActive
                        ? Icons.wifi_rounded
                        : Icons.history_rounded,
                    label: room.isActive ? '在线' : '历史',
                    color: room.isActive ? Colors.green : Colors.grey,
                  ),
                  _buildRoomStatusBadge(
                    context,
                    icon: requiresPassword
                        ? Icons.lock_outline_rounded
                        : Icons.lock_open_rounded,
                    label: requiresPassword ? '密码房' : '公开房',
                    color: requiresPassword ? Colors.orange : Colors.blueGrey,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoomStatusBadge(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingXSmall,
        vertical: context.spacingXXSmall,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(context.radius(999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: context.iconXSmall, color: color),
          SizedBox(width: context.spacingXXSmall),
          Text(
            label,
            style: TextStyle(
              fontSize: context.fontXSmall,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openOrJoinRoom(ChatRoomDescriptor room) async {
    if (room.locallyJoined) {
      await _manager.openConversation(room.roomId);
      return;
    }
    final password = chatRoomRequiresPassword(room.metadataJson)
        ? await _showJoinRoomPasswordDialog(room)
        : '';
    if (password == null) {
      return;
    }
    try {
      await _manager.joinRoom(room, password: password);
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        '已加入 ${room.roomName}',
        isSuccess: true,
      );
    } catch (error) {
      if (mounted) {
        showTopToast(
          context,
          error.toString().contains('密码错误') ? '房间密码错误' : '加入房间失败: $error',
          isSuccess: false,
        );
      }
    }
  }

  Widget _buildDirectTab(BuildContext context, bool isDark) {
    final conversations = _manager.directConversations
        .where(
          (conversation) =>
              !_pendingDeletedConversationIds.contains(conversation.id),
        )
        .toList(growable: false);
    final selectedConversation =
        _manager.selectedConversation?.type == ChatConversationType.direct
            ? _manager.selectedConversation
            : null;
    final windowSize = MediaQuery.sizeOf(context);
    final isWide = !usesSinglePanelChatLayout(
      width: windowSize.width,
      height: windowSize.height,
    );

    if (conversations.isEmpty) {
      return _buildEmptyState(
        context,
        isDark,
        title: '还没有私聊会话',
        message: '去大厅左侧点一个在线用户，或者右键在线用户发起私聊。',
        icon: Icons.mark_chat_unread_outlined,
      );
    }

    final listPanel = _buildDirectConversationList(
      context,
      isDark,
      conversations,
      allowSwipeDelete: usesMobileDirectConversationSwipe(
        width: windowSize.width,
        height: windowSize.height,
      ),
    );
    final chatPanel = _buildConversationPanel(
      context,
      isDark,
      selectedConversation,
      emptyTitle: '请选择一个私聊会话',
      emptyMessage: '左侧会显示最近的私聊会话，点击后即可继续聊天。',
      onBack: isWide || selectedConversation == null
          ? null
          : () => _manager.clearSelectedConversation(
                type: ChatConversationType.direct,
              ),
    );

    if (isWide) {
      return Row(
        children: [
          SizedBox(width: context.w(320), child: listPanel),
          Expanded(child: chatPanel),
        ],
      );
    }

    return selectedConversation == null ? listPanel : chatPanel;
  }

  Widget _buildDirectConversationList(
    BuildContext context,
    bool isDark,
    List<ChatConversation> conversations, {
    required bool allowSwipeDelete,
  }) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.spacingLarge,
        context.spacingLarge,
        context.spacingSmall,
        context.spacingLarge,
      ),
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: ListView.separated(
        itemCount: conversations.length,
        separatorBuilder: (_, __) => SizedBox(height: context.spacingSmall),
        itemBuilder: (context, index) {
          final conversation = conversations[index];
          final isSelected = conversation.id == _manager.selectedConversationId;
          final conversationCard = InkWell(
            onTap: () async {
              await _manager.selectTab(ChatMainTab.direct);
              await _manager.openConversation(conversation.id);
            },
            borderRadius: BorderRadius.circular(context.cardRadius),
            child: Container(
              padding: EdgeInsets.all(context.spacingMedium),
              decoration: BoxDecoration(
                color: isSelected
                    ? Theme.of(context).primaryColor.withValues(alpha: 0.12)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.02)),
                borderRadius: BorderRadius.circular(context.cardRadius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.fontMedium,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.lightTextPrimary,
                          ),
                        ),
                        SizedBox(height: context.spacingXXSmall),
                        Text(
                          conversation.peerVirtualIp ?? '未知用户',
                          style: TextStyle(
                            fontSize: context.fontSmall,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (conversation.unreadCount > 0)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.spacingSmall,
                        vertical: context.spacingXXSmall,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(
                          context.radius(999),
                        ),
                      ),
                      child: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                        style: TextStyle(
                          fontSize: context.fontXSmall,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  SizedBox(width: context.spacingSmall),
                  IconButton(
                    tooltip: '删除会话',
                    onPressed: () =>
                        _confirmAndDeleteDirectConversation(conversation),
                    icon: const Icon(Icons.delete_outline_rounded),
                    color: AppTheme.errorColor,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          );
          if (!allowSwipeDelete) {
            return conversationCard;
          }
          return Dismissible(
            key: ValueKey('direct-conversation-${conversation.id}'),
            direction: DismissDirection.endToStart,
            confirmDismiss: (_) =>
                _confirmDeleteDirectConversation(conversation),
            onDismissed: (_) => unawaited(
              _deleteDirectConversation(
                conversation,
                hideImmediately: true,
              ),
            ),
            background: Container(
              padding: EdgeInsets.symmetric(horizontal: context.spacingLarge),
              alignment: Alignment.centerRight,
              decoration: BoxDecoration(
                color: AppTheme.errorColor,
                borderRadius: BorderRadius.circular(context.cardRadius),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline_rounded, color: Colors.white),
                  SizedBox(width: 6),
                  Text('删除', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
            child: conversationCard,
          );
        },
      ),
    );
  }

  Widget _buildConversationPanel(
    BuildContext context,
    bool isDark,
    ChatConversation? conversation, {
    required String emptyTitle,
    required String emptyMessage,
    VoidCallback? onBack,
  }) {
    if (conversation == null) {
      return _buildEmptyState(
        context,
        isDark,
        title: emptyTitle,
        message: emptyMessage,
        icon: Icons.chat_bubble_outline,
      );
    }

    final messages = _manager.selectedConversationId == conversation.id
        ? _manager.selectedMessages
        : const <ChatMessageRecord>[];
    final windowSize = MediaQuery.sizeOf(context);
    final compact = isCompactChatWindow(
      width: windowSize.width,
      height: windowSize.height,
    );

    return Container(
      margin: EdgeInsets.fromLTRB(
        context.spacingSmall,
        compact ? context.spacingSmall : context.spacingLarge,
        compact ? context.spacingSmall : context.spacingLarge,
        compact ? context.spacingSmall : context.spacingLarge,
      ),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(
              compact ? context.cardPaddingSmall : context.cardPadding,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                if (onBack != null) ...[
                  IconButton(
                    onPressed: onBack,
                    tooltip: '返回会话列表',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  SizedBox(width: context.spacingXSmall),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.title,
                        style: TextStyle(
                          fontSize: context.fontLarge,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                        ),
                      ),
                      SizedBox(height: context.spacingXXSmall),
                      Text(
                        _conversationSubtitle(conversation),
                        style: TextStyle(
                          fontSize: context.fontSmall,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if ((conversation.type == ChatConversationType.hall ||
                        conversation.type == ChatConversationType.direct) &&
                    messages.isNotEmpty)
                  IconButton(
                    onPressed: () =>
                        _confirmClearConversationHistory(conversation),
                    tooltip: '清理聊天记录',
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                if (conversation.type == ChatConversationType.room)
                  TextButton(
                    onPressed: () async {
                      final room = _manager.rooms
                          .where((item) => item.roomId == conversation.id)
                          .cast<ChatRoomDescriptor?>()
                          .firstWhere((_) => true, orElse: () => null);
                      if (room != null && room.locallyJoined) {
                        await _manager.leaveRoom(room);
                        if (!mounted) {
                          return;
                        }
                        showTopToast(
                          this.context,
                          '已退出 ${room.roomName}',
                          isSuccess: true,
                        );
                      }
                    },
                    child: const Text('退出房间'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      '还没有消息，先发第一句吧',
                      style: TextStyle(
                        fontSize: context.fontBody,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.all(context.cardPadding),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _buildMessageBubble(context, isDark, message);
                    },
                  ),
          ),
          _buildComposer(context, isDark, conversation),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(
    BuildContext context,
    bool isDark,
    ChatMessageRecord message,
  ) {
    final isOutgoing = message.direction == ChatMessageDirection.outgoing;
    final bubbleColor = isOutgoing
        ? Theme.of(context).primaryColor.withValues(alpha: 0.14)
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.03));
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final transferProgress = isOutgoing && message.hasAttachment
        ? _manager.attachmentTransferProgressFor(message.id)
        : null;

    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onSecondaryTapDown: (details) =>
          unawaited(_showMessageMenu(context, details.globalPosition, message)),
      child: Align(
        alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.w(560)),
          child: Container(
            margin: EdgeInsets.only(bottom: context.spacingSmall),
            padding: EdgeInsets.all(context.spacingMedium),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(context.cardRadius),
            ),
            child: Column(
              crossAxisAlignment: isOutgoing
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontSize: context.fontXSmall,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
                SizedBox(height: context.spacingXXSmall),
                _buildMessageContent(context, isDark, message, textColor),
                if (transferProgress?.isActive == true) ...[
                  SizedBox(height: context.spacingSmall),
                  _buildAttachmentTransferProgress(
                    context,
                    isDark,
                    transferProgress!,
                  ),
                ],
                SizedBox(height: context.spacingXXSmall),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.hasAttachment) ...[
                      IconButton(
                        onPressed: message.attachment?.payloadAvailable == true
                            ? () => _saveAttachmentAs(message.attachment!)
                            : null,
                        tooltip: message.attachment?.payloadAvailable == true
                            ? '下载附件'
                            : '附件内容不可用',
                        icon: const Icon(Icons.download_outlined),
                        iconSize: context.iconXSmall,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                      ),
                      SizedBox(width: context.spacingXXSmall),
                    ],
                    Text(
                      _formatTime(message.sentAtEpochMs),
                      style: TextStyle(
                        fontSize: context.fontXSmall,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                    if (message.status == ChatMessageStatus.failed) ...[
                      SizedBox(width: context.spacingXSmall),
                      Text(
                        '发送失败',
                        style: TextStyle(
                          fontSize: context.fontXSmall,
                          color: Colors.red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(width: context.spacingXSmall),
                      InkWell(
                        onTap: () => _retryMessage(message),
                        child: Text(
                          '重发',
                          style: TextStyle(
                            fontSize: context.fontXSmall,
                            color: Theme.of(context).primaryColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentTransferProgress(
    BuildContext context,
    bool isDark,
    ChatAttachmentTransferProgress progress,
  ) {
    final label = progress.phase == ChatAttachmentTransferPhase.preparing
        ? '准备上传'
        : '上传中';
    final secondaryColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return SizedBox(
      width: context.w(280),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.upload_file_outlined,
                size: context.fontSmall,
                color: Theme.of(context).primaryColor,
              ),
              SizedBox(width: context.spacingXXSmall),
              Text(
                '$label ${progress.progressPercent}%',
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: secondaryColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${_formatFileSize(progress.bytesPerSecond)}/s',
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: secondaryColor,
                ),
              ),
            ],
          ),
          SizedBox(height: context.spacingXXSmall),
          LinearProgressIndicator(
            value: progress.progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(
    BuildContext context,
    bool isDark,
    ChatMessageRecord message,
    Color textColor,
  ) {
    if (message.contentType == ChatMessageContentType.text ||
        message.attachment == null) {
      return Text(
        message.text,
        style: TextStyle(fontSize: context.fontBody, color: textColor),
      );
    }

    final attachment = message.attachment!;
    if (!attachment.payloadAvailable) {
      return _buildAttachmentPlaceholder(
        context,
        isDark,
        attachment,
        hint: attachment.needsManualResend ? '附件未自动补齐，需要发送方手动重发' : '附件内容暂不可用',
      );
    }

    if (message.contentType == ChatMessageContentType.image) {
      return FutureBuilder<String>(
        future: _manager.resolveAttachmentPath(attachment),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _buildAttachmentPlaceholder(
              context,
              isDark,
              attachment,
              hint: '正在加载图片...',
            );
          }
          return InkWell(
            onTap: () => _openAttachmentFile(attachment),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(context.radius(12)),
                  child: Image.file(
                    File(snapshot.data!),
                    width: context.w(260),
                    height: context.w(180),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildAttachmentPlaceholder(
                      context,
                      isDark,
                      attachment,
                      hint: '图片加载失败，可点击尝试打开文件',
                    ),
                  ),
                ),
                SizedBox(height: context.spacingXSmall),
                Text(
                  attachment.fileName,
                  style: TextStyle(
                    fontSize: context.fontSmall,
                    color: textColor,
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    if (message.contentType == ChatMessageContentType.voice) {
      final isPlaying = _playingAttachmentId == attachment.id;
      return InkWell(
        onTap: () => _toggleVoicePlayback(attachment),
        borderRadius: BorderRadius.circular(context.radius(12)),
        child: Container(
          padding: EdgeInsets.all(context.spacingSmall),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(context.radius(12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: Theme.of(context).primaryColor,
              ),
              SizedBox(width: context.spacingSmall),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.fileName,
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _formatDuration(attachment.durationMs),
                    style: TextStyle(
                      fontSize: context.fontXSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => _openAttachmentFile(attachment),
      borderRadius: BorderRadius.circular(context.radius(12)),
      child: Container(
        padding: EdgeInsets.all(context.spacingSmall),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(context.radius(12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              message.contentType == ChatMessageContentType.video
                  ? Icons.video_file_outlined
                  : Icons.insert_drive_file_outlined,
              color: Theme.of(context).primaryColor,
            ),
            SizedBox(width: context.spacingSmall),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: context.w(240)),
                  child: Text(
                    attachment.fileName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: textColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _formatFileSize(attachment.sizeBytes),
                  style: TextStyle(
                    fontSize: context.fontXSmall,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentPlaceholder(
    BuildContext context,
    bool isDark,
    ChatAttachmentRecord attachment, {
    required String hint,
  }) {
    return Container(
      padding: EdgeInsets.all(context.spacingSmall),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(context.radius(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            attachment.fileName,
            style: TextStyle(
              fontSize: context.fontSmall,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingXXSmall),
          Text(
            hint,
            style: TextStyle(
              fontSize: context.fontXSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingXXSmall),
          Text(
            _formatFileSize(attachment.sizeBytes),
            style: TextStyle(
              fontSize: context.fontXSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context,
    bool isDark,
    ChatConversation conversation,
  ) {
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _pickAndSendAttachment(conversation),
            tooltip: '发送图片/视频/文件',
            icon: const Icon(Icons.attach_file),
          ),
          IconButton(
            onPressed: () => _toggleVoiceRecording(conversation),
            tooltip: _isRecording ? '结束录音并发送' : '录制语音消息',
            icon: Icon(
              _isRecording
                  ? Icons.stop_circle_outlined
                  : Icons.mic_none_outlined,
              color: _isRecording ? Colors.red : null,
            ),
          ),
          Expanded(
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(
                  LogicalKeyboardKey.enter,
                  includeRepeats: false,
                ): _SubmitChatComposerIntent(),
                SingleActivator(
                  LogicalKeyboardKey.numpadEnter,
                  includeRepeats: false,
                ): _SubmitChatComposerIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _SubmitChatComposerIntent: _SubmitChatComposerAction(
                    shouldHandle: _shouldHandleComposerSubmitShortcut,
                    onSubmit: () => _submitComposerFromKeyboard(conversation),
                  ),
                },
                child: TextField(
                  controller: _textController,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(hintText: '输入消息后按发送'),
                ),
              ),
            ),
          ),
          SizedBox(width: context.spacingSmall),
          ElevatedButton.icon(
            onPressed: () => _sendCurrentText(conversation),
            icon: const Icon(Icons.send),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupported(BuildContext context, bool isDark) {
    return _buildEmptyState(
      context,
      isDark,
      title: '当前平台暂未接入聊天室',
      message: '聊天室当前支持 Windows、macOS 和 Android。',
      icon: Icons.desktop_mac_outlined,
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    bool isDark, {
    required String title,
    required String message,
    required IconData icon,
  }) {
    final primaryColor = Theme.of(context).primaryColor;
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: context.w(560)),
        margin: EdgeInsets.all(context.spacingLarge),
        padding: EdgeInsets.all(context.cardPadding),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.darkCardBackground
              : AppTheme.lightCardBackground,
          borderRadius: BorderRadius.circular(context.cardRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: context.w(72),
              height: context.w(72),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(context.radius(20)),
              ),
              child: Icon(icon, size: context.iconXLarge, color: primaryColor),
            ),
            SizedBox(height: context.spacingMedium),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fontLarge,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
              ),
            ),
            SizedBox(height: context.spacingSmall),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fontBody,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  ChatConversation? _resolveHallConversation(String selectedHallId) {
    final selected = _manager.selectedConversation;
    if (selected != null &&
        selected.hallId == selectedHallId &&
        selected.type != ChatConversationType.direct) {
      return selected;
    }

    for (final conversation in _manager.conversations) {
      if (conversation.id == selectedHallId &&
          conversation.type == ChatConversationType.hall) {
        return conversation;
      }
    }
    return null;
  }

  String _conversationSubtitle(ChatConversation conversation) {
    switch (conversation.type) {
      case ChatConversationType.hall:
        return '公共大厅';
      case ChatConversationType.direct:
        return conversation.peerVirtualIp ?? '私聊';
      case ChatConversationType.room:
        return '自定义聊天室';
    }
  }

  String _formatTime(int epochMs) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _openPeer(ChatPeerPresence peer) async {
    await _manager.openDirectChat(peer);
    if (!mounted) {
      return;
    }
    _tabController.index = ChatMainTab.direct.index;
  }

  Future<void> _showPeerMenu(
    BuildContext context,
    Offset position,
    ChatPeerPresence peer,
  ) async {
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem<String>(value: 'direct', child: Text('发起私聊')),
      ],
    );
    if (value == 'direct' && mounted) {
      await _openPeer(peer);
    }
  }

  Future<void> _showMessageMenu(
    BuildContext context,
    Offset position,
    ChatMessageRecord message,
  ) async {
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.red),
              SizedBox(width: 8),
              Text('删除消息'),
            ],
          ),
        ),
      ],
    );
    if (value != 'delete' || !mounted) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: this.context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除消息'),
            content: const Text('确定删除这条消息吗？删除后无法恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }

    try {
      final deleted = await _manager.deleteMessage(message);
      if (!mounted) {
        return;
      }
      showTopToast(
        this.context,
        deleted ? '消息已删除' : '消息不存在或已被删除',
        isSuccess: deleted,
      );
    } catch (error) {
      if (mounted) {
        showTopToast(this.context, '删除消息失败: $error', isSuccess: false);
      }
    }
  }

  Future<bool> _confirmDeleteDirectConversation(
    ChatConversation conversation,
  ) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除私聊会话'),
            content: Text(
              '确定删除与“${conversation.title}”的私聊会话吗？\n\n'
              '本机会话、聊天记录和附件将被删除，且无法撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.errorColor,
                ),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _confirmAndDeleteDirectConversation(
    ChatConversation conversation,
  ) async {
    if (!await _confirmDeleteDirectConversation(conversation) || !mounted) {
      return;
    }
    await _deleteDirectConversation(conversation);
  }

  Future<void> _deleteDirectConversation(
    ChatConversation conversation, {
    bool hideImmediately = false,
  }) async {
    if (hideImmediately && mounted) {
      setState(() {
        _pendingDeletedConversationIds.add(conversation.id);
      });
    }
    try {
      final deleted = await _manager.deleteDirectConversation(conversation.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingDeletedConversationIds.remove(conversation.id);
      });
      showTopToast(
        context,
        deleted ? '私聊会话已删除' : '会话不存在或已被删除',
        isSuccess: deleted,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingDeletedConversationIds.remove(conversation.id);
      });
      showTopToast(context, '删除私聊会话失败: $error', isSuccess: false);
    }
  }

  Future<void> _confirmClearConversationHistory(
    ChatConversation conversation,
  ) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('清理聊天记录'),
            content: Text(
              '确定清理“${conversation.title}”中的全部聊天记录吗？\n\n'
              '此操作只清理本机记录，且无法撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('清理'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }

    try {
      final clearedCount = await _manager.clearConversationMessages(
        conversation.id,
      );
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        clearedCount > 0 ? '已清理 $clearedCount 条聊天记录' : '当前没有聊天记录',
        isSuccess: true,
      );
    } catch (error) {
      if (mounted) {
        showTopToast(context, '清理聊天记录失败: $error', isSuccess: false);
      }
    }
  }

  Future<void> _showCreateRoomDialog(String hallId) async {
    final nameController = TextEditingController();
    final passwordController = TextEditingController();
    try {
      final shouldCreate = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          var obscurePassword = true;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('创建群组房间'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '房间名称',
                      hintText: '例如 运维讨论组',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: '房间密码（可留空）',
                      suffixIcon: IconButton(
                        onPressed: () => setDialogState(
                          () => obscurePassword = !obscurePassword,
                        ),
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('创建'),
                ),
              ],
            ),
          );
        },
      );
      final roomName = nameController.text;
      if (shouldCreate != true || roomName.trim().isEmpty) {
        return;
      }
      await _manager.createRoom(
        hallId,
        roomName,
        password: passwordController.text,
      );
      if (!mounted) {
        return;
      }
      showTopToast(context, '聊天室已创建', isSuccess: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '创建聊天室失败: $error', isSuccess: false);
    } finally {
      nameController.dispose();
      passwordController.dispose();
    }
  }

  Future<String?> _showJoinRoomPasswordDialog(ChatRoomDescriptor room) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          var obscurePassword = true;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text('加入 ${room.roomName}'),
              content: TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: '房间密码',
                  suffixIcon: IconButton(
                    onPressed: () => setDialogState(
                      () => obscurePassword = !obscurePassword,
                    ),
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop(controller.text),
                  child: const Text('加入'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      controller.dispose();
    }
  }

  bool _shouldHandleComposerSubmitShortcut() {
    final composing = _textController.value.composing;
    return !composing.isValid || composing.isCollapsed;
  }

  void _submitComposerFromKeyboard(ChatConversation conversation) {
    if (!_shouldHandleComposerSubmitShortcut()) {
      return;
    }
    if (_textController.text.trim().isEmpty) {
      return;
    }
    unawaited(_sendCurrentText(conversation));
  }

  Future<void> _sendCurrentText(ChatConversation conversation) async {
    final text = _textController.text;
    _textController.clear();
    try {
      final result = await _manager.sendText(
        conversationId: conversation.id,
        text: text,
      );
      if (!mounted) {
        return;
      }
      if (result.isPartialSuccess || result.isFailure) {
        showTopToast(
          context,
          _buildSendResultMessage(
            result,
            successLabel: '消息已发送',
            partialLabel: '消息部分送达',
            failureLabel: '消息发送失败',
          ),
          isSuccess: result.isPartialSuccess,
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (_textController.text.isEmpty) {
        _textController.text = text;
      }
      showTopToast(context, '发送失败: $error', isSuccess: false);
    }
  }

  Future<void> _pickAndSendAttachment(ChatConversation conversation) async {
    try {
      final pickedResult = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
      );
      final filePath = pickedResult?.files.single.path;
      if (filePath == null || filePath.trim().isEmpty) {
        return;
      }
      final sendResult = await _manager.sendAttachment(
        conversationId: conversation.id,
        sourceFilePath: filePath,
      );
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        _buildSendResultMessage(
          sendResult,
          successLabel: '附件已发送',
          partialLabel: '附件部分送达',
          failureLabel: '附件发送失败',
        ),
        isSuccess: !sendResult.isFailure,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '附件发送失败: $error', isSuccess: false);
    }
  }

  Future<void> _toggleVoiceRecording(ChatConversation conversation) async {
    if (_isRecording) {
      await _stopAndSendVoice(conversation);
      return;
    }

    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        if (!mounted) {
          return;
        }
        showTopToast(context, '当前设备未授予录音权限', isSuccess: false);
        return;
      }
      final outputPath = path.join(
        Directory.systemTemp.path,
        'vnt_voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: outputPath,
      );
      setState(() {
        _isRecording = true;
        _recordingStartedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '开始录音失败: $error', isSuccess: false);
    }
  }

  Future<void> _stopAndSendVoice(ChatConversation conversation) async {
    final startedAt = _recordingStartedAt;
    try {
      final outputPath = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
        _recordingStartedAt = null;
      });
      if (outputPath == null || outputPath.trim().isEmpty) {
        return;
      }
      final durationMs = startedAt == null
          ? null
          : DateTime.now().difference(startedAt).inMilliseconds;
      final result = await _manager.sendAttachment(
        conversationId: conversation.id,
        sourceFilePath: outputPath,
        explicitContentType: ChatMessageContentType.voice,
        durationMs: durationMs,
      );
      try {
        await File(outputPath).delete();
      } catch (_) {
        // 临时录音删除失败不影响主流程
      }
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        _buildSendResultMessage(
          result,
          successLabel: '语音消息已发送',
          partialLabel: '语音消息部分送达',
          failureLabel: '语音发送失败',
        ),
        isSuccess: !result.isFailure,
      );
    } catch (error) {
      setState(() {
        _isRecording = false;
        _recordingStartedAt = null;
      });
      if (!mounted) {
        return;
      }
      showTopToast(context, '发送语音失败: $error', isSuccess: false);
    }
  }

  Future<void> _toggleVoicePlayback(ChatAttachmentRecord attachment) async {
    try {
      if (_playingAttachmentId == attachment.id) {
        await _audioPlayer.stop();
        if (!mounted) {
          return;
        }
        setState(() {
          _playingAttachmentId = null;
        });
        return;
      }

      final filePath = await _manager.resolveAttachmentPath(attachment);
      await _audioPlayer.setFilePath(filePath);
      if (!mounted) {
        return;
      }
      setState(() {
        _playingAttachmentId = attachment.id;
      });
      unawaited(_audioPlayer.play());
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '语音播放失败: $error', isSuccess: false);
    }
  }

  Future<void> _openAttachmentFile(ChatAttachmentRecord attachment) async {
    try {
      final filePath = await _manager.resolveAttachmentPath(attachment);
      final opened = await launchUrl(
        Uri.file(filePath),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        if (Platform.isAndroid) {
          await Share.shareXFiles([
            XFile(filePath, name: attachment.fileName),
          ], text: attachment.fileName);
          return;
        }
        if (mounted) {
          showTopToast(context, '系统未能打开该附件', isSuccess: false);
        }
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '打开附件失败: $error', isSuccess: false);
    }
  }

  Future<void> _saveAttachmentAs(ChatAttachmentRecord attachment) async {
    if (!attachment.payloadAvailable) {
      showTopToast(context, '附件内容不可用，无法下载', isSuccess: false);
      return;
    }

    try {
      final sourcePath = await _manager.resolveAttachmentPath(attachment);
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        throw StateError('附件缓存文件不存在');
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存附件',
        fileName: attachment.fileName,
        lockParentWindow: true,
      );
      if (savePath == null || savePath.trim().isEmpty) {
        return;
      }

      if (!path.equals(
        path.normalize(path.absolute(sourcePath)),
        path.normalize(path.absolute(savePath)),
      )) {
        await sourceFile.copy(savePath);
      }
      if (mounted) {
        showTopToast(context, '附件已保存到 $savePath', isSuccess: true);
      }
    } catch (error) {
      if (mounted) {
        showTopToast(context, '保存附件失败: $error', isSuccess: false);
      }
    }
  }

  Future<void> _retryMessage(ChatMessageRecord message) async {
    try {
      final result = await _manager.resendMessage(message);
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        _buildSendResultMessage(
          result,
          successLabel: '已重新发送',
          partialLabel: '已重新发送，但仍有部分未送达',
          failureLabel: '重发失败',
        ),
        isSuccess: !result.isFailure,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '重发失败: $error', isSuccess: false);
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _formatDuration(int? durationMs) {
    final value = durationMs ?? 0;
    final totalSeconds = (value / 1000).round();
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _buildSendResultMessage(
    ChatSendResult result, {
    required String successLabel,
    required String partialLabel,
    required String failureLabel,
  }) {
    if (result.isSuccess) {
      return successLabel;
    }
    if (result.hadNoRecipients) {
      return '$failureLabel：当前没有在线接收方';
    }
    if (result.isPartialSuccess) {
      return '$partialLabel（成功 ${result.deliveredRecipients}/${result.attemptedRecipients}）';
    }
    return '$failureLabel（成功 ${result.deliveredRecipients}/${result.attemptedRecipients}）';
  }
}

class _SubmitChatComposerIntent extends Intent {
  const _SubmitChatComposerIntent();
}

class _SubmitChatComposerAction extends Action<_SubmitChatComposerIntent> {
  _SubmitChatComposerAction({
    required this.shouldHandle,
    required this.onSubmit,
  });

  final bool Function() shouldHandle;
  final VoidCallback onSubmit;

  @override
  bool isEnabled(_SubmitChatComposerIntent intent) {
    return shouldHandle();
  }

  @override
  bool consumesKey(_SubmitChatComposerIntent intent) {
    return shouldHandle();
  }

  @override
  Object? invoke(_SubmitChatComposerIntent intent) {
    onSubmit();
    return null;
  }
}

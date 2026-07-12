import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/toast_utils.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  String? _playingAttachmentId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _manager.selectTab(
          _tabController.index == 0 ? ChatMainTab.hall : ChatMainTab.direct,
        );
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
    final targetTabIndex = _manager.selectedTab == ChatMainTab.hall ? 0 : 1;
    if (_tabController.index != targetTabIndex) {
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
                  padding: EdgeInsets.all(context.spacingLarge),
                  child: _buildHeader(context, isDark),
                ),
                Container(
                  margin:
                      EdgeInsets.symmetric(horizontal: context.spacingLarge),
                  child: TabBar(
                    controller: _tabController,
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
                Expanded(
                  child: _manager.loading && _manager.halls.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildHallTab(context, isDark),
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

  Widget _buildHeader(BuildContext context, bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    return Row(
      children: [
        Container(
          width: context.iconXLarge,
          height: context.iconXLarge,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryColor, primaryColor.withValues(alpha: 0.75)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(context.cardRadius),
          ),
          child: Icon(
            Icons.forum,
            color: Colors.white,
            size: context.iconLarge,
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
      ],
    );
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
    final layoutIsWide = MediaQuery.of(context).size.width >= 1080;
    final startupIssue = _manager.chatStartupIssue;

    if (layoutIsWide) {
      return Column(
        children: [
          if (startupIssue != null)
            _buildStartupIssueBanner(context, isDark, startupIssue),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: context.w(280),
                  child: _buildHallUsersPanel(context, isDark, selectedHallId),
                ),
                Expanded(
                  child: _buildHallContent(
                    context,
                    isDark,
                    selectedHallId,
                    selectedConversation,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (startupIssue != null)
          _buildStartupIssueBanner(context, isDark, startupIssue),
        SizedBox(
          height: context.w(220),
          child: _buildHallUsersPanel(context, isDark, selectedHallId),
        ),
        Expanded(
          child: _buildHallContent(
            context,
            isDark,
            selectedHallId,
            selectedConversation,
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
    String selectedHallId,
    ChatConversation? selectedConversation,
  ) {
    return Column(
      children: [
        _buildHallCardStrip(context, isDark, selectedHallId),
        _buildRoomStrip(
          context,
          isDark,
          selectedHallId,
          selectedConversation,
        ),
        Expanded(
          child: _buildConversationPanel(
            context,
            isDark,
            selectedConversation,
            emptyTitle: '请选择大厅或房间',
            emptyMessage: '点击一个公共大厅卡片，或创建/加入一个自定义聊天室开始聊天。',
          ),
        ),
      ],
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
          Row(
            children: [
              Text(
                '自定义聊天室',
                style: TextStyle(
                  fontSize: context.fontMedium,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showCreateRoomDialog(selectedHallId),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('创建聊天室'),
              ),
            ],
          ),
          SizedBox(height: context.spacingSmall),
          if (rooms.isEmpty)
            Text(
              '当前大厅还没有自定义聊天室，创建一个后其他在线用户就能自由加入。',
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            )
          else
            Wrap(
              spacing: context.spacingSmall,
              runSpacing: context.spacingSmall,
              children: rooms.map((room) {
                final isSelected = selectedConversation?.id == room.roomId;
                return ActionChip(
                  backgroundColor: isSelected
                      ? Theme.of(context).primaryColor.withValues(alpha: 0.14)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.02)),
                  side: BorderSide(
                    color: room.isActive
                        ? Theme.of(context).primaryColor.withValues(alpha: 0.25)
                        : Colors.grey.withValues(alpha: 0.20),
                  ),
                  avatar: Icon(
                    room.isActive ? Icons.meeting_room : Icons.history,
                    size: context.iconSmall,
                    color: room.isActive
                        ? Theme.of(context).primaryColor
                        : Colors.grey,
                  ),
                  label: Text(
                    room.locallyJoined
                        ? '${room.roomName} (已加入)'
                        : room.roomName,
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  onPressed: () async {
                    if (!room.locallyJoined) {
                      await _manager.joinRoom(room);
                      if (!mounted) {
                        return;
                      }
                      showTopToast(
                        this.context,
                        '已加入 ${room.roomName}',
                        isSuccess: true,
                      );
                    } else {
                      await _manager.openConversation(room.roomId);
                    }
                  },
                );
              }).toList(growable: false),
            ),
        ],
      ),
    );
  }

  Widget _buildDirectTab(BuildContext context, bool isDark) {
    final conversations = _manager.directConversations;
    final selectedConversation =
        _manager.selectedConversation?.type == ChatConversationType.direct
            ? _manager.selectedConversation
            : null;
    final isWide = MediaQuery.of(context).size.width >= 980;

    if (conversations.isEmpty) {
      return _buildEmptyState(
        context,
        isDark,
        title: '还没有私聊会话',
        message: '去大厅左侧点一个在线用户，或者右键在线用户发起私聊。',
        icon: Icons.mark_chat_unread_outlined,
      );
    }

    final listPanel =
        _buildDirectConversationList(context, isDark, conversations);
    final chatPanel = _buildConversationPanel(
      context,
      isDark,
      selectedConversation,
      emptyTitle: '请选择一个私聊会话',
      emptyMessage: '左侧会显示最近的私聊会话，点击后即可继续聊天。',
    );

    if (isWide) {
      return Row(
        children: [
          SizedBox(width: context.w(320), child: listPanel),
          Expanded(child: chatPanel),
        ],
      );
    }

    return Column(
      children: [
        SizedBox(height: context.w(280), child: listPanel),
        Expanded(child: chatPanel),
      ],
    );
  }

  Widget _buildDirectConversationList(
    BuildContext context,
    bool isDark,
    List<ChatConversation> conversations,
  ) {
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
          return InkWell(
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
                        borderRadius:
                            BorderRadius.circular(context.radius(999)),
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
                ],
              ),
            ),
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

    return Container(
      margin: EdgeInsets.fromLTRB(
        context.spacingSmall,
        context.spacingLarge,
        context.spacingLarge,
        context.spacingLarge,
      ),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(context.cardPadding),
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
      onSecondaryTapDown: (details) => unawaited(
        _showMessageMenu(context, details.globalPosition, message),
      ),
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
        style: TextStyle(
          fontSize: context.fontBody,
          color: textColor,
        ),
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
                  decoration: const InputDecoration(
                    hintText: '输入消息后按发送',
                  ),
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
      message: '聊天室当前支持 Windows 和 macOS 桌面端。',
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
    _tabController.index = 1;
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
        PopupMenuItem<String>(
          value: 'direct',
          child: Text('发起私聊'),
        ),
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

  Future<void> _showCreateRoomDialog(String hallId) async {
    final controller = TextEditingController();
    try {
      final roomName = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('创建自定义聊天室'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '聊天室名称',
                hintText: '例如 运维讨论组',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text),
                child: const Text('创建'),
              ),
            ],
          );
        },
      );
      if (roomName == null || roomName.trim().isEmpty) {
        return;
      }
      await _manager.createRoom(hallId, roomName);
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
      final filePath = Platform.isMacOS
          ? (await file_selector.openFile(confirmButtonText: '选择'))?.path
          : (await FilePicker.platform.pickFiles(
              allowMultiple: false,
              withData: false,
            ))
              ?.files
              .single
              .path;
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
          await Share.shareXFiles(
            [XFile(filePath, name: attachment.fileName)],
            text: attachment.fileName,
          );
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

      final savePath = Platform.isMacOS
          ? (await file_selector.getSaveLocation(
              suggestedName: attachment.fileName,
              confirmButtonText: '保存',
            ))
              ?.path
          : await FilePicker.platform.saveFile(
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

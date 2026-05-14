import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_view.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

/// 房间页面 - 只保留聊天域，包含聊天室与私信两个标签。
class RoomPage extends StatefulWidget {
  final NetworkConfig? selectedConfig;
  final VoidCallback? onDisconnect;

  const RoomPage({
    super.key,
    this.selectedConfig,
    this.onDisconnect,
  });

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    unawaited(chatManager.init());
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWideScreen = MediaQuery.of(context).size.width > 600;
    final isAndroid = Platform.isAndroid;
    final hasConnection = vntManager.size() > 0;
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor:
          isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(
                isWideScreen ? context.spacingXLarge : context.spacingMedium,
              ),
              child: _buildHeader(isDark, hasConnection),
            ),
            if (hasConnection)
              Container(
                margin: EdgeInsets.symmetric(
                  horizontal: isWideScreen
                      ? context.spacingXLarge
                      : context.spacingMedium,
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: UnderlineTabIndicator(
                    borderSide: BorderSide(
                      color: primaryColor,
                      width: context.w(3),
                    ),
                    insets: EdgeInsets.symmetric(
                      horizontal: isWideScreen
                          ? context.spacing(40)
                          : context.spacingLarge,
                    ),
                  ),
                  labelColor: primaryColor,
                  unselectedLabelColor: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                  dividerColor: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.05),
                  labelStyle: TextStyle(
                    fontSize: context.buttonFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: TextStyle(
                    fontSize: context.buttonFontSize,
                    fontWeight: FontWeight.w500,
                  ),
                  tabs: [
                    Tab(text: isAndroid ? '大厅' : '聊天室'),
                    const Tab(text: '私信'),
                  ],
                ),
              ),
            Expanded(
              child: hasConnection
                  ? TabBarView(
                      controller: _tabController,
                      children: [
                        ChatRoomView(
                          section: ChatRoomSection.lobby,
                          layoutMode: isAndroid
                              ? ChatRoomLayoutMode.androidLobby
                              : ChatRoomLayoutMode.standard,
                        ),
                        isAndroid
                            ? _buildAndroidDirectPeerList(isDark)
                            : const ChatRoomView(
                                section: ChatRoomSection.directMessages,
                              ),
                      ],
                    )
                  : _buildNotConnectedView(isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, bool hasConnection) {
    final primaryColor = Theme.of(context).primaryColor;
    return Row(
      children: [
        Container(
          width: context.iconXLarge,
          height: context.iconXLarge,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryColor, primaryColor.withValues(alpha: 0.7)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(context.cardRadius),
          ),
          child: Icon(
            Icons.forum_outlined,
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
                '房间',
                style: TextStyle(
                  fontSize: context.fontXLarge,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              SizedBox(height: context.spacingXXSmall),
              Text(
                hasConnection
                    ? (Platform.isAndroid
                        ? '大厅与私信已启用'
                        : '大厅聊天室与私信会话已启用')
                    : '请先连接一个组网配置后再进入聊天',
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
      ],
    );
  }

  Widget _buildNotConnectedView(bool isDark) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.darkCardBackground
              : AppTheme.lightCardBackground,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '当前未连接组网',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              '连接成功后即可进入大厅、发起私信与远程协助。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidDirectPeerList(bool isDark) {
    return AnimatedBuilder(
      animation: chatManager,
      builder: (context, _) {
        final peers = chatManager.onlinePeers;
        if (peers.isEmpty) {
          return Center(
            child: _buildEmptyHintCard(
              isDark,
              '暂无在线用户',
              '等待其他设备加入当前组网后，即可点击发起私聊。',
              Icons.people_outline,
            ),
          );
        }
        return ListView.separated(
          padding: EdgeInsets.all(context.spacingMedium),
          itemCount: peers.length,
          separatorBuilder: (_, __) => SizedBox(height: context.spacingSmall),
          itemBuilder: (context, index) {
            final peer = peers[index];
            final friendStatus = chatManager.friendStatusOf(peer.peerId);
            final subtitle =
                '${peer.virtualIp}${chatManager.hasMultipleNetworks ? ' · ${peer.networkKey}' : ''}${friendStatus == ChatFriendStatus.friend ? ' · 好友' : ''}';
            return Material(
              color: isDark
                  ? AppTheme.darkCardBackground
                  : AppTheme.lightCardBackground,
              borderRadius: BorderRadius.circular(context.cardRadius),
              child: InkWell(
                borderRadius: BorderRadius.circular(context.cardRadius),
                onTap: () => _openAndroidDirectConversation(peer),
                child: Padding(
                  padding: EdgeInsets.all(context.spacingMedium),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: context.iconMedium * 0.65,
                        backgroundColor:
                            Theme.of(context).colorScheme.primary.withValues(
                                  alpha: 0.12,
                                ),
                        child: Icon(
                          Icons.person_outline,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      SizedBox(width: context.spacingMedium),
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
                              subtitle,
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
                      Icon(
                        Icons.chevron_right,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openAndroidDirectConversation(ChatPeer peer) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _AndroidDirectConversationPage(peer: peer),
      ),
    );
  }

  Widget _buildEmptyHintCard(
    bool isDark,
    String title,
    String subtitle,
    IconData icon,
  ) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.darkCardBackground
            : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AndroidDirectConversationPage extends StatelessWidget {
  const _AndroidDirectConversationPage({
    required this.peer,
  });

  final ChatPeer peer;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      appBar: AppBar(
        title: Text(peer.displayName),
      ),
      body: ChatRoomView(
        section: ChatRoomSection.directMessages,
        layoutMode: ChatRoomLayoutMode.androidDirectDetail,
        initialDirectPeer: peer,
      ),
    );
  }
}

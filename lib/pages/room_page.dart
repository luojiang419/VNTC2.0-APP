import 'package:flutter/material.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_view.dart';
import 'package:vnt_app/chat/room_lobby_view.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

/// 房间页面 - 包含大厅、聊天室与私信三个标签。
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
    _tabController = TabController(length: 3, vsync: this);
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
    final scopedNetworkKey = widget.selectedConfig?.itemKey.trim();
    final hasScopedNetwork =
        scopedNetworkKey != null && scopedNetworkKey.isNotEmpty;
    final hasConnection = hasScopedNetwork
        ? vntManager.hasConnectionItem(scopedNetworkKey)
        : vntManager.size() > 0;
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
                  tabs: const [
                    Tab(text: '大厅'),
                    Tab(text: '聊天室'),
                    Tab(text: '私信'),
                  ],
                ),
              ),
            Expanded(
              child: hasConnection
                  ? TabBarView(
                      controller: _tabController,
                      children: [
                        RoomLobbyView(
                          scopedNetworkKey: scopedNetworkKey,
                          onOpenChannelConversation: _openChannelConversation,
                          onOpenDirectPeer: _openDirectPeer,
                        ),
                        ChatRoomView(
                          section: ChatRoomSection.channels,
                          scopedNetworkKey: scopedNetworkKey,
                        ),
                        ChatRoomView(
                          section: ChatRoomSection.directMessages,
                          scopedNetworkKey: scopedNetworkKey,
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
                    ? '可在大厅管理房间，在聊天室交流，在私信中一对一沟通'
                    : '请先连接一个组网配置后再进入大厅、聊天室或私信',
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
              '连接成功后即可进入大厅管理房间、在聊天室交流并发起私信。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openChannelConversation(String conversationId) async {
    _tabController.animateTo(1);
    await chatManager.selectConversation(conversationId);
  }

  Future<void> _openDirectPeer(ChatPeer peer) async {
    _tabController.animateTo(2);
    await chatManager.openDirectConversation(peer);
  }
}

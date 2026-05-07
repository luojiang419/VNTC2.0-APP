import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_manager.dart';
import 'chat_models.dart';
import 'chat_peer_labels.dart';
import 'chat_repository.dart';

enum ChatRoomSection { channels, directMessages }

class ChatRoomView extends StatefulWidget {
  const ChatRoomView({
    super.key,
    required this.section,
    this.scopedNetworkKey,
  });

  final ChatRoomSection section;
  final String? scopedNetworkKey;

  @override
  State<ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<ChatRoomView> {
  final TextEditingController _textController = TextEditingController();
  int _lastStatusVersion = -1;

  String? get _scopedNetworkKey {
    final value = widget.scopedNetworkKey?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  List<ChatConversationSummary> get _lobbyConversations =>
      chatManager.lobbyConversationsForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  List<ChatConversationSummary> get _roomConversations =>
      chatManager.roomConversationsForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  List<ChatConversationSummary> get _directConversations =>
      chatManager.directConversationsForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  List<ChatConversationSummary> get _channelConversations =>
      chatManager.channelConversationsForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  List<ChatChannel> get _scopedChannels =>
      chatManager.channelsForScope(scopedNetworkKey: _scopedNetworkKey);

  List<ChatPeer> get _onlinePeers => chatManager.onlinePeersForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  List<String> get _connectedNetworkKeys =>
      chatManager.connectedNetworkKeysForScope(
        scopedNetworkKey: _scopedNetworkKey,
      );

  bool get _hasMultipleNetworks => chatManager.hasMultipleNetworksInScope(
      scopedNetworkKey: _scopedNetworkKey);

  @override
  void initState() {
    super.initState();
    unawaited(chatManager.init());
    if (widget.section == ChatRoomSection.channels) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          chatManager.openPreferredChannelConversation(
            scopedNetworkKey: _scopedNetworkKey,
          ),
        );
      });
    }
  }

  @override
  void didUpdateWidget(covariant ChatRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section ||
        oldWidget.scopedNetworkKey != widget.scopedNetworkKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.section != ChatRoomSection.channels) {
          return;
        }
        unawaited(
          chatManager.openPreferredChannelConversation(
            scopedNetworkKey: _scopedNetworkKey,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: chatManager,
      builder: (context, _) {
        _showStatusSnackBarIfNeeded(context);
        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 980;
            final leftPane = _buildSidebar(context, widget.section);
            final showConversationOnlyOnNarrow =
                _shouldShowConversationOnlyOnNarrow();
            final rightPane = _buildConversationPane(
              context,
              onShowSidebar: !isWide && showConversationOnlyOnNarrow
                  ? () => _showSidebarSheet(context)
                  : null,
            );
            if (isWide) {
              return Row(
                children: [
                  SizedBox(width: 320, child: leftPane),
                  const VerticalDivider(width: 1),
                  Expanded(child: rightPane),
                ],
              );
            }
            if (showConversationOnlyOnNarrow) {
              return rightPane;
            }
            return leftPane;
          },
        );
      },
    );
  }

  void _showStatusSnackBarIfNeeded(BuildContext context) {
    final message = chatManager.statusMessage;
    if (message == null ||
        message.isEmpty ||
        chatManager.statusVersion == _lastStatusVersion) {
      return;
    }
    _lastStatusVersion = chatManager.statusVersion;
    if (!chatManager.consumeStatusVersion(chatManager.statusVersion) ||
        !chatManager.shouldShowStatusSnackBar(message)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final value = _textController.value;
    final isComposing = value.composing.isValid && !value.composing.isCollapsed;
    if (isComposing) {
      return KeyEventResult.ignored;
    }
    unawaited(_sendText());
    return KeyEventResult.handled;
  }

  Widget _buildSidebar(
    BuildContext context,
    ChatRoomSection section, {
    VoidCallback? onEntryActivated,
  }) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildDebugToolsCard(context),
          const SizedBox(height: 12),
          if (section == ChatRoomSection.channels) ...[
            _buildSectionCard(
              context: context,
              title: '默认大厅',
              count: _lobbyConversations.length,
              child: _buildLobbyConversationList(
                onEntryActivated: onEntryActivated,
              ),
            ),
            const SizedBox(height: 12),
            _buildSectionCard(
              context: context,
              title: '房间',
              count: _roomConversations.length,
              child: _buildRoomConversationList(
                onEntryActivated: onEntryActivated,
              ),
            ),
          ] else ...[
            _buildSectionCard(
              context: context,
              title: '私信会话',
              count: _directConversations.length,
              child: _buildConversationList(
                _directConversations,
                emptyTitle: '还没有私信会话',
                emptySubtitle: '从在线成员发起私聊后会出现在这里',
                onEntryActivated: onEntryActivated,
              ),
            ),
            const SizedBox(height: 12),
            _buildSectionCard(
              context: context,
              title: '在线成员',
              count: _onlinePeers.length,
              child: _buildOnlinePeerList(
                onEntryActivated: onEntryActivated,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDebugToolsCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '联调工具',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '网络 ${_connectedNetworkKeys.length} 个 · 在线设备 ${_onlinePeers.length} 个',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => chatManager.debugRefreshNow(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新发现'),
                ),
                OutlinedButton.icon(
                  onPressed: _showDiagnosticsDialog,
                  icon: const Icon(Icons.medical_information_outlined),
                  label: const Text('查看诊断'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _confirmClearChatData,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('清空聊天数据'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required BuildContext context,
    required String title,
    required int count,
    required Widget child,
    Widget? trailing,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList(
    List<ChatConversationSummary> conversations, {
    required String emptyTitle,
    required String emptySubtitle,
    VoidCallback? onEntryActivated,
  }) {
    if (conversations.isEmpty) {
      return _buildEmptyHint(emptyTitle, emptySubtitle);
    }
    return Column(
      children: conversations.map((conversation) {
        final selected =
            chatManager.selectedConversationId == conversation.conversationId;
        final title = conversation.title.isEmpty ? '未命名会话' : conversation.title;
        return _buildSelectableTile(
          selected: selected,
          onTap: () {
            onEntryActivated?.call();
            chatManager.selectConversation(conversation.conversationId);
          },
          title: title,
          subtitle: conversation.lastPreview.isEmpty
              ? '暂无消息'
              : conversation.lastPreview,
          trailing: conversation.unreadCount > 0
              ? _buildUnreadBadge(conversation.unreadCount)
              : null,
        );
      }).toList(),
    );
  }

  Widget _buildLobbyConversationList({VoidCallback? onEntryActivated}) {
    if (_lobbyConversations.isEmpty) {
      return _buildEmptyHint('默认大厅尚未就绪', '连接组网后会自动创建默认大厅');
    }
    return Column(
      children: _lobbyConversations.map((conversation) {
        final selected =
            chatManager.selectedConversationId == conversation.conversationId;
        final subtitle = _hasMultipleNetworks
            ? '${conversation.networkKey} · 默认公共大厅'
            : '默认公共大厅';
        return _buildSelectableTile(
          selected: selected,
          onTap: () {
            onEntryActivated?.call();
            chatManager.selectConversation(conversation.conversationId);
          },
          title: conversation.title,
          subtitle: subtitle,
          trailing: conversation.unreadCount > 0
              ? _buildUnreadBadge(conversation.unreadCount)
              : null,
        );
      }).toList(),
    );
  }

  Widget _buildRoomConversationList({VoidCallback? onEntryActivated}) {
    if (_roomConversations.isEmpty) {
      return _buildEmptyHint('还没有房间会话', '请先从大厅创建房间或加入房间');
    }
    return Column(
      children: _roomConversations.map((conversation) {
        final selected =
            chatManager.selectedConversationId == conversation.conversationId;
        final channel = conversation.channelId == null
            ? null
            : _scopedChannels
                .where((item) => item.channelId == conversation.channelId)
                .cast<ChatChannel?>()
                .firstOrNull;
        final roomTypeLabel = channel?.isPrivate == true ? '私密房间' : '公开房间';
        final subtitle = _hasMultipleNetworks
            ? '${conversation.networkKey} · $roomTypeLabel'
            : roomTypeLabel;
        return _buildSelectableTile(
          selected: selected,
          onTap: () {
            onEntryActivated?.call();
            chatManager.selectConversation(conversation.conversationId);
          },
          title: conversation.title,
          subtitle: subtitle,
          trailing: conversation.unreadCount > 0
              ? _buildUnreadBadge(conversation.unreadCount)
              : null,
        );
      }).toList(),
    );
  }

  Widget _buildChannelList() {
    if (_scopedChannels.isEmpty) {
      return _buildEmptyHint('还没有频道', '点击右上角创建公开频道或私密频道');
    }
    return Column(
      children: _scopedChannels.map((channel) {
        final conversationId = ChatIds.channelConversationId(
          channel.networkKey,
          channel.channelId,
        );
        final selected = chatManager.selectedConversationId == conversationId;
        final isOwner = chatManager.isChannelOwner(channel);
        return _buildSelectableTile(
          selected: selected,
          onTap: () => chatManager.selectConversation(conversationId),
          title: channel.name,
          subtitle: channel.isPrivate
              ? (channel.joined ? '私密频道 · 已加入' : '私密频道 · 待加入')
              : (channel.joined ? '公开频道 · 已加入' : '公开频道'),
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'join') {
                chatManager.joinChannel(channel);
              } else if (value == 'leave') {
                chatManager.leaveChannel(channel);
              } else if (value == 'voice') {
                chatManager.joinChannelVoice(channel);
              } else if (value == 'rename') {
                _showRenameChannelDialog(channel);
              } else if (value == 'members') {
                _showManageMembersDialog(channel);
              } else if (value == 'invite') {
                _showInviteMembersDialog(channel);
              } else if (value == 'archive') {
                chatManager.archiveChannel(channel);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: channel.joined ? 'leave' : 'join',
                child: Text(channel.joined ? '退出频道' : '加入频道'),
              ),
              PopupMenuItem(
                value: 'voice',
                enabled: chatManager.isChatAudioSupported,
                child: Text(
                  chatManager.isChatAudioSupported ? '进入语音' : '进入语音（当前平台不支持）',
                ),
              ),
              if (isOwner)
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('频道改名'),
                ),
              if (isOwner)
                const PopupMenuItem(
                  value: 'members',
                  child: Text('管理成员'),
                ),
              if (isOwner)
                const PopupMenuItem(
                  value: 'invite',
                  child: Text('邀请成员'),
                ),
              if (isOwner)
                const PopupMenuItem(
                  value: 'archive',
                  child: Text('归档频道'),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFriendList() {
    if (chatManager.friendPeers.isEmpty) {
      return _buildEmptyHint('还没有好友', '可以先从在线设备发起好友申请');
    }
    return Column(
      children: chatManager.friendPeers.map((peer) {
        final status = chatManager.friendStatusOf(peer.peerId);
        final subtitle = switch (status) {
          ChatFriendStatus.pending => '等待处理',
          ChatFriendStatus.friend => peer.isOnline ? '在线' : '离线',
          ChatFriendStatus.blocked => '已拉黑',
          ChatFriendStatus.stranger => '陌生人',
        };
        return _buildSelectableTile(
          selected: false,
          onTap: status == ChatFriendStatus.blocked
              ? () => _showRemarkDialog(peer)
              : () => chatManager.openDirectConversation(peer),
          title: peer.displayName,
          subtitle:
              '${peer.virtualIp}${_hasMultipleNetworks ? ' · ${peer.networkKey}' : ''} · $subtitle',
          trailing: status == ChatFriendStatus.pending
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: () => chatManager.acceptFriend(peer.peerId),
                      tooltip: '通过',
                      icon: const Icon(Icons.check_circle_outline),
                    ),
                    IconButton(
                      onPressed: () => chatManager.rejectFriend(peer.peerId),
                      tooltip: '拒绝',
                      icon: const Icon(Icons.cancel_outlined),
                    ),
                  ],
                )
              : PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'chat') {
                      chatManager.openDirectConversation(peer);
                    } else if (value == 'remark') {
                      _showRemarkDialog(peer);
                    } else if (value == 'remove') {
                      chatManager.removeFriend(peer.peerId);
                    } else if (value == 'block') {
                      chatManager.blockPeer(peer.peerId);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'chat', child: Text('发起私聊')),
                    PopupMenuItem(value: 'remark', child: Text('设置备注')),
                    PopupMenuItem(value: 'remove', child: Text('删除好友')),
                    PopupMenuItem(value: 'block', child: Text('拉黑')),
                  ],
                ),
        );
      }).toList(),
    );
  }

  Widget _buildOnlinePeerList({VoidCallback? onEntryActivated}) {
    if (_onlinePeers.isEmpty) {
      return _buildEmptyHint('暂无在线设备', '等待其他设备加入当前组网');
    }
    return Column(
      children: _onlinePeers.map((peer) {
        final friendStatus = chatManager.friendStatusOf(peer.peerId);
        return _buildSelectableTile(
          selected: false,
          onTap: () {
            onEntryActivated?.call();
            chatManager.openDirectConversation(peer);
          },
          onSecondaryTapDown: (details) =>
              _showPeerContextMenu(peer, details.globalPosition),
          title: chatPeerPrimaryName(peer),
          subtitle: buildOnlinePeerSubtitle(
            peer,
            hasMultipleNetworks: _hasMultipleNetworks,
            friendStatus: friendStatus,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => chatManager.openDirectConversation(peer),
                tooltip: '私聊',
                icon: const Icon(Icons.chat_bubble_outline),
              ),
              IconButton(
                onPressed: friendStatus != ChatFriendStatus.stranger
                    ? null
                    : () => chatManager.requestFriend(peer),
                tooltip: '加好友',
                icon: const Icon(Icons.person_add_alt_1_outlined),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<void> _showPeerContextMenu(
    ChatPeer peer,
    Offset globalPosition,
  ) async {
    final friendStatus = chatManager.friendStatusOf(peer.peerId);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'chat', child: Text('发起私信')),
        const PopupMenuItem(value: 'request_control', child: Text('请求控制')),
        const PopupMenuItem(value: 'invite_control', child: Text('邀请控制')),
        if (friendStatus == ChatFriendStatus.stranger)
          const PopupMenuItem(value: 'friend', child: Text('加好友')),
        const PopupMenuItem(value: 'remark', child: Text('设置备注')),
        const PopupMenuItem(value: 'block', child: Text('拉黑')),
      ],
    );
    if (selected == null) {
      return;
    }
    if (selected == 'chat') {
      await chatManager.openDirectConversation(peer);
      return;
    }
    if (selected == 'request_control') {
      await chatManager.requestRemoteControl(peer);
      return;
    }
    if (selected == 'invite_control') {
      await chatManager.inviteRemoteControl(peer);
      return;
    }
    if (selected == 'friend') {
      await chatManager.requestFriend(peer);
      return;
    }
    if (selected == 'remark') {
      await _showRemarkDialog(peer);
      return;
    }
    if (selected == 'block') {
      await chatManager.blockPeer(peer.peerId);
    }
  }

  Widget _buildSelectableTile({
    required bool selected,
    required VoidCallback onTap,
    required String title,
    required String subtitle,
    Widget? trailing,
    void Function(TapDownDetails details)? onSecondaryTapDown,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: onSecondaryTapDown,
        child: ListTile(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onTap: onTap,
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing,
        ),
      ),
    );
  }

  Widget _buildUnreadBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  bool _conversationMatchesCurrentSection(
      ChatConversationSummary? conversation) {
    if (conversation == null ||
        !chatMatchesNetworkScope(conversation.networkKey, _scopedNetworkKey)) {
      return false;
    }
    return switch (widget.section) {
      ChatRoomSection.channels =>
        conversation.type == ChatConversationType.channel,
      ChatRoomSection.directMessages =>
        conversation.type == ChatConversationType.direct,
    };
  }

  bool _shouldShowConversationOnlyOnNarrow() {
    return _conversationMatchesCurrentSection(chatManager.selectedConversation);
  }

  void _showSidebarSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final height = MediaQuery.of(sheetContext).size.height * 0.82;
        return SafeArea(
          child: SizedBox(
            height: height,
            child: _buildSidebar(
              sheetContext,
              widget.section,
              onEntryActivated: () => Navigator.of(sheetContext).pop(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildConversationPane(
    BuildContext context, {
    VoidCallback? onShowSidebar,
  }) {
    final conversation = chatManager.selectedConversation;
    final section = widget.section;
    if (section == ChatRoomSection.channels &&
        _channelConversations.isNotEmpty &&
        !_conversationMatchesCurrentSection(conversation)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          chatManager.openPreferredChannelConversation(
            scopedNetworkKey: _scopedNetworkKey,
          ),
        );
      });
    }
    if (!_conversationMatchesCurrentSection(conversation)) {
      return Center(
        child: _buildEmptyHint(
          section == ChatRoomSection.channels ? '聊天室已启用' : '私信已启用',
          section == ChatRoomSection.channels
              ? '从大厅选择默认大厅或房间后开始交流'
              : '从左侧私信会话或在线成员开始一对一聊天',
        ),
      );
    }
    final activeConversation = conversation!;
    final peer = chatManager.findPeer(activeConversation.peerId);
    final channel = activeConversation.channelId == null
        ? null
        : _scopedChannels
            .where((item) => item.channelId == activeConversation.channelId)
            .cast<ChatChannel?>()
            .firstOrNull;
    return Column(
      children: [
        _buildConversationHeader(
          activeConversation,
          peer,
          channel,
          onShowSidebar: onShowSidebar,
        ),
        if (chatManager.callSession?.isIncoming == true &&
            chatManager.callSession?.state == ChatCallState.ringing)
          _buildIncomingCallBanner(),
        if (chatManager.remoteAssistSession?.peerId ==
            activeConversation.peerId)
          _buildRemoteAssistBanner(peer),
        Expanded(
          child: chatManager.activeMessages.isEmpty
              ? Center(
                  child: _buildEmptyHint('暂无消息', '现在可以发送文字、图片、文件和语音'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: chatManager.activeMessages.length,
                  itemBuilder: (context, index) {
                    final message = chatManager.activeMessages[index];
                    return _buildMessageBubble(message);
                  },
                ),
        ),
        _buildInputBar(activeConversation, channel),
      ],
    );
  }

  Widget _buildConversationHeader(ChatConversationSummary conversation,
      ChatPeer? peer, ChatChannel? channel,
      {VoidCallback? onShowSidebar}) {
    final session = chatManager.callSession;
    final isDirectCall = session?.type == ChatCallType.direct &&
        session?.peerId == conversation.peerId &&
        session?.state != ChatCallState.ended;
    final isChannelVoice = session?.type == ChatCallType.channel &&
        session?.channelId == conversation.channelId &&
        session?.joinedVoice == true;
    final audioSupported = chatManager.isChatAudioSupported;
    final remoteAssistReason = peer == null
        ? '当前会话不支持远程协助'
        : chatManager.remoteAssistUnavailableMessageForPeer(peer);
    final subtitle = conversation.type == ChatConversationType.direct
        ? '${peer?.virtualIp ?? ''} · ${peer?.isOnline == true ? '在线' : '离线'}'
        : '${conversation.networkKey} · ${channel?.isPrivate == true ? '私密房间' : '公开房间'}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          if (onShowSidebar != null)
            IconButton(
              onPressed: onShowSidebar,
              tooltip: widget.section == ChatRoomSection.channels
                  ? '切换大厅和房间'
                  : '切换私信会话',
              icon: const Icon(Icons.view_list_rounded),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (audioSupported && chatManager.chatAudioHeadsetRecommended)
                  Text(
                    '语音建议佩戴耳机或耳麦',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                  ),
              ],
            ),
          ),
          if (conversation.type == ChatConversationType.direct && peer != null)
            IconButton(
              onPressed: remoteAssistReason == null
                  ? () => chatManager.inviteRemoteControl(peer)
                  : null,
              tooltip: remoteAssistReason ?? '邀请对方控制当前设备',
              icon: const Icon(Icons.screen_share_outlined),
            ),
          if (conversation.type == ChatConversationType.direct && peer != null)
            IconButton(
              onPressed: remoteAssistReason == null
                  ? () => chatManager.requestRemoteControl(peer)
                  : null,
              tooltip: remoteAssistReason ?? '请求控制对方设备',
              icon: const Icon(Icons.control_camera_outlined),
            ),
          if (conversation.type == ChatConversationType.direct && peer != null)
            IconButton(
              onPressed: audioSupported
                  ? (isDirectCall
                      ? chatManager.hangupCall
                      : (peer.isOnline
                          ? () => chatManager.startPrivateCall(peer)
                          : null))
                  : null,
              tooltip: audioSupported
                  ? (isDirectCall ? '挂断语音' : '发起语音')
                  : chatManager.chatAudioUnsupportedReason,
              icon: Icon(isDirectCall ? Icons.call_end : Icons.call),
            ),
          if (conversation.type == ChatConversationType.channel &&
              channel != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  audioSupported
                      ? (isChannelVoice
                          ? '语音中 ${session?.participants.length ?? 1} 人'
                          : '未加入语音')
                      : '当前平台不支持语音',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                IconButton(
                  onPressed: audioSupported
                      ? (isChannelVoice
                          ? chatManager.leaveChannelVoice
                          : () => chatManager.joinChannelVoice(channel))
                      : null,
                  tooltip: audioSupported
                      ? (isChannelVoice ? '离开语音' : '加入语音')
                      : chatManager.chatAudioUnsupportedReason,
                  icon: Icon(
                      isChannelVoice ? Icons.headset_off : Icons.headset_mic),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildIncomingCallBanner() {
    final session = chatManager.callSession;
    final caller = chatManager.findPeer(session?.peerId);
    final audioSupported = chatManager.isChatAudioSupported;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.ring_volume),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${caller?.displayName ?? '对方'} 正在呼叫你',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(
            onPressed: chatManager.rejectIncomingCall,
            child: const Text('拒绝'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: audioSupported ? chatManager.acceptIncomingCall : null,
            child: Text(audioSupported ? '接听' : '暂不支持'),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteAssistBanner(ChatPeer? peer) {
    final session = chatManager.remoteAssistSession;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final title = session.mode == RemoteAssistMode.requestControl
        ? (session.isIncoming
            ? '${peer?.displayName ?? '对方'} 请求控制当前设备'
            : '已向对方发送控制请求')
        : (session.isIncoming
            ? '${peer?.displayName ?? '对方'} 邀请你去控制其设备'
            : '已邀请对方来控制当前设备');
    final subtitle = switch (session.state) {
      RemoteAssistState.pending => session.isIncoming ? '等待你处理' : '等待对方处理',
      RemoteAssistState.accepted => '对方已同意，准备启动远程协助',
      RemoteAssistState.ready => '远程协助准备完成',
      RemoteAssistState.active => '远程协助会话已启动',
      RemoteAssistState.rejected => '远程协助请求已被拒绝',
      RemoteAssistState.ended => '远程协助会话已结束',
      RemoteAssistState.failed => '远程协助启动失败',
    };
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.desktop_windows_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (session.isIncoming && session.state == RemoteAssistState.pending)
            TextButton(
              onPressed: chatManager.rejectRemoteAssist,
              child: const Text('拒绝'),
            ),
          if (session.isIncoming && session.state == RemoteAssistState.pending)
            const SizedBox(width: 8),
          if (session.isIncoming && session.state == RemoteAssistState.pending)
            FilledButton(
              onPressed: chatManager.acceptRemoteAssist,
              child: const Text('同意'),
            ),
          if (!session.isIncoming && session.state == RemoteAssistState.pending)
            FilledButton.tonal(
              onPressed: chatManager.cancelRemoteAssist,
              child: const Text('取消'),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isOutgoing = message.direction == ChatMessageDirection.outgoing;
    final peer = chatManager.findPeer(message.senderPeerId);
    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isOutgoing
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
              : Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isOutgoing ? '我' : (peer?.displayName ?? message.senderPeerId),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            _buildMessageContent(message),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusText(message.status, message.attachmentId != null),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Text(
                  TimeOfDay.fromDateTime(message.receivedAt).format(context),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageContent(ChatMessage message) {
    return FutureBuilder<ChatAttachment?>(
      future: message.attachmentId == null
          ? Future.value(null)
          : ChatRepository.instance.getAttachment(message.attachmentId!),
      builder: (context, snapshot) {
        final attachment = snapshot.data;
        if (message.kind == ChatMessageKind.text || attachment == null) {
          return Text(message.text);
        }
        final canAccept = message.direction == ChatMessageDirection.incoming &&
            message.status == ChatMessageStatus.awaitingAccept;
        final hasFile = attachment.localPath.isNotEmpty &&
            File(attachment.localPath).existsSync();
        final widgets = <Widget>[];
        if (message.kind == ChatMessageKind.image && hasFile) {
          widgets.add(
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(attachment.localPath),
                width: 220,
                height: 160,
                fit: BoxFit.cover,
              ),
            ),
          );
          widgets.add(const SizedBox(height: 8));
        } else {
          widgets.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  message.kind == ChatMessageKind.voiceNote
                      ? Icons.keyboard_voice_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    attachment.fileName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
          widgets.add(const SizedBox(height: 8));
        }
        widgets.add(
          Text(
            '${(attachment.size / 1024).toStringAsFixed(1)} KB',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
        if (message.kind == ChatMessageKind.voiceNote &&
            hasFile &&
            message.status == ChatMessageStatus.transferred) {
          widgets.add(const SizedBox(height: 8));
          widgets.add(
            FilledButton.tonalIcon(
              onPressed: chatManager.isChatAudioSupported
                  ? () => chatManager.playVoiceMessage(message)
                  : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放语音'),
            ),
          );
        }
        if (canAccept) {
          widgets.add(const SizedBox(height: 12));
          widgets.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      chatManager.rejectAttachment(attachment.attachmentId),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () =>
                      chatManager.acceptAttachment(attachment.attachmentId),
                  child: const Text('接收'),
                ),
              ],
            ),
          );
        }
        if (message.direction == ChatMessageDirection.outgoing &&
            message.status == ChatMessageStatus.awaitingAccept) {
          widgets.add(const SizedBox(height: 8));
          widgets.add(
            Text(
              '等待对方确认接收',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: widgets,
        );
      },
    );
  }

  String _statusText(ChatMessageStatus status, bool hasAttachment) {
    return switch (status) {
      ChatMessageStatus.pending => '发送中',
      ChatMessageStatus.sent => '已发送',
      ChatMessageStatus.delivered => '已送达',
      ChatMessageStatus.failed => '失败',
      ChatMessageStatus.awaitingAccept => hasAttachment ? '待接收' : '待处理',
      ChatMessageStatus.accepted => '已同意',
      ChatMessageStatus.rejected => '已拒绝',
      ChatMessageStatus.transferred => '已接收',
      ChatMessageStatus.expired => '已过期',
    };
  }

  Widget _buildInputBar(
    ChatConversationSummary conversation,
    ChatChannel? channel,
  ) {
    final session = chatManager.callSession;
    final isChannelVoice = session?.type == ChatCallType.channel &&
        session?.channelId == conversation.channelId &&
        session?.joinedVoice == true;
    final audioSupported = chatManager.isChatAudioSupported;
    final currentSpeaker = session?.speakerPeerId?.isNotEmpty == true
        ? chatManager.findPeer(session!.speakerPeerId)?.displayName ??
            session.speakerPeerId
        : '暂无';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Column(
        children: [
          if (!audioSupported)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${chatManager.chatAudioUnsupportedReason}，文字、图片和文件聊天不受影响',
                    ),
                  ),
                ],
              ),
            ),
          if (audioSupported && chatManager.chatAudioHeadsetRecommended)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.headphones_outlined),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Windows 语音首版建议佩戴耳机或耳麦，以获得更稳定的通话效果'),
                  ),
                ],
              ),
            ),
          if (chatManager.isVoiceRecording)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.mic, color: Colors.red),
                  SizedBox(width: 8),
                  Text('正在录制语音，松开发送，移出取消'),
                ],
              ),
            ),
          if (session?.type == ChatCallType.direct &&
              session?.state != ChatCallState.ended &&
              conversation.peerId == session?.peerId)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.call),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      session?.state == ChatCallState.active
                          ? '语音通话中'
                          : '等待对方接听...',
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: chatManager.hangupCall,
                    child: const Text('挂断'),
                  ),
                ],
              ),
            ),
          if (isChannelVoice)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.multitrack_audio),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '房间语音中 · ${session?.participants.length ?? 1} 人 · 当前发言: $currentSpeaker',
                    ),
                  ),
                  Listener(
                    onPointerDown: (_) => chatManager.requestPtt(),
                    onPointerUp: (_) => chatManager.releasePtt(),
                    onPointerCancel: (_) => chatManager.releasePtt(),
                    child: FilledButton(
                      onPressed: () {},
                      child: const Text('按住说话'),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _handleComposerKey,
                  child: TextField(
                    controller: _textController,
                    maxLength: ChatManager.textLimit,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '输入消息...',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: chatManager.isSendingAttachment
                    ? null
                    : chatManager.sendPickedImage,
                tooltip: chatManager.isSendingAttachment ? '附件发送中' : '发送图片',
                icon: const Icon(Icons.image_outlined),
              ),
              IconButton(
                onPressed: chatManager.isSendingAttachment
                    ? null
                    : chatManager.sendPickedFile,
                tooltip: chatManager.isSendingAttachment ? '附件发送中' : '发送文件',
                icon: const Icon(Icons.attach_file),
              ),
              if (audioSupported)
                Listener(
                  onPointerDown: (_) => chatManager.startVoiceNoteRecording(),
                  onPointerUp: (_) => chatManager.finishVoiceNoteRecording(),
                  onPointerCancel: (_) =>
                      chatManager.cancelVoiceNoteRecording(),
                  child: IconButton(
                    onPressed: () {},
                    tooltip: '按住录语音',
                    icon: const Icon(Icons.keyboard_voice_outlined),
                  ),
                )
              else
                IconButton(
                  onPressed: null,
                  tooltip: chatManager.chatAudioUnsupportedReason,
                  icon: const Icon(Icons.keyboard_voice_outlined),
                ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _sendText,
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _sendText() async {
    final text = _textController.text;
    _textController.clear();
    await chatManager.sendTextMessage(text);
  }

  Widget _buildEmptyHint(String title, String subtitle) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.forum_outlined,
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
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Future<void> _showCreateChannelDialog() async {
    final connectedNetworks = _connectedNetworkKeys;
    if (connectedNetworks.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有可用的已连接网络')),
      );
      return;
    }
    String? selectedNetworkKey = chatManager.preferredNetworkKey(
      scopedNetworkKey: _scopedNetworkKey,
    );
    bool isPrivate = false;
    final selectedIds = <String>{};
    final nameController = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('创建频道'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (connectedNetworks.length > 1) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedNetworkKey,
                        decoration: const InputDecoration(
                          labelText: '所属网络',
                          border: OutlineInputBorder(),
                        ),
                        items: connectedNetworks
                            .map(
                              (networkKey) => DropdownMenuItem(
                                value: networkKey,
                                child: Text(networkKey),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            selectedNetworkKey = value;
                            selectedIds.clear();
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: '频道名称',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isPrivate,
                      title: const Text('私密频道'),
                      subtitle: const Text('私密频道只邀请指定成员'),
                      onChanged: (value) => setState(() => isPrivate = value),
                    ),
                    if (isPrivate) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 220,
                        child: ListView(
                          children: chatManager
                              .onlinePeersForNetwork(selectedNetworkKey ?? '')
                              .map((peer) {
                            return CheckboxListTile(
                              value: selectedIds.contains(peer.peerId),
                              title: Text(peer.displayName),
                              subtitle: Text(peer.virtualIp),
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    selectedIds.add(peer.peerId);
                                  } else {
                                    selectedIds.remove(peer.peerId);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('创建'),
                ),
              ],
            );
          },
        );
      },
    );
    if (created != true) {
      nameController.dispose();
      return;
    }
    final trimmed = nameController.text.trim();
    nameController.dispose();
    if (trimmed.isEmpty) {
      return;
    }
    final networkKey = selectedNetworkKey;
    if (networkKey == null) {
      return;
    }
    final invited = chatManager
        .onlinePeersForNetwork(networkKey)
        .where((peer) => selectedIds.contains(peer.peerId))
        .toList();
    await chatManager.createChannel(
      networkKey: networkKey,
      name: trimmed,
      isPrivate: isPrivate,
      invitedPeers: invited,
    );
  }

  Future<void> _showDiagnosticsDialog() async {
    final report = await chatManager.buildDiagnosticsReport();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('聊天室联调诊断'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(
                report,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(this.context);
                await Clipboard.setData(ClipboardData(text: report));
                if (!mounted) {
                  return;
                }
                navigator.pop();
                messenger.showSnackBar(
                  const SnackBar(content: Text('诊断信息已复制')),
                );
              },
              child: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmClearChatData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清空聊天室本地数据'),
          content: const Text(
            '这会删除当前机器上的聊天数据库、附件缓存、房间本地状态和聊天室日志。用于双机联调前清场，是否继续？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认清空'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await chatManager.clearAllChatData();
  }

  Future<void> _showRenameChannelDialog(ChatChannel channel) async {
    final controller = TextEditingController(text: channel.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('频道改名'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '输入新的频道名称',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      await chatManager.renameChannel(channel, controller.text);
    }
    controller.dispose();
  }

  Future<void> _showInviteMembersDialog(ChatChannel channel) async {
    final allCandidates = _onlinePeers
        .where((peer) => peer.networkKey == channel.networkKey)
        .toList();
    final selectedIds = <String>{};
    final invited = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('邀请成员到 ${channel.name}'),
              content: SizedBox(
                width: 420,
                height: 300,
                child: ListView(
                  children: allCandidates.map((peer) {
                    return CheckboxListTile(
                      value: selectedIds.contains(peer.peerId),
                      title: Text(peer.displayName),
                      subtitle: Text(peer.virtualIp),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            selectedIds.add(peer.peerId);
                          } else {
                            selectedIds.remove(peer.peerId);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('邀请'),
                ),
              ],
            );
          },
        );
      },
    );
    if (invited != true) {
      return;
    }
    final peers = allCandidates
        .where((peer) => selectedIds.contains(peer.peerId))
        .toList();
    await chatManager.inviteMembersToChannel(channel, peers);
  }

  Future<void> _showManageMembersDialog(ChatChannel channel) async {
    final peers = await chatManager.channelPeers(channel);
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('管理 ${channel.name} 成员'),
          content: SizedBox(
            width: 460,
            height: 320,
            child: peers.isEmpty
                ? const Center(child: Text('暂无成员'))
                : ListView(
                    children: peers.map((peer) {
                      final isOwner = peer.peerId == channel.ownerPeerId;
                      return ListTile(
                        title: Text(peer.displayName),
                        subtitle: Text(
                          '${peer.virtualIp}${isOwner ? ' · owner' : ''}',
                        ),
                        trailing: isOwner
                            ? const Text('Owner')
                            : TextButton(
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  await chatManager.removeMemberFromChannel(
                                    channel,
                                    peer,
                                  );
                                },
                                child: const Text('移除'),
                              ),
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showRemarkDialog(ChatPeer peer) async {
    final controller = TextEditingController(text: peer.remark);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('设置 ${peer.deviceName} 的备注'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '输入本地备注',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      await chatManager.updateRemark(peer.peerId, controller.text);
    }
    controller.dispose();
  }
}

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

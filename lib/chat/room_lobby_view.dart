import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_manager.dart';
import 'chat_models.dart';
import 'chat_peer_labels.dart';

class RoomLobbyView extends StatefulWidget {
  const RoomLobbyView({
    super.key,
    this.scopedNetworkKey,
    required this.onOpenChannelConversation,
    required this.onOpenDirectPeer,
  });

  final String? scopedNetworkKey;
  final Future<void> Function(String conversationId) onOpenChannelConversation;
  final Future<void> Function(ChatPeer peer) onOpenDirectPeer;

  @override
  State<RoomLobbyView> createState() => _RoomLobbyViewState();
}

class _RoomLobbyViewState extends State<RoomLobbyView> {
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
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: chatManager,
      builder: (context, _) {
        _showStatusSnackBarIfNeeded(context);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildDebugToolsCard(context),
            const SizedBox(height: 12),
            _buildSectionCard(
              context: context,
              title: '默认大厅',
              count: _lobbyConversations.length,
              child: _buildLobbyConversationList(),
            ),
            const SizedBox(height: 12),
            _buildSectionCard(
              context: context,
              title: '房间',
              count: _roomConversations.length,
              trailing: TextButton.icon(
                onPressed: _showCreateRoomDialog,
                icon: const Icon(Icons.add),
                label: const Text('创建房间'),
              ),
              child: _buildRoomList(),
            ),
            const SizedBox(height: 12),
            _buildSectionCard(
              context: context,
              title: '在线成员',
              count: _onlinePeers.length,
              child: _buildOnlinePeerList(),
            ),
          ],
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

  Widget _buildLobbyConversationList() {
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
          onTap: () => widget.onOpenChannelConversation(
            conversation.conversationId,
          ),
          title: conversation.title,
          subtitle: subtitle,
          trailing: conversation.unreadCount > 0
              ? _buildUnreadBadge(conversation.unreadCount)
              : null,
        );
      }).toList(),
    );
  }

  Widget _buildRoomList() {
    final rooms = _scopedChannels
        .where((channel) => !ChatManager.isLobbyChannelId(channel.channelId))
        .toList();
    if (rooms.isEmpty) {
      return _buildEmptyHint('还没有房间', '点击右上角创建公开房间或私密房间');
    }
    return Column(
      children: rooms.map((channel) {
        final conversationId = ChatIds.channelConversationId(
          channel.networkKey,
          channel.channelId,
        );
        final selected = chatManager.selectedConversationId == conversationId;
        final isOwner = chatManager.isChannelOwner(channel);
        final roomTypeLabel = channel.isPrivate
            ? (channel.joined ? '私密房间 · 已加入' : '私密房间 · 待加入')
            : (channel.joined ? '公开房间 · 已加入' : '公开房间');
        final subtitle = _hasMultipleNetworks
            ? '${channel.networkKey} · $roomTypeLabel'
            : roomTypeLabel;
        return _buildSelectableTile(
          selected: selected,
          onTap: () => widget.onOpenChannelConversation(conversationId),
          title: channel.name,
          subtitle: subtitle,
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'join') {
                unawaited(chatManager.joinChannel(channel));
              } else if (value == 'leave') {
                unawaited(chatManager.leaveChannel(channel));
              } else if (value == 'voice') {
                unawaited(chatManager.joinChannelVoice(channel));
              } else if (value == 'rename') {
                unawaited(_showRenameRoomDialog(channel));
              } else if (value == 'members') {
                unawaited(_showManageMembersDialog(channel));
              } else if (value == 'invite') {
                unawaited(_showInviteMembersDialog(channel));
              } else if (value == 'archive') {
                unawaited(chatManager.archiveChannel(channel));
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: channel.joined ? 'leave' : 'join',
                child: Text(channel.joined ? '退出房间' : '加入房间'),
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
                  child: Text('房间改名'),
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
                  child: Text('归档房间'),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildOnlinePeerList() {
    if (_onlinePeers.isEmpty) {
      return _buildEmptyHint('暂无在线设备', '等待其他设备加入当前组网');
    }
    return Column(
      children: _onlinePeers.map((peer) {
        final friendStatus = chatManager.friendStatusOf(peer.peerId);
        return _buildSelectableTile(
          selected: false,
          onTap: () => widget.onOpenDirectPeer(peer),
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
                onPressed: () => widget.onOpenDirectPeer(peer),
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
      await widget.onOpenDirectPeer(peer);
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
            maxLines: 2,
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

  Future<void> _showCreateRoomDialog() async {
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
            final currentNetworkKey = selectedNetworkKey ?? '';
            final candidates =
                chatManager.onlinePeersForNetwork(currentNetworkKey);
            return AlertDialog(
              title: const Text('创建房间'),
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
                        labelText: '房间名称',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isPrivate,
                      title: const Text('私密房间'),
                      subtitle: const Text('私密房间只邀请指定成员'),
                      onChanged: (value) => setState(() => isPrivate = value),
                    ),
                    if (isPrivate) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 220,
                        child: ListView(
                          children: candidates.map((peer) {
                            return CheckboxListTile(
                              value: selectedIds.contains(peer.peerId),
                              title: Text(chatPeerPrimaryName(peer)),
                              subtitle: Text(
                                buildMemberPeerSubtitle(
                                  peer,
                                  hasMultipleNetworks: _hasMultipleNetworks,
                                ),
                              ),
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
    final conversationId = chatManager.selectedConversationId;
    if (conversationId != null && mounted) {
      await widget.onOpenChannelConversation(conversationId);
    }
  }

  Future<void> _showRenameRoomDialog(ChatChannel channel) async {
    final controller = TextEditingController(text: channel.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('房间改名'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '输入新的房间名称',
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
                      title: Text(chatPeerPrimaryName(peer)),
                      subtitle: Text(
                        buildMemberPeerSubtitle(
                          peer,
                          hasMultipleNetworks: _hasMultipleNetworks,
                        ),
                      ),
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
                        title: Text(chatPeerPrimaryName(peer)),
                        subtitle: Text(
                          buildMemberPeerSubtitle(
                            peer,
                            hasMultipleNetworks: _hasMultipleNetworks,
                            suffix: isOwner ? '房主' : null,
                          ),
                        ),
                        trailing: isOwner
                            ? const Text('房主')
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
}

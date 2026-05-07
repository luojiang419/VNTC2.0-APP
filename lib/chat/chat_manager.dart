import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:vnt_app/remote_assist/remote_assist_service.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';
import 'package:vnt_app/windows/windows_firewall_service.dart';

import 'chat_audio_service.dart';
import 'chat_logger.dart';
import 'chat_models.dart';
import 'chat_network_service.dart';
import 'chat_repository.dart';

class ChatManager extends ChangeNotifier implements ChatNetworkDelegate {
  ChatManager._();

  static final ChatManager instance = ChatManager._();
  static const Uuid _uuid = Uuid();
  static const Duration _syncInterval = Duration(seconds: 3);
  static const Duration _attachmentExpiry = Duration(minutes: 10);
  static const int textLimit = 4000;
  static const int imageLimitBytes = 20 * 1024 * 1024;
  static const int fileLimitBytes = 200 * 1024 * 1024;

  final ChatRepository _repository = ChatRepository.instance;
  final ChatLogger _logger = ChatLogger.instance;
  final Map<String, ChatNetworkService> _services = {};
  Future<void>? _initFuture;
  Timer? _syncTimer;
  bool _initialized = false;
  DateTime? _lastRetentionAt;
  DateTime? _voiceRecordingStartedAt;
  int _mediaPlaybackPackets = 0;
  final Map<String, int> _networkStartRetryCounts = {};
  final RemoteAssistService _remoteAssist = RemoteAssistService.instance;
  final WindowsFirewallService _firewall = WindowsFirewallService.instance;
  bool _remoteAssistRuntimeReady = false;
  bool _chatFirewallChecked = false;
  WindowsFirewallEnsureResult? _lastChatFirewallResult;
  WindowsFirewallEnsureResult? _lastRemoteAssistFirewallResult;
  bool _lastRemoteAssistFirewallBlockedReady = false;
  bool? _lastRemoteAssistHostReadySucceeded;
  DateTime? _lastRemoteAssistReadySentAt;
  DateTime? _lastRemoteAssistReadyReceivedAt;

  @visibleForTesting
  Future<void> Function({int? listenPort})? debugRefreshRemoteAssistRuntime;

  @visibleForTesting
  Future<WindowsFirewallEnsureResult> Function(RemoteAssistSession session)?
      debugEnsureRemoteAssistFirewallResult;

  @visibleForTesting
  Future<void> Function(int listenPort, String sessionToken)?
      debugEnsureRemoteAssistHostReady;

  @visibleForTesting
  Future<void> Function(String virtualIp, String sessionToken)?
      debugLaunchRemoteAssistController;

  @visibleForTesting
  Future<void> Function({int? listenPort})? debugCleanupRemoteAssistRuntime;

  @visibleForTesting
  Future<void> Function({
    required String networkKey,
    required String peerId,
    required ChatEnvelopeType type,
    String? conversationId,
    String? channelId,
    required Map<String, dynamic> payload,
  })? debugSendEnvelopeToPeer;

  List<ChatConversationSummary> conversations = const [];
  List<ChatPeer> onlinePeers = const [];
  List<ChatPeer> friendPeers = const [];
  List<ChatChannel> channels = const [];
  List<ChatMessage> activeMessages = const [];
  Map<String, ChatPeer> peerIndex = const {};
  Map<String, ChatFriendStatus> friendStatuses = const {};

  String? selectedConversationId;
  ChatCallSession? callSession;
  RemoteAssistSession? remoteAssistSession;
  String? _lastRemoteAssistHostError;
  String? _lastRemoteAssistConnectError;
  String? _lastRemoteAssistBundledRuntimePath;
  String? _lastRemoteAssistInstalledRuntimePath;
  int? _lastRemoteAssistListenPort;
  String? statusMessage;
  int statusVersion = 0;
  int _lastConsumedStatusVersion = -1;
  String? _lastPushedStatusMessage;
  DateTime? _lastPushedStatusAt;
  int _pendingOutgoingAttachmentCount = 0;
  final Set<String> _processingRemoteAssistAcceptSessionIds = <String>{};

  ChatAudioService get _audio => ChatAudioService.instance;

  bool get isVoiceRecording => _audio.isVoiceRecording;

  bool get isChatAudioSupported => _audio.isAudioFeatureSupported;

  bool get isSendingAttachment => _pendingOutgoingAttachmentCount > 0;

  String get chatAudioUnsupportedReason => _audio.unsupportedReason;

  bool get chatAudioHeadsetRecommended => _audio.headsetRecommended;

  List<ChatConversationSummary> get directConversations => conversations
      .where((conversation) => conversation.type == ChatConversationType.direct)
      .toList();

  List<ChatConversationSummary> get lobbyConversations => conversations
      .where((conversation) =>
          conversation.type == ChatConversationType.channel &&
          isLobbyChannelId(conversation.channelId))
      .toList();

  List<ChatConversationSummary> get channelConversations => conversations
      .where(
          (conversation) => conversation.type == ChatConversationType.channel)
      .toList();

  List<ChatConversationSummary> get roomConversations => channelConversations
      .where((conversation) => !isLobbyChannelId(conversation.channelId))
      .toList();

  bool get isRemoteAssistSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get isRemoteAssistRuntimeReady => _remoteAssistRuntimeReady;

  List<String> get connectedNetworkKeys {
    final keys = _services.keys.toList()..sort();
    return keys;
  }

  bool get hasMultipleNetworks => connectedNetworkKeys.length > 1;

  List<String> connectedNetworkKeysForScope({String? scopedNetworkKey}) {
    final keys = connectedNetworkKeys;
    final normalizedScope = scopedNetworkKey?.trim() ?? '';
    if (normalizedScope.isEmpty) {
      return keys;
    }
    return keys.where((key) => key == normalizedScope).toList();
  }

  bool hasMultipleNetworksInScope({String? scopedNetworkKey}) {
    return connectedNetworkKeysForScope(scopedNetworkKey: scopedNetworkKey)
            .length >
        1;
  }

  List<ChatConversationSummary> directConversationsForScope({
    String? scopedNetworkKey,
  }) {
    return directConversations
        .where(
          (conversation) => chatMatchesNetworkScope(
            conversation.networkKey,
            scopedNetworkKey,
          ),
        )
        .toList();
  }

  List<ChatConversationSummary> lobbyConversationsForScope({
    String? scopedNetworkKey,
  }) {
    return lobbyConversations
        .where(
          (conversation) => chatMatchesNetworkScope(
            conversation.networkKey,
            scopedNetworkKey,
          ),
        )
        .toList();
  }

  List<ChatConversationSummary> roomConversationsForScope({
    String? scopedNetworkKey,
  }) {
    return roomConversations
        .where(
          (conversation) => chatMatchesNetworkScope(
            conversation.networkKey,
            scopedNetworkKey,
          ),
        )
        .toList();
  }

  List<ChatConversationSummary> channelConversationsForScope({
    String? scopedNetworkKey,
  }) {
    return channelConversations
        .where(
          (conversation) => chatMatchesNetworkScope(
            conversation.networkKey,
            scopedNetworkKey,
          ),
        )
        .toList();
  }

  List<ChatChannel> channelsForScope({String? scopedNetworkKey}) {
    return channels
        .where(
          (channel) => chatMatchesNetworkScope(
            channel.networkKey,
            scopedNetworkKey,
          ),
        )
        .toList();
  }

  List<ChatPeer> onlinePeersForScope({String? scopedNetworkKey}) {
    return onlinePeers
        .where(
          (peer) => chatMatchesNetworkScope(peer.networkKey, scopedNetworkKey),
        )
        .toList();
  }

  static bool isLobbyChannelId(String? channelId) {
    return channelId != null && channelId.startsWith('lobby:');
  }

  Future<void> init() {
    if (_initialized) {
      return Future.value();
    }
    return _initFuture ??= _initInternal();
  }

  Future<void> _initInternal() async {
    try {
      if (_initialized) {
        return;
      }
      await _logger.init();
      await _repository.init();
      await _audio.init();
      _remoteAssistRuntimeReady = await _remoteAssist.isAvailable();
      if (_remoteAssistRuntimeReady) {
        try {
          await _remoteAssist.cleanupManagedSessionState(
            listenPort: RemoteAssistService.listenPort,
          );
          _lastRemoteAssistHostError = null;
          await _refreshRemoteAssistRuntimeDetails(
            listenPort: RemoteAssistService.listenPort,
          );
          await _logRemoteAssistInfo(
            '内置 RustDesk 启动期会话清理完成',
            extra: {
              'startupCleanup': true,
            },
          );
        } catch (error, stackTrace) {
          _lastRemoteAssistHostError = error.toString();
          await _logger.warn(
            'remote_assist.runtime',
            '内置 RustDesk 启动期会话清理失败',
            extra: {
              'error': error.toString(),
              'stackTrace': stackTrace.toString(),
            },
          );
        }
      }
      if (!_chatFirewallChecked) {
        _chatFirewallChecked = true;
        await _ensureFirewallRules(
          includeRemoteAssist: false,
          contextLabel: '聊天室',
          pushStatusOnFailure: true,
        );
      }
      await _purgeRetentionIfNeeded(force: true);
      _syncTimer = Timer.periodic(_syncInterval, (_) {
        unawaited(syncConnections());
      });
      await syncConnections();
      _initialized = true;
      await _logger.info('manager', '聊天室管理器初始化完成', extra: {
        'connectedNetworks': connectedNetworkKeys,
        'databasePath': await _repository.databasePath,
        'logFilePath': _logger.logFilePath,
      });
    } finally {
      if (!_initialized) {
        _initFuture = null;
      }
    }
  }

  Future<void> disposeManager() async {
    _syncTimer?.cancel();
    _syncTimer = null;
    for (final service in _services.values) {
      await service.dispose();
    }
    _services.clear();
    await _audio.dispose();
    _initialized = false;
    await _logger.info('manager', '聊天室管理器已释放');
  }

  Future<void> syncConnections() async {
    final activeKeys = <String>{};
    for (final entry in vntManager.map.entries) {
      final key = entry.key;
      final box = entry.value;
      if (box.isClosed()) {
        continue;
      }
      final localIp = box.currentDevice()['virtualIp'] as String? ?? '';
      if (localIp.isEmpty) {
        continue;
      }
      activeKeys.add(key);
      final service = _services.putIfAbsent(
        key,
        () => ChatNetworkService(
          networkKey: key,
          vntBox: box,
          delegate: this,
        ),
      );
      if (!service.isStarted) {
        try {
          await service.start();
          _networkStartRetryCounts.remove(key);
        } catch (error, stackTrace) {
          if (ChatNetworkService.isRetryableStartError(error)) {
            final retryCount = (_networkStartRetryCounts[key] ?? 0) + 1;
            _networkStartRetryCounts[key] = retryCount;
            await _logger.warn(
              'manager.network',
              '聊天室网络监听等待虚拟IP就绪，将自动重试',
              networkKey: key,
              extra: {
                'localVirtualIp': localIp,
                'retryCount': retryCount,
                'error': error.toString(),
              },
            );
            if (retryCount == 3 || retryCount % 10 == 0) {
              _pushStatus(
                '聊天室本地监听正在等待虚拟IP就绪（已连接服务器，将自动重试）',
              );
            }
            continue;
          }
          _networkStartRetryCounts.remove(key);
          await _logger.error(
            'manager.network',
            '聊天室网络监听启动失败',
            networkKey: key,
            extra: {
              'error': error.toString(),
            },
          );
          onNetworkWarning(key, error, stackTrace);
          continue;
        }
      }
      await _syncNetworkPeers(key, box);
    }

    final staleKeys =
        _services.keys.where((key) => !activeKeys.contains(key)).toList();
    for (final key in staleKeys) {
      await _services.remove(key)?.dispose();
      await _repository.markNetworkPeersOffline(key);
      _networkStartRetryCounts.remove(key);
      if (remoteAssistSession?.networkKey == key) {
        remoteAssistSession = remoteAssistSession?.copyWith(
          state: RemoteAssistState.ended,
          updatedAt: DateTime.now(),
        );
      }
    }
    await _expirePendingAttachments();
    await _purgeRetentionIfNeeded();
    await _reloadSidebar();
    await _logger.info('manager.sync', '聊天室连接同步完成', extra: {
      'connectedNetworks': connectedNetworkKeys,
      'onlinePeers': onlinePeers.length,
      'conversations': conversations.length,
    });
  }

  Future<void> _expirePendingAttachments() async {
    final now = DateTime.now();
    final pending = await _repository.listPendingAttachments();
    for (final attachment in pending) {
      if (attachment.expiresAt == null || attachment.expiresAt!.isAfter(now)) {
        continue;
      }
      await _repository.upsertAttachment(
        attachment.copyWith(
          offerStatus: ChatMessageStatus.expired,
          transferStatus: ChatMessageStatus.expired,
        ),
      );
      final message = await _repository.getMessage(attachment.messageId);
      if (message != null) {
        await _repository.replaceMessage(
          message.copyWith(status: ChatMessageStatus.expired),
        );
        await _logger.warn(
          'attachment.expire',
          '附件状态已过期',
          extra: {
            'attachmentId': attachment.attachmentId,
            'messageId': attachment.messageId,
          },
        );
      }
    }
  }

  Future<void> _syncNetworkPeers(String networkKey, VntBox box) async {
    final service = _services[networkKey];
    if (service == null) {
      return;
    }
    final now = DateTime.now();
    final localIp = box.currentDevice()['virtualIp'] as String? ?? '';
    final localPeerId = ChatIds.peerId(networkKey, localIp);
    final localDeviceName = box.getNetConfig()?.deviceName ?? localIp;
    final localExisting = await _repository.getPeer(localPeerId);
    final localCapabilities = [
      'text',
      'image',
      'file',
      'voice_note',
      'voice_call',
      'channels',
      ...await _remoteAssist.localCapabilities(),
    ];
    await _repository.upsertPeer(
      ChatPeer(
        peerId: localPeerId,
        networkKey: networkKey,
        virtualIp: localIp,
        deviceName: localExisting?.deviceName == localIp
            ? localDeviceName
            : (localExisting?.deviceName ?? localDeviceName),
        remark: localExisting?.remark ?? '',
        isOnline: true,
        lastSeenAt: now,
        capabilities: localCapabilities,
        createdAt: localExisting?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    await _ensureDefaultLobbyForNetwork(
      networkKey: networkKey,
      localPeerId: localPeerId,
      now: now,
    );

    final peers = box.peerDeviceList();
    final seen = <String>{localPeerId};
    for (final peer in peers) {
      final peerId = ChatIds.peerId(networkKey, peer.virtualIp);
      seen.add(peerId);
      final existing = await _repository.getPeer(peerId);
      await _repository.upsertPeer(
        ChatPeer(
          peerId: peerId,
          networkKey: networkKey,
          virtualIp: peer.virtualIp,
          deviceName: existing?.deviceName.isNotEmpty == true
              ? existing!.deviceName
              : (peer.name.isNotEmpty ? peer.name : peer.virtualIp),
          remark: existing?.remark ?? '',
          isOnline: peer.status.trim().toLowerCase() == 'online',
          lastSeenAt: now,
          capabilities: existing?.capabilities ?? const [],
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        ),
      );
    }

    final existingPeers = await _repository.listPeers(networkKey: networkKey);
    for (final peer in existingPeers) {
      if (seen.contains(peer.peerId)) {
        continue;
      }
      await _repository.upsertPeer(
        peer.copyWith(
          isOnline: false,
          lastSeenAt: now,
          updatedAt: now,
        ),
      );
    }
    await service.refreshPeers(peers);
    await _logger.info(
      'manager.discovery',
      '同步在线设备完成',
      networkKey: networkKey,
      extra: {
        'localPeerId': localPeerId,
        'peerCount': peers.length,
      },
    );
  }

  Future<void> _purgeRetentionIfNeeded({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastRetentionAt != null &&
        now.difference(_lastRetentionAt!) < const Duration(hours: 12)) {
      return;
    }
    await _repository.purgeExpiredData();
    _lastRetentionAt = now;
  }

  Future<void> _reloadSidebar() async {
    final conversationsList = await _repository.listConversations();
    final channelList = await _repository.listChannels();
    final allPeers = await _repository.listPeers();
    final friends = await _repository.listFriends();
    final now = DateTime.now();
    final normalizedPeers = allPeers
        .map((peer) => _normalizePeerOnlineState(peer, now))
        .toList(growable: false);
    final normalizedPeerIndex = {
      for (final peer in normalizedPeers) peer.peerId: peer,
    };
    final peers = <ChatPeer>[];
    final localPeerIds = connectedNetworkKeys
        .map(_localPeerIdForNetwork)
        .whereType<String>()
        .toSet();
    for (final friend in friends) {
      final peer = normalizedPeerIndex[friend.peerId];
      if (peer != null) {
        peers.add(peer);
      }
    }
    conversations = conversationsList
        .map((conversation) => _resolveConversationSummary(
              conversation,
              normalizedPeers,
              channelList,
            ))
        .toList();
    channels = channelList.where((channel) => !channel.archived).toList();
    onlinePeers = normalizedPeers
        .where((peer) => peer.isOnline && !localPeerIds.contains(peer.peerId))
        .toList()
      ..sort((a, b) {
        final networkCompare = a.networkKey.compareTo(b.networkKey);
        if (networkCompare != 0) {
          return networkCompare;
        }
        return a.virtualIp.compareTo(b.virtualIp);
      });
    friendPeers = peers;
    peerIndex = normalizedPeerIndex;
    friendStatuses = {
      for (final friend in friends) friend.peerId: friend.status,
    };
    if (selectedConversationId != null) {
      activeMessages = await _repository.listMessages(selectedConversationId!);
    }
    notifyListeners();
  }

  ChatConversationSummary _resolveConversationSummary(
    ChatConversationSummary conversation,
    List<ChatPeer> allPeers,
    List<ChatChannel> allChannels,
  ) {
    if (conversation.type == ChatConversationType.direct &&
        conversation.peerId != null) {
      final peer = allPeers
          .where((item) => item.peerId == conversation.peerId)
          .firstOrNull;
      if (peer != null && peer.displayName != conversation.title) {
        return conversation.copyWith(title: peer.displayName);
      }
      return conversation;
    }
    if (conversation.channelId != null) {
      final channel = allChannels
          .where((item) => item.channelId == conversation.channelId)
          .firstOrNull;
      if (channel != null && channel.name != conversation.title) {
        return conversation.copyWith(title: channel.name);
      }
    }
    return conversation;
  }

  Future<void> selectConversation(String conversationId) async {
    selectedConversationId = conversationId;
    await _repository.markConversationRead(conversationId);
    activeMessages = await _repository.listMessages(conversationId);
    await _reloadSidebar();
  }

  ChatConversationSummary? get selectedConversation {
    if (selectedConversationId == null) {
      return null;
    }
    for (final item in conversations) {
      if (item.conversationId == selectedConversationId) {
        return item;
      }
    }
    return null;
  }

  ChatPeer? findPeer(String? peerId) {
    if (peerId == null) {
      return null;
    }
    return peerIndex[peerId];
  }

  bool isPeerOnline(ChatPeer peer, {DateTime? now}) {
    return chatPeerIsEffectivelyOnline(peer, now: now);
  }

  ChatFriendStatus friendStatusOf(String peerId) {
    return friendStatuses[peerId] ?? ChatFriendStatus.stranger;
  }

  bool isPeerBlocked(String peerId) {
    return friendStatusOf(peerId) == ChatFriendStatus.blocked;
  }

  Duration _statusCooldownForMessage(String message) {
    if (message.contains('防火墙') || message.contains('虚拟IP')) {
      return const Duration(seconds: 90);
    }
    return const Duration(seconds: 3);
  }

  bool consumeStatusVersion(int version) {
    if (version <= _lastConsumedStatusVersion) {
      return false;
    }
    _lastConsumedStatusVersion = version;
    return true;
  }

  bool shouldShowStatusSnackBar(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    return !(trimmed.contains('虚拟IP') || trimmed.contains('防火墙'));
  }

  void _pushStatus(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (_lastPushedStatusMessage == trimmed && _lastPushedStatusAt != null) {
      final cooldown = _statusCooldownForMessage(trimmed);
      if (now.difference(_lastPushedStatusAt!) < cooldown) {
        return;
      }
    }
    _lastPushedStatusMessage = trimmed;
    _lastPushedStatusAt = now;
    statusMessage = trimmed;
    statusVersion++;
    notifyListeners();
    unawaited(_logger.warn('status', trimmed));
  }

  Future<bool> _ensureChatAudioAvailable(
    String action, {
    String? networkKey,
    Map<String, dynamic>? extra,
  }) async {
    if (_audio.isAudioFeatureSupported) {
      return true;
    }
    final message = '${_audio.unsupportedReason}，暂时无法$action';
    _pushStatus(message);
    await _logger.warn(
      'voice.unsupported',
      '聊天室音频能力不可用',
      networkKey: networkKey,
      extra: {
        'action': action,
        'reason': _audio.unsupportedReason,
        if (extra != null) ...extra,
      },
    );
    return false;
  }

  Future<void> debugRefreshNow() async {
    if (_lastChatFirewallResult?.success != true) {
      await _ensureFirewallRules(
        includeRemoteAssist: false,
        contextLabel: '聊天室',
        pushStatusOnFailure: true,
      );
    }
    for (final service in _services.values) {
      service.resetDiscoveryState();
    }
    await _logger.info('debug', '手动触发聊天室联调刷新');
    await syncConnections();
    _pushStatus('聊天室状态已刷新');
  }

  Future<void> clearAllChatData() async {
    await _logger.warn('debug', '开始清空聊天室本地数据');
    await _stopAudioStreams();
    if (_audio.isVoiceRecording) {
      await _audio.cancelVoiceNoteRecording();
    }
    callSession = null;
    selectedConversationId = null;
    activeMessages = const [];
    conversations = const [];
    channels = const [];
    onlinePeers = const [];
    friendPeers = const [];
    peerIndex = const {};
    friendStatuses = const {};
    _mediaPlaybackPackets = 0;
    await _repository.clearAllChatData();
    await _logger.clear();
    await _logger.info('debug', '聊天室日志已清空并重新开始记录');
    for (final service in _services.values) {
      service.resetDiscoveryState();
    }
    await syncConnections();
    _pushStatus('聊天室本地数据已清空');
  }

  String _formatFirewallRules(List<WindowsFirewallRuleSpec> rules) {
    if (rules.isEmpty) {
      return 'none';
    }
    return rules.map((rule) => '${rule.signature}(${rule.purpose})').join(', ');
  }

  Future<WindowsFirewallEnsureResult> _ensureFirewallRules({
    required bool includeRemoteAssist,
    required String contextLabel,
    bool pushStatusOnFailure = false,
  }) async {
    final result = await _firewall.ensureChatAndRemoteAssistRules(
      includeRemoteAssist: includeRemoteAssist,
    );
    if (includeRemoteAssist) {
      _lastRemoteAssistFirewallResult = result;
    } else {
      _lastChatFirewallResult = result;
    }
    if (result.success) {
      await _logger.info(
        'firewall',
        result.firewallEnabled
            ? '$contextLabel 端口放行检查完成'
            : '$contextLabel 检测到 Windows 防火墙已关闭，跳过端口放行检查',
        extra: {
          'includeRemoteAssist': includeRemoteAssist,
          'promptedForElevation': result.promptedForElevation,
          'firewallEnabled': result.firewallEnabled,
          'skippedRuleCheck': result.skippedRuleCheck,
          'allowedRules': result.allowedRules
              .map((rule) => rule.signature)
              .toList(growable: false),
        },
      );
      return result;
    }

    final message = result.errorMessage?.trim().isNotEmpty == true
        ? result.errorMessage!.trim()
        : '仍缺少放行规则: ${_formatFirewallRules(result.missingRules)}';
    await _logger.error(
      'firewall',
      '$contextLabel 端口放行检查失败',
      extra: {
        'includeRemoteAssist': includeRemoteAssist,
        'promptedForElevation': result.promptedForElevation,
        'failureKind': result.failureKind.name,
        'blocksRemoteAssist': result.blocksRemoteAssist,
        'firewallEnabled': result.firewallEnabled,
        'skippedRuleCheck': result.skippedRuleCheck,
        'missingRules': result.missingRules
            .map((rule) => rule.signature)
            .toList(growable: false),
        'error': message,
        if (result.attemptedCommand != null)
          'attemptedCommand': result.attemptedCommand,
        if (result.processExitCode != null)
          'processExitCode': result.processExitCode,
        if (result.processStdout != null) 'processStdout': result.processStdout,
        if (result.processStderr != null) 'processStderr': result.processStderr,
        if (result.elevatedScriptStarted != null)
          'elevatedScriptStarted': result.elevatedScriptStarted,
      },
    );
    if (pushStatusOnFailure) {
      _pushStatus(
        '$contextLabel 可能被 Windows 防火墙拦截，请允许管理员授权或手动放行相关端口',
      );
    }
    return result;
  }

  bool _remoteAssistFirewallHasWarning(WindowsFirewallEnsureResult result) {
    return result.failureKind != WindowsFirewallEnsureFailureKind.none &&
        result.failureKind != WindowsFirewallEnsureFailureKind.firewallDisabled;
  }

  String _remoteAssistControlledReadyStatusMessage(
    WindowsFirewallEnsureResult result,
  ) {
    if (_remoteAssistFirewallHasWarning(result)) {
      return '桌面服务已启动，但 Windows 防火墙未确认放行；若对方无法接入，请手动放行 TCP 21118';
    }
    return '桌面服务已启动，正在等待对方接入';
  }

  Future<WindowsFirewallEnsureResult> _ensureRemoteAssistFirewallState(
    RemoteAssistSession session,
  ) async {
    final result = debugEnsureRemoteAssistFirewallResult != null
        ? await debugEnsureRemoteAssistFirewallResult!(session)
        : await _ensureFirewallRules(
            includeRemoteAssist: true,
            contextLabel: '远程协助',
            pushStatusOnFailure: false,
          );
    _lastRemoteAssistFirewallResult = result;
    _lastRemoteAssistFirewallBlockedReady = result.blocksRemoteAssist;
    final logMessage = result.success
        ? '远程协助端口放行检查完成'
        : result.blocksRemoteAssist
            ? '远程协助端口放行失败并阻断桌面服务就绪'
            : '远程协助端口放行未确认，将继续尝试启动桌面服务';
    final logExtra = {
      'sessionId': session.sessionId,
      'listenPort': session.listenPort,
      'success': result.success,
      'failureKind': result.failureKind.name,
      'blocksRemoteAssist': result.blocksRemoteAssist,
      'firewallEnabled': result.firewallEnabled,
      'skippedRuleCheck': result.skippedRuleCheck,
      'promptedForElevation': result.promptedForElevation,
      'allowedRules': result.allowedRules
          .map((rule) => rule.signature)
          .toList(growable: false),
      'missingRules': result.missingRules
          .map((rule) => rule.signature)
          .toList(growable: false),
      if (result.errorMessage != null) 'error': result.errorMessage,
      if (result.attemptedCommand != null)
        'attemptedCommand': result.attemptedCommand,
      if (result.processExitCode != null)
        'processExitCode': result.processExitCode,
      if (result.processStdout != null) 'processStdout': result.processStdout,
      if (result.processStderr != null) 'processStderr': result.processStderr,
      if (result.elevatedScriptStarted != null)
        'elevatedScriptStarted': result.elevatedScriptStarted,
    };
    if (result.success) {
      await _logger.info(
        'remote_assist.firewall',
        logMessage,
        networkKey: session.networkKey,
        extra: logExtra,
      );
    } else if (result.blocksRemoteAssist) {
      await _logger.error(
        'remote_assist.firewall',
        logMessage,
        networkKey: session.networkKey,
        extra: logExtra,
      );
    } else {
      await _logger.warn(
        'remote_assist.firewall',
        logMessage,
        networkKey: session.networkKey,
        extra: logExtra,
      );
    }
    return result;
  }

  Future<WindowsFirewallEnsureResult> _prepareControlledLocalRemoteAssistHost(
    RemoteAssistSession session,
  ) async {
    _pushStatus('已同意远程协助，正在准备本机桌面服务');
    await _logRemoteAssistInfo(
      '开始准备本机桌面服务',
      session: session,
    );
    final firewallResult = await _ensureRemoteAssistFirewallState(session);
    await _logRemoteAssistInfo(
      '远程协助防火墙检查结果',
      session: session,
      extra: {
        'firewallSuccess': firewallResult.success,
        'firewallFailureKind': firewallResult.failureKind.name,
        'firewallBlocksRemoteAssist': firewallResult.blocksRemoteAssist,
        'firewallEnabled': firewallResult.firewallEnabled,
        'firewallSkippedRuleCheck': firewallResult.skippedRuleCheck,
        if (firewallResult.errorMessage != null)
          'firewallError': firewallResult.errorMessage,
      },
    );
    if (firewallResult.blocksRemoteAssist) {
      _lastRemoteAssistHostReadySucceeded = false;
      throw StateError(
        firewallResult.errorMessage?.trim().isNotEmpty == true
            ? firewallResult.errorMessage!.trim()
            : '远程协助防火墙检查阻断了桌面服务启动',
      );
    }
    try {
      if (debugEnsureRemoteAssistHostReady != null) {
        await debugEnsureRemoteAssistHostReady!(
          session.listenPort,
          session.sessionToken,
        );
      } else {
        await _remoteAssist.ensureHostReady(
          listenPort: session.listenPort,
          sessionToken: session.sessionToken,
        );
      }
      _lastRemoteAssistHostError = null;
      _lastRemoteAssistHostReadySucceeded = true;
      await _logRemoteAssistInfo(
        '本机桌面服务已就绪',
        session: session,
        extra: {
          'firewallWarning': _remoteAssistFirewallHasWarning(firewallResult),
          'firewallFailureKind': firewallResult.failureKind.name,
        },
      );
      return firewallResult;
    } catch (error, stackTrace) {
      _lastRemoteAssistHostError = error.toString();
      _lastRemoteAssistHostReadySucceeded = false;
      await _logger.error(
        'remote_assist.host',
        '本机桌面服务就绪失败',
        networkKey: session.networkKey,
        extra: {
          'sessionId': session.sessionId,
          'listenPort': session.listenPort,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
          if (_lastRemoteAssistBundledRuntimePath != null)
            'bundledRuntime': _lastRemoteAssistBundledRuntimePath,
          if (_lastRemoteAssistInstalledRuntimePath != null)
            'installedRuntime': _lastRemoteAssistInstalledRuntimePath,
          'firewallFailureKind': firewallResult.failureKind.name,
        },
      );
      rethrow;
    }
  }

  Future<String> buildDiagnosticsReport() async {
    final dbPath = await _repository.databasePath;
    final baseDir = await _repository.baseDirectoryPath;
    final attachmentsDir = (await _repository.attachmentsDirectory).path;
    final tempDir = (await _repository.tempDirectory).path;
    final bundledRuntimePath = await _remoteAssist.bundledRuntimePath();
    final companionExecutablePath =
        await _remoteAssist.companionExecutablePath();
    final installedRuntimePath = await _remoteAssist.installedRuntimePath();
    final managedRuntimeHome = await _remoteAssist.managedRuntimeHomePath();
    final managedConfigDir = await _remoteAssist.managedConfigDirectoryPath();
    final managedLogsDir = await _remoteAssist.managedLogsDirectoryPath();
    await _remoteAssist.syncManagedLogsToMirror();
    final managedRustDeskLogsDir =
        await _remoteAssist.managedRustDeskInternalLogsDirectoryPath();
    final mirroredCompanionLogsDir =
        await _remoteAssist.mirroredCompanionLogsDirectoryPath();
    final firewallStatus =
        await _firewall.checkRuleStatus(includeRemoteAssist: true);
    final buffer = StringBuffer()
      ..writeln('聊天室联调诊断')
      ..writeln('时间: ${DateTime.now().toIso8601String()}')
      ..writeln('日志文件: ${_logger.logFilePath}')
      ..writeln('数据库: $dbPath')
      ..writeln('聊天目录: $baseDir')
      ..writeln('附件目录: $attachmentsDir')
      ..writeln('临时目录: $tempDir')
      ..writeln('连接网络: ${connectedNetworkKeys.join(', ')}')
      ..writeln('在线设备数: ${onlinePeers.length}')
      ..writeln('会话数: ${conversations.length}')
      ..writeln('频道数: ${channels.length}')
      ..writeln('音频后端: ${_audio.backendName}')
      ..writeln('语音消息格式: ${_audio.preferredVoiceCodecLabel}')
      ..writeln('音频能力支持: $isChatAudioSupported')
      ..writeln(
          '音频说明: ${isChatAudioSupported ? '已启用' : chatAudioUnsupportedReason}')
      ..writeln('建议佩戴耳机: ${_audio.headsetRecommended}')
      ..writeln('实时输入采样率: ${_audio.liveInputSampleRate ?? 'unknown'}')
      ..writeln('实时输出采样率: ${_audio.liveOutputSampleRate ?? 'unknown'}')
      ..writeln('最近音频错误: ${_audio.lastAudioError ?? 'none'}')
      ..writeln('语音录音中: ${_audio.isVoiceRecording}')
      ..writeln('麦克风流开启: ${_audio.isStreamingMic}')
      ..writeln('实时播放器开启: ${_audio.isIncomingStreamPlaying}')
      ..writeln(
          '当前通话: ${callSession?.type.name ?? 'none'} / ${callSession?.state.name ?? 'idle'}');
    buffer
      ..writeln('Windows 防火墙已启用: ${firewallStatus.firewallEnabled}')
      ..writeln('Windows 防火墙规则已就绪: ${firewallStatus.success}')
      ..writeln('Windows 防火墙跳过规则检查: ${firewallStatus.skippedRuleCheck}')
      ..writeln('Windows 防火墙结果分类: ${firewallStatus.failureKind.name}')
      ..writeln(
          'Windows 防火墙已放行: ${_formatFirewallRules(firewallStatus.allowedRules)}')
      ..writeln(
          'Windows 防火墙缺失: ${_formatFirewallRules(firewallStatus.missingRules)}')
      ..writeln(
          '最近聊天室防火墙授权: ${_lastChatFirewallResult?.promptedForElevation ?? false}')
      ..writeln(
          '最近远程协助防火墙授权: ${_lastRemoteAssistFirewallResult?.promptedForElevation ?? false}')
      ..writeln(
          '最近远程协助防火墙结果分类: ${_lastRemoteAssistFirewallResult?.failureKind.name ?? WindowsFirewallEnsureFailureKind.none.name}')
      ..writeln('最近远程协助防火墙是否阻断 ready: $_lastRemoteAssistFirewallBlockedReady')
      ..writeln(
          '最近远程协助防火墙命令: ${_lastRemoteAssistFirewallResult?.attemptedCommand ?? 'none'}')
      ..writeln(
          '最近远程协助防火墙退出码: ${_lastRemoteAssistFirewallResult?.processExitCode?.toString() ?? 'none'}')
      ..writeln(
          '最近防火墙错误: ${_lastRemoteAssistFirewallResult?.errorMessage ?? _lastChatFirewallResult?.errorMessage ?? 'none'}')
      ..writeln('远程协助运行时就绪: $_remoteAssistRuntimeReady')
      ..writeln(
          '远程协助运行策略: bundled-only + VNT virtual-ip direct + session-password')
      ..writeln('远程协助 bundled runtime: ${bundledRuntimePath ?? 'missing'}')
      ..writeln(
          '附带 rustdesk_qs.exe（仅分发兼容）: ${companionExecutablePath ?? 'missing'}')
      ..writeln(
          '系统安装 RustDesk（仅诊断，不参与启动）: ${installedRuntimePath ?? 'missing'}')
      ..writeln('远程协助受管目录: $managedRuntimeHome')
      ..writeln('远程协助受管配置目录: $managedConfigDir')
      ..writeln('远程协助受管 supervisor 日志目录: $managedLogsDir')
      ..writeln('远程协助受管 RustDesk 日志目录: $managedRustDeskLogsDir')
      ..writeln('远程协助镜像日志目录: $mirroredCompanionLogsDir')
      ..writeln(
          '最近内置 RustDesk host 命令: ${_remoteAssist.lastHostCommand ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host 模式: ${_remoteAssist.lastHostLaunchMode ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host 日志: ${_remoteAssist.lastHostLogPath ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host 镜像日志: ${_remoteAssist.lastCompanionMirrorLogPath ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host 退出码: ${_remoteAssist.lastHostExitCode?.toString() ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host stdout: ${_remoteAssist.lastHostStdoutSnippet ?? 'none'}')
      ..writeln(
          '最近内置 RustDesk host stderr: ${_remoteAssist.lastHostStderrSnippet ?? 'none'}')
      ..writeln(
          '最近远程协助监听端口: ${_lastRemoteAssistListenPort ?? RemoteAssistService.listenPort}')
      ..writeln(
          '最近远程协助 host ready 成功: ${_lastRemoteAssistHostReadySucceeded?.toString() ?? 'unknown'}')
      ..writeln(
          '最近 remoteAssistReady 已发送: ${_lastRemoteAssistReadySentAt?.toIso8601String() ?? 'none'}')
      ..writeln(
          '最近 remoteAssistReady 已接收: ${_lastRemoteAssistReadyReceivedAt?.toIso8601String() ?? 'none'}')
      ..writeln('最近远程协助 host 错误: ${_lastRemoteAssistHostError ?? 'none'}')
      ..writeln(
          '最近远程协助 connect 错误: ${_lastRemoteAssistConnectError ?? 'none'}');
    if (remoteAssistSession != null) {
      buffer
        ..writeln(
            '当前远程协助: ${remoteAssistSession!.mode.name} / ${remoteAssistSession!.state.name}')
        ..writeln('远程协助 controller: ${remoteAssistSession!.controllerPeerId}')
        ..writeln('远程协助 controlled: ${remoteAssistSession!.controlledPeerId}')
        ..writeln(
            '远程协助 controllerIp: ${remoteAssistSession!.controllerVirtualIp}')
        ..writeln(
            '远程协助 controlledIp: ${remoteAssistSession!.controlledVirtualIp}')
        ..writeln('远程协助 listenPort: ${remoteAssistSession!.listenPort}');
    }
    for (final entry in _services.entries) {
      final service = entry.value;
      buffer
        ..writeln('--- 网络 ${entry.key} ---')
        ..writeln('本机虚拟 IP: ${service.localVirtualIp}')
        ..writeln('控制端口: ${ChatNetworkService.controlPort}')
        ..writeln('附件端口: ${ChatNetworkService.attachmentPort}')
        ..writeln('语音端口: ${ChatNetworkService.mediaPort}')
        ..writeln('语音已发包: ${service.mediaSentPackets}')
        ..writeln('语音已收包: ${service.mediaReceivedPackets}');
    }
    buffer.writeln('本地播放已收包: $_mediaPlaybackPackets');
    return buffer.toString();
  }

  Future<void> _refreshRemoteAssistRuntimeDetails({
    int? listenPort,
  }) async {
    if (debugRefreshRemoteAssistRuntime != null) {
      await debugRefreshRemoteAssistRuntime!(listenPort: listenPort);
      return;
    }
    _remoteAssistRuntimeReady = await _remoteAssist.isAvailable();
    _lastRemoteAssistBundledRuntimePath =
        await _remoteAssist.bundledRuntimePath();
    _lastRemoteAssistInstalledRuntimePath =
        await _remoteAssist.installedRuntimePath();
    _lastRemoteAssistListenPort = listenPort ?? _lastRemoteAssistListenPort;
  }

  Future<void> _logRemoteAssistInfo(
    String message, {
    RemoteAssistSession? session,
    String? networkKey,
    Map<String, Object?> extra = const {},
  }) async {
    final currentSession = session ?? remoteAssistSession;
    final payload = <String, Object?>{
      if (currentSession != null) 'sessionId': currentSession.sessionId,
      if (currentSession != null) 'mode': currentSession.mode.name,
      if (currentSession != null) 'state': currentSession.state.name,
      if (currentSession != null)
        'controllerPeerId': currentSession.controllerPeerId,
      if (currentSession != null)
        'controlledPeerId': currentSession.controlledPeerId,
      if (currentSession != null)
        'controllerVirtualIp': currentSession.controllerVirtualIp,
      if (currentSession != null)
        'controlledVirtualIp': currentSession.controlledVirtualIp,
      if (currentSession != null) 'listenPort': currentSession.listenPort,
      if (_lastRemoteAssistBundledRuntimePath != null)
        'bundledRuntime': _lastRemoteAssistBundledRuntimePath,
      if (_lastRemoteAssistInstalledRuntimePath != null)
        'installedRuntime': _lastRemoteAssistInstalledRuntimePath,
      ...extra,
    };
    await _logger.info(
      'remote_assist',
      message,
      networkKey: networkKey ?? currentSession?.networkKey,
      extra: payload,
    );
  }

  String? _localPeerIdForNetwork(String networkKey) {
    final service = _services[networkKey];
    if (service == null || service.localVirtualIp.isEmpty) {
      return null;
    }
    return ChatIds.peerId(networkKey, service.localVirtualIp);
  }

  ChatPeer _normalizePeerOnlineState(ChatPeer peer, DateTime now) {
    final effectivelyOnline = chatPeerIsEffectivelyOnline(peer, now: now);
    if (effectivelyOnline == peer.isOnline) {
      return peer;
    }
    return peer.copyWith(isOnline: effectivelyOnline);
  }

  String? preferredNetworkKey({String? scopedNetworkKey}) {
    if (selectedConversation != null &&
        chatMatchesNetworkScope(
          selectedConversation!.networkKey,
          scopedNetworkKey,
        )) {
      return selectedConversation!.networkKey;
    }
    final keys =
        connectedNetworkKeysForScope(scopedNetworkKey: scopedNetworkKey);
    if (keys.isEmpty) {
      return null;
    }
    return keys.first;
  }

  ChatChannel? preferredLobbyChannel({String? scopedNetworkKey}) {
    final networkKey = preferredNetworkKey(scopedNetworkKey: scopedNetworkKey);
    if (networkKey == null) {
      return null;
    }
    return channels
        .where((channel) =>
            channel.networkKey == networkKey &&
            channel.channelId == ChatIds.lobbyChannelId(networkKey))
        .firstOrNull;
  }

  Future<void> openPreferredLobby({String? scopedNetworkKey}) async {
    final lobby = preferredLobbyChannel(scopedNetworkKey: scopedNetworkKey);
    if (lobby == null) {
      return;
    }
    await selectConversation(
      ChatIds.channelConversationId(lobby.networkKey, lobby.channelId),
    );
  }

  Future<void> openPreferredChannelConversation(
      {String? scopedNetworkKey}) async {
    final lobby = preferredLobbyChannel(scopedNetworkKey: scopedNetworkKey);
    if (lobby != null) {
      await selectConversation(
        ChatIds.channelConversationId(lobby.networkKey, lobby.channelId),
      );
      return;
    }
    final scopedRoomConversations = roomConversationsForScope(
      scopedNetworkKey: scopedNetworkKey,
    );
    if (scopedRoomConversations.isNotEmpty) {
      await selectConversation(scopedRoomConversations.first.conversationId);
    }
  }

  bool peerSupportsRemoteAssist(ChatPeer peer) {
    return peer.capabilities.contains(RemoteAssistService.capabilityWindows) &&
        peer.capabilities.contains(RemoteAssistService.capabilityController) &&
        peer.capabilities.contains(RemoteAssistService.capabilityControlled);
  }

  Future<String?> remoteAssistUnsupportedReason(ChatPeer peer) async {
    if (!isRemoteAssistSupported) {
      return '当前平台暂不支持远程协助';
    }
    final runtimeReason = await _remoteAssist.unavailableReason();
    if (runtimeReason.isNotEmpty) {
      return runtimeReason;
    }
    if (!isPeerOnline(peer)) {
      return '对方当前不在线';
    }
    if (!peerSupportsRemoteAssist(peer)) {
      return '对方当前版本未启用远程协助';
    }
    return null;
  }

  String? remoteAssistUnavailableMessageForPeer(ChatPeer peer) {
    if (!isRemoteAssistSupported) {
      return '当前平台暂不支持远程协助';
    }
    if (!_remoteAssistRuntimeReady) {
      return 'RustDesk 运行时缺失，请重新构建或检查运行包';
    }
    if (!isPeerOnline(peer)) {
      return '对方当前不在线';
    }
    if (!peerSupportsRemoteAssist(peer)) {
      return '对方当前版本未启用远程协助';
    }
    return null;
  }

  List<ChatPeer> onlinePeersForNetwork(String networkKey) {
    return onlinePeers.where((peer) => peer.networkKey == networkKey).toList();
  }

  bool isChannelOwner(ChatChannel channel) {
    return _localPeerIdForNetwork(channel.networkKey) == channel.ownerPeerId;
  }

  Future<void> openDirectConversation(ChatPeer peer) async {
    final localPeerId = _localPeerIdForNetwork(peer.networkKey);
    if (localPeerId == null) {
      return;
    }
    final conversationId = ChatIds.directConversationId(
      peer.networkKey,
      localPeerId,
      peer.peerId,
    );
    final now = DateTime.now();
    final existing = await _repository.getConversation(conversationId);
    await _repository.upsertConversation(
      existing ??
          ChatConversationSummary(
            conversationId: conversationId,
            networkKey: peer.networkKey,
            type: ChatConversationType.direct,
            title: peer.displayName,
            peerId: peer.peerId,
            channelId: null,
            unreadCount: 0,
            lastPreview: '',
            lastMessageAt: null,
            archived: false,
            createdAt: now,
            updatedAt: now,
          ),
    );
    await _logger.info(
      'conversation',
      '打开私聊会话',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peer.peerId,
        'conversationId': conversationId,
      },
    );
    await selectConversation(conversationId);
  }

  Future<void> requestFriend(ChatPeer peer) async {
    final localPeerId = _localPeerIdForNetwork(peer.networkKey);
    if (localPeerId == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertFriend(
      ChatFriend(
        peerId: peer.peerId,
        status: ChatFriendStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peer.peerId,
      type: ChatEnvelopeType.friendRequest,
      payload: {'requesterPeerId': localPeerId},
    );
    await _logger.info(
      'friend',
      '发送好友申请',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peer.peerId,
      },
    );
    await _reloadSidebar();
  }

  Future<void> acceptFriend(String peerId) async {
    final peer = await _repository.getPeer(peerId);
    if (peer == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertFriend(
      ChatFriend(
        peerId: peerId,
        status: ChatFriendStatus.friend,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peerId,
      type: ChatEnvelopeType.friendAccept,
      payload: const {},
    );
    await _logger.info(
      'friend',
      '通过好友申请',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peerId,
      },
    );
    await _reloadSidebar();
  }

  Future<void> rejectFriend(String peerId) async {
    final peer = await _repository.getPeer(peerId);
    if (peer == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertFriend(
      ChatFriend(
        peerId: peerId,
        status: ChatFriendStatus.stranger,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peerId,
      type: ChatEnvelopeType.friendReject,
      payload: const {},
    );
    await _logger.info(
      'friend',
      '拒绝好友申请',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peerId,
      },
    );
    await _reloadSidebar();
  }

  Future<void> blockPeer(String peerId) async {
    final peer = await _repository.getPeer(peerId);
    if (peer == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertFriend(
      ChatFriend(
        peerId: peerId,
        status: ChatFriendStatus.blocked,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peerId,
      type: ChatEnvelopeType.friendBlock,
      payload: const {},
    );
    await _logger.warn(
      'friend',
      '拉黑设备',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peerId,
      },
    );
    await _reloadSidebar();
  }

  Future<void> removeFriend(String peerId) async {
    final peer = await _repository.getPeer(peerId);
    if (peer == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertFriend(
      ChatFriend(
        peerId: peerId,
        status: ChatFriendStatus.stranger,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peerId,
      type: ChatEnvelopeType.friendRemove,
      payload: const {},
    );
    await _logger.info(
      'friend',
      '删除好友',
      networkKey: peer.networkKey,
      extra: {
        'peerId': peerId,
      },
    );
    await _reloadSidebar();
  }

  Future<void> _ensureDefaultLobbyForNetwork({
    required String networkKey,
    required String localPeerId,
    required DateTime now,
  }) async {
    final channelId = ChatIds.lobbyChannelId(networkKey);
    final conversationId = ChatIds.channelConversationId(networkKey, channelId);
    final existingChannel = await _repository.getChannel(channelId);
    await _repository.upsertChannel(
      existingChannel ??
          ChatChannel(
            channelId: channelId,
            networkKey: networkKey,
            name: '大厅',
            ownerPeerId: localPeerId,
            isPrivate: false,
            joined: true,
            archived: false,
            createdAt: now,
            updatedAt: now,
          ),
    );
    await _repository.upsertChannelMember(
      ChatChannelMember(
        channelId: channelId,
        peerId: localPeerId,
        role: 'owner',
        joinedAt: now,
        updatedAt: now,
      ),
    );
    final existingConversation =
        await _repository.getConversation(conversationId);
    await _repository.upsertConversation(
      existingConversation ??
          ChatConversationSummary(
            conversationId: conversationId,
            networkKey: networkKey,
            type: ChatConversationType.channel,
            title: '大厅',
            peerId: null,
            channelId: channelId,
            unreadCount: 0,
            lastPreview: '',
            lastMessageAt: null,
            archived: false,
            createdAt: now,
            updatedAt: now,
          ),
    );
  }

  Future<void> updateRemark(String peerId, String remark) async {
    await _repository.setPeerRemark(peerId, remark);
    await _reloadSidebar();
  }

  Future<void> createChannel({
    required String networkKey,
    required String name,
    required bool isPrivate,
    List<ChatPeer> invitedPeers = const [],
  }) async {
    final localPeerId = _localPeerIdForNetwork(networkKey);
    if (localPeerId == null) {
      return;
    }
    final now = DateTime.now();
    final channelId = _uuid.v4();
    final conversationId = ChatIds.channelConversationId(networkKey, channelId);
    final channel = ChatChannel(
      channelId: channelId,
      networkKey: networkKey,
      name: name.trim(),
      ownerPeerId: localPeerId,
      isPrivate: isPrivate,
      joined: true,
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertChannel(channel);
    await _repository.upsertChannelMember(
      ChatChannelMember(
        channelId: channelId,
        peerId: localPeerId,
        role: 'owner',
        joinedAt: now,
        updatedAt: now,
      ),
    );
    await _repository.upsertConversation(
      ChatConversationSummary(
        conversationId: conversationId,
        networkKey: networkKey,
        type: ChatConversationType.channel,
        title: name.trim(),
        peerId: null,
        channelId: channelId,
        unreadCount: 0,
        lastPreview: '',
        lastMessageAt: null,
        archived: false,
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (isPrivate) {
      for (final peer in invitedPeers) {
        await _repository.upsertChannelMember(
          ChatChannelMember(
            channelId: channelId,
            peerId: peer.peerId,
            role: 'member',
            joinedAt: now,
            updatedAt: now,
          ),
        );
        await _sendEnvelopeToPeer(
          networkKey: networkKey,
          peerId: peer.peerId,
          type: ChatEnvelopeType.channelInvite,
          conversationId: conversationId,
          channelId: channelId,
          payload: {
            'channelId': channelId,
            'name': name.trim(),
            'ownerPeerId': localPeerId,
            'isPrivate': true,
          },
        );
      }
    } else {
      final peers = await _repository.listPeers(
        networkKey: networkKey,
        onlineOnly: true,
        excludeLocal: true,
        localPeerId: localPeerId,
      );
      await _broadcastToPeers(
        networkKey: networkKey,
        peers: peers.map((peer) => peer.peerId).toList(),
        type: ChatEnvelopeType.channelAnnounce,
        conversationId: conversationId,
        channelId: channelId,
        payload: {
          'channelId': channelId,
          'name': name.trim(),
          'ownerPeerId': localPeerId,
          'isPrivate': false,
        },
      );
    }
    await selectConversation(conversationId);
    await _logger.info(
      'channel',
      '创建频道',
      networkKey: networkKey,
      extra: {
        'channelId': channelId,
        'name': name.trim(),
        'isPrivate': isPrivate,
        'invitedCount': invitedPeers.length,
      },
    );
  }

  Future<void> joinChannel(ChatChannel channel) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertChannel(
      channel.copyWith(joined: true, updatedAt: now),
    );
    await _repository.upsertChannelMember(
      ChatChannelMember(
        channelId: channel.channelId,
        peerId: localPeerId,
        role: channel.ownerPeerId == localPeerId ? 'owner' : 'member',
        joinedAt: now,
        updatedAt: now,
      ),
    );
    final members = await _repository.listChannelMembers(channel.channelId);
    await _broadcastToPeers(
      networkKey: channel.networkKey,
      peers: members.map((member) => member.peerId).toList(),
      type: ChatEnvelopeType.channelJoin,
      channelId: channel.channelId,
      payload: {
        'channelId': channel.channelId,
        'peerId': localPeerId,
      },
    );
    await selectConversation(
      ChatIds.channelConversationId(channel.networkKey, channel.channelId),
    );
    await _logger.info(
      'channel',
      '加入频道',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
      },
    );
  }

  Future<void> leaveChannel(ChatChannel channel) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null) {
      return;
    }
    await leaveChannelVoice();
    final now = DateTime.now();
    await _repository.upsertChannel(
      channel.copyWith(joined: false, updatedAt: now),
    );
    await _repository.removeChannelMember(channel.channelId, localPeerId);
    final members = await _repository.listChannelMembers(channel.channelId);
    await _broadcastToPeers(
      networkKey: channel.networkKey,
      peers: members.map((member) => member.peerId).toList(),
      type: ChatEnvelopeType.channelLeave,
      channelId: channel.channelId,
      payload: {
        'channelId': channel.channelId,
        'peerId': localPeerId,
      },
    );
    await _reloadSidebar();
    await _logger.info(
      'channel',
      '退出频道',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
      },
    );
  }

  Future<void> archiveChannel(ChatChannel channel) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null || localPeerId != channel.ownerPeerId) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertChannel(
      channel.copyWith(archived: true, updatedAt: now),
    );
    final conversationId = ChatIds.channelConversationId(
      channel.networkKey,
      channel.channelId,
    );
    final conversation = await _repository.getConversation(conversationId);
    if (conversation != null) {
      await _repository.upsertConversation(
        conversation.copyWith(archived: true, updatedAt: now),
      );
    }
    final members = await _repository.listChannelMembers(channel.channelId);
    await _broadcastToPeers(
      networkKey: channel.networkKey,
      peers: members.map((member) => member.peerId).toList(),
      type: ChatEnvelopeType.channelArchive,
      channelId: channel.channelId,
      payload: {'channelId': channel.channelId},
    );
    await _reloadSidebar();
    await _logger.warn(
      'channel',
      '归档频道',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
      },
    );
  }

  Future<void> inviteMembersToChannel(
    ChatChannel channel,
    List<ChatPeer> peers,
  ) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null || localPeerId != channel.ownerPeerId) {
      return;
    }
    final now = DateTime.now();
    for (final peer in peers) {
      await _repository.upsertChannelMember(
        ChatChannelMember(
          channelId: channel.channelId,
          peerId: peer.peerId,
          role: 'member',
          joinedAt: now,
          updatedAt: now,
        ),
      );
      await _sendEnvelopeToPeer(
        networkKey: channel.networkKey,
        peerId: peer.peerId,
        type: ChatEnvelopeType.channelInvite,
        conversationId: ChatIds.channelConversationId(
          channel.networkKey,
          channel.channelId,
        ),
        channelId: channel.channelId,
        payload: {
          'channelId': channel.channelId,
          'name': channel.name,
          'ownerPeerId': channel.ownerPeerId,
          'isPrivate': true,
        },
      );
    }
    await _reloadSidebar();
    await _logger.info(
      'channel',
      '邀请频道成员',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
        'peerCount': peers.length,
      },
    );
  }

  Future<List<ChatChannel>> _publicChannelsForHandshakeSync(
    String networkKey,
  ) async {
    final channels = await _repository.listChannels(networkKey: networkKey);
    final visibleChannels = channels
        .where(chatChannelShouldSyncOnHandshake)
        .toList(growable: false);
    return visibleChannels
      ..sort((a, b) {
        final createdCompare = a.createdAt.compareTo(b.createdAt);
        if (createdCompare != 0) {
          return createdCompare;
        }
        return a.channelId.compareTo(b.channelId);
      });
  }

  Future<void> _syncKnownPublicChannelsToPeer({
    required String networkKey,
    required String peerId,
  }) async {
    final channels = await _publicChannelsForHandshakeSync(networkKey);
    if (channels.isEmpty) {
      return;
    }
    try {
      for (final channel in channels) {
        await _sendEnvelopeToPeer(
          networkKey: networkKey,
          peerId: peerId,
          type: ChatEnvelopeType.channelAnnounce,
          conversationId: ChatIds.channelConversationId(
            networkKey,
            channel.channelId,
          ),
          channelId: channel.channelId,
          payload: buildPublicChannelAnnouncementPayload(channel),
        );
      }
    } catch (error) {
      await _logger.warn(
        'channel.sync',
        '握手后补同步公开频道失败',
        networkKey: networkKey,
        extra: {
          'peerId': peerId,
          'channelCount': channels.length,
          'error': error.toString(),
        },
      );
      return;
    }
    await _logger.info(
      'channel.sync',
      '握手后补同步公开频道',
      networkKey: networkKey,
      extra: {
        'peerId': peerId,
        'channelCount': channels.length,
        'channelIds': channels
            .map((channel) => channel.channelId)
            .toList(growable: false),
      },
    );
  }

  Future<void> renameChannel(ChatChannel channel, String newName) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    final trimmed = newName.trim();
    if (localPeerId == null ||
        localPeerId != channel.ownerPeerId ||
        trimmed.isEmpty ||
        trimmed == channel.name) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertChannel(
      channel.copyWith(name: trimmed, updatedAt: now),
    );
    final conversationId = ChatIds.channelConversationId(
      channel.networkKey,
      channel.channelId,
    );
    final conversation = await _repository.getConversation(conversationId);
    if (conversation != null) {
      await _repository.upsertConversation(
        conversation.copyWith(
          title: trimmed,
          updatedAt: now,
        ),
      );
    }
    final members = await _repository.listChannelMembers(channel.channelId);
    await _broadcastToPeers(
      networkKey: channel.networkKey,
      peers: members.map((member) => member.peerId).toList(),
      type: ChatEnvelopeType.channelAnnounce,
      conversationId: conversationId,
      channelId: channel.channelId,
      payload: {
        'channelId': channel.channelId,
        'name': trimmed,
        'ownerPeerId': channel.ownerPeerId,
        'isPrivate': channel.isPrivate,
      },
    );
    await _reloadSidebar();
    await _logger.info(
      'channel',
      '频道改名',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
        'newName': trimmed,
      },
    );
  }

  Future<void> removeMemberFromChannel(
    ChatChannel channel,
    ChatPeer peer,
  ) async {
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null ||
        localPeerId != channel.ownerPeerId ||
        peer.peerId == channel.ownerPeerId) {
      return;
    }
    await _repository.removeChannelMember(channel.channelId, peer.peerId);
    await _sendEnvelopeToPeer(
      networkKey: channel.networkKey,
      peerId: peer.peerId,
      type: ChatEnvelopeType.channelLeave,
      channelId: channel.channelId,
      payload: {
        'channelId': channel.channelId,
        'peerId': peer.peerId,
      },
    );
    await _reloadSidebar();
    await _logger.warn(
      'channel',
      '移除频道成员',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channel.channelId,
        'peerId': peer.peerId,
      },
    );
  }

  Future<List<ChatPeer>> channelPeers(ChatChannel channel) async {
    final members = await _repository.listChannelMembers(channel.channelId);
    final peers = <ChatPeer>[];
    for (final member in members) {
      final peer = await _repository.getPeer(member.peerId);
      if (peer != null) {
        peers.add(peer);
      }
    }
    return peers;
  }

  Future<void> sendTextMessage(String rawText) async {
    final conversation = selectedConversation;
    final text = rawText.trim();
    if (conversation == null || text.isEmpty) {
      return;
    }
    if (text.length > textLimit) {
      _pushStatus('文字消息不能超过 $textLimit 字');
      return;
    }
    final localPeerId = _localPeerIdForNetwork(conversation.networkKey);
    if (localPeerId == null) {
      return;
    }
    final now = DateTime.now();
    final messageId = _uuid.v4();
    final message = ChatMessage(
      messageId: messageId,
      conversationId: conversation.conversationId,
      networkKey: conversation.networkKey,
      senderPeerId: localPeerId,
      kind: ChatMessageKind.text,
      direction: ChatMessageDirection.outgoing,
      status: ChatMessageStatus.pending,
      text: text,
      attachmentId: null,
      peerId: conversation.peerId,
      channelId: conversation.channelId,
      sentAt: now,
      receivedAt: now,
      createdAt: now,
    );
    await _repository.replaceMessage(message);
    await _repository.touchConversation(
      conversationId: conversation.conversationId,
      networkKey: conversation.networkKey,
      type: conversation.type,
      title: conversation.title,
      peerId: conversation.peerId,
      channelId: conversation.channelId,
      preview: text,
      messageTime: now,
      incrementUnread: false,
    );
    await selectConversation(conversation.conversationId);
    await _logger.info(
      'message.text',
      '发送文字消息',
      networkKey: conversation.networkKey,
      extra: {
        'conversationId': conversation.conversationId,
        'messageId': messageId,
        'length': text.length,
      },
    );
    try {
      if (conversation.type == ChatConversationType.direct &&
          conversation.peerId != null) {
        await _sendEnvelopeToPeer(
          networkKey: conversation.networkKey,
          peerId: conversation.peerId!,
          type: ChatEnvelopeType.dmMessage,
          conversationId: conversation.conversationId,
          payload: {
            'messageId': messageId,
            'kind': ChatMessageKind.text.name,
            'text': text,
          },
        );
      } else if (conversation.channelId != null) {
        final result = await _broadcastToPeers(
          networkKey: conversation.networkKey,
          peers: await _channelBroadcastPeerIds(conversation),
          type: ChatEnvelopeType.dmMessage,
          conversationId: conversation.conversationId,
          channelId: conversation.channelId,
          payload: {
            'messageId': messageId,
            'kind': ChatMessageKind.text.name,
            'text': text,
          },
        );
        if (result.allFailed) {
          throw StateError('频道文字消息广播失败，全部目标节点均未送达');
        }
        if (result.hasFailures) {
          await _logger.warn(
            'message.text',
            '频道文字消息部分节点发送失败',
            networkKey: conversation.networkKey,
            extra: {
              'conversationId': conversation.conversationId,
              'messageId': messageId,
              'attemptedCount': result.attemptedCount,
              'successCount': result.successCount,
              'failedIps': result.failedIps,
            },
          );
        }
      }
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.sent),
      );
      await selectConversation(conversation.conversationId);
      await _logger.info(
        'message.text',
        '文字消息发送完成',
        networkKey: conversation.networkKey,
        extra: {
          'conversationId': conversation.conversationId,
          'messageId': messageId,
        },
      );
    } catch (error, stackTrace) {
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.failed),
      );
      await selectConversation(conversation.conversationId);
      await _logger.error(
        'message.text',
        '文字消息发送失败',
        networkKey: conversation.networkKey,
        extra: {
          'conversationId': conversation.conversationId,
          'messageId': messageId,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      _pushStatus('聊天室消息发送失败，请查看联调诊断和 chat-debug.log');
    }
  }

  Future<List<String>> _channelBroadcastPeerIds(
    ChatConversationSummary conversation,
  ) async {
    if (isLobbyChannelId(conversation.channelId)) {
      return onlinePeersForNetwork(conversation.networkKey)
          .map((peer) => peer.peerId)
          .toList();
    }
    final members =
        await _repository.listChannelMembers(conversation.channelId!);
    return members.map((member) => member.peerId).toList();
  }

  Future<void> sendPickedImage() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (picked == null || picked.files.single.path == null) {
        return;
      }
      await sendAttachmentFile(
        picked.files.single.path!,
        ChatMessageKind.image,
      );
    } catch (error, stackTrace) {
      await _recordOutgoingAttachmentFailure(
        stage: 'pick',
        kind: ChatMessageKind.image,
        networkKey: selectedConversation?.networkKey,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> sendPickedFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(allowMultiple: false);
      if (picked == null || picked.files.single.path == null) {
        return;
      }
      await sendAttachmentFile(
        picked.files.single.path!,
        ChatMessageKind.file,
      );
    } catch (error, stackTrace) {
      await _recordOutgoingAttachmentFailure(
        stage: 'pick',
        kind: ChatMessageKind.file,
        networkKey: selectedConversation?.networkKey,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> sendAttachmentFile(
    String sourcePath,
    ChatMessageKind kind,
  ) async {
    final conversation = selectedConversation;
    if (conversation == null) {
      return;
    }
    _pendingOutgoingAttachmentCount++;
    notifyListeners();
    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        _pushStatus('待发送附件不存在或已被移动');
        return;
      }
      final stat = await file.stat();
      if (kind == ChatMessageKind.image && stat.size > imageLimitBytes) {
        _pushStatus('图片不能超过 20MB');
        return;
      }
      if (kind == ChatMessageKind.file && stat.size > fileLimitBytes) {
        _pushStatus('文件不能超过 200MB');
        return;
      }
      final imported = await _repository.importOutgoingFile(sourcePath);
      await _sendOutgoingAttachment(
        conversation: conversation,
        localPath: imported.path,
        fileName: path.basename(sourcePath),
        kind: kind,
      );
    } catch (error, stackTrace) {
      await _recordOutgoingAttachmentFailure(
        stage: 'prepare',
        kind: kind,
        networkKey: conversation.networkKey,
        sourcePath: sourcePath,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (_pendingOutgoingAttachmentCount > 0) {
        _pendingOutgoingAttachmentCount--;
      }
      notifyListeners();
    }
  }

  Future<void> _recordOutgoingAttachmentFailure({
    required String stage,
    required ChatMessageKind kind,
    required Object error,
    String? networkKey,
    String? sourcePath,
    StackTrace? stackTrace,
  }) async {
    await _logger.error(
      'attachment.$stage',
      '准备发送附件失败',
      networkKey: networkKey,
      extra: {
        'kind': kind.name,
        if (sourcePath != null) 'sourcePath': sourcePath,
        'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      },
    );
    _pushStatus('聊天室附件发送失败，请查看联调诊断和 chat-debug.log');
  }

  Future<void> _sendOutgoingAttachment({
    required ChatConversationSummary conversation,
    required String localPath,
    required String fileName,
    required ChatMessageKind kind,
  }) async {
    final localPeerId = _localPeerIdForNetwork(conversation.networkKey);
    if (localPeerId == null) {
      return;
    }
    final now = DateTime.now();
    final sha256 = await _repository.computeSha256(localPath);
    final attachmentId = _uuid.v4();
    final messageId = _uuid.v4();
    final mimeType = lookupMimeType(localPath) ??
        (kind == ChatMessageKind.image
            ? 'image/*'
            : kind == ChatMessageKind.voiceNote
                ? 'audio/ogg'
                : 'application/octet-stream');
    final size = await File(localPath).length();
    final attachment = ChatAttachment(
      attachmentId: attachmentId,
      messageId: messageId,
      direction: ChatMessageDirection.outgoing.name,
      type: kind.name,
      fileName: fileName,
      mimeType: mimeType,
      size: size,
      sha256: sha256,
      localPath: localPath,
      remotePath: '',
      offerStatus: ChatMessageStatus.awaitingAccept,
      transferStatus: ChatMessageStatus.pending,
      createdAt: now,
      expiresAt: now.add(_attachmentExpiry),
    );
    final message = ChatMessage(
      messageId: messageId,
      conversationId: conversation.conversationId,
      networkKey: conversation.networkKey,
      senderPeerId: localPeerId,
      kind: kind,
      direction: ChatMessageDirection.outgoing,
      status: ChatMessageStatus.awaitingAccept,
      text: kind == ChatMessageKind.voiceNote ? '[语音消息]' : '',
      attachmentId: attachmentId,
      peerId: conversation.peerId,
      channelId: conversation.channelId,
      metadata: {'fileName': fileName},
      sentAt: now,
      receivedAt: now,
      createdAt: now,
    );
    await _repository.upsertAttachment(attachment);
    await _repository.replaceMessage(message);
    await _repository.touchConversation(
      conversationId: conversation.conversationId,
      networkKey: conversation.networkKey,
      type: conversation.type,
      title: conversation.title,
      peerId: conversation.peerId,
      channelId: conversation.channelId,
      preview: _repository.buildPreview(
        kind,
        message.text,
        fileName: fileName,
      ),
      messageTime: now,
      incrementUnread: false,
    );
    await selectConversation(conversation.conversationId);
    await _logger.info(
      'attachment.offer',
      '发送附件 offer',
      networkKey: conversation.networkKey,
      extra: {
        'conversationId': conversation.conversationId,
        'messageId': messageId,
        'attachmentId': attachmentId,
        'kind': kind.name,
        'fileName': fileName,
        'size': size,
      },
    );
    final type = kind == ChatMessageKind.voiceNote
        ? ChatEnvelopeType.voiceNoteOffer
        : ChatEnvelopeType.attachmentOffer;
    final payload = {
      'messageId': messageId,
      'attachmentId': attachmentId,
      'kind': kind.name,
      'fileName': fileName,
      'mimeType': mimeType,
      'size': size,
      'sha256': sha256,
      'expiresAt': attachment.expiresAt!.millisecondsSinceEpoch,
    };
    ChatBroadcastResult? result;
    try {
      if (conversation.type == ChatConversationType.direct &&
          conversation.peerId != null) {
        await _sendEnvelopeToPeer(
          networkKey: conversation.networkKey,
          peerId: conversation.peerId!,
          type: type,
          conversationId: conversation.conversationId,
          payload: payload,
        );
      } else if (conversation.channelId != null) {
        result = await _broadcastToPeers(
          networkKey: conversation.networkKey,
          peers: await _channelBroadcastPeerIds(conversation),
          type: type,
          conversationId: conversation.conversationId,
          channelId: conversation.channelId,
          payload: payload,
        );
        if (result.allFailed) {
          throw StateError('频道附件消息广播失败，全部目标节点均未送达');
        }
        if (result.hasFailures) {
          await _logger.warn(
            'attachment.offer',
            '频道附件消息部分节点发送失败',
            networkKey: conversation.networkKey,
            extra: {
              'conversationId': conversation.conversationId,
              'messageId': messageId,
              'attachmentId': attachmentId,
              'attemptedCount': result.attemptedCount,
              'successCount': result.successCount,
              'failedIps': result.failedIps,
            },
          );
        }
      }
    } catch (error, stackTrace) {
      await _repository.upsertAttachment(
        attachment.copyWith(
          offerStatus: ChatMessageStatus.failed,
          transferStatus: ChatMessageStatus.failed,
        ),
      );
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.failed),
      );
      await selectConversation(conversation.conversationId);
      await _logger.error(
        'attachment.offer',
        '附件消息发送失败',
        networkKey: conversation.networkKey,
        extra: {
          'conversationId': conversation.conversationId,
          'messageId': messageId,
          'attachmentId': attachmentId,
          if (result != null) 'attemptedCount': result.attemptedCount,
          if (result != null) 'successCount': result.successCount,
          if (result != null) 'failedIps': result.failedIps,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      _pushStatus('聊天室附件发送失败，请查看联调诊断和 chat-debug.log');
    }
  }

  Future<void> acceptAttachment(String attachmentId) async {
    final attachment = await _repository.getAttachment(attachmentId);
    if (attachment == null) {
      return;
    }
    final message = await _repository.getMessage(attachment.messageId);
    if (message == null) {
      return;
    }
    final senderPeer = await _repository.getPeer(message.senderPeerId);
    if (senderPeer == null) {
      return;
    }
    await _repository.upsertAttachment(
      attachment.copyWith(
        offerStatus: ChatMessageStatus.accepted,
        transferStatus: ChatMessageStatus.accepted,
      ),
    );
    await _sendEnvelopeToPeer(
      networkKey: senderPeer.networkKey,
      peerId: senderPeer.peerId,
      type: ChatEnvelopeType.attachmentAccept,
      conversationId: message.conversationId,
      payload: {
        'messageId': message.messageId,
        'attachmentId': attachmentId,
      },
    );
    await selectConversation(message.conversationId);
    await _logger.info(
      'attachment.accept',
      '同意接收附件',
      networkKey: senderPeer.networkKey,
      extra: {
        'messageId': message.messageId,
        'attachmentId': attachmentId,
      },
    );
  }

  Future<void> rejectAttachment(String attachmentId) async {
    final attachment = await _repository.getAttachment(attachmentId);
    if (attachment == null) {
      return;
    }
    final message = await _repository.getMessage(attachment.messageId);
    if (message == null) {
      return;
    }
    final senderPeer = await _repository.getPeer(message.senderPeerId);
    await _repository.upsertAttachment(
      attachment.copyWith(
        offerStatus: ChatMessageStatus.rejected,
        transferStatus: ChatMessageStatus.rejected,
      ),
    );
    if (senderPeer != null) {
      await _sendEnvelopeToPeer(
        networkKey: senderPeer.networkKey,
        peerId: senderPeer.peerId,
        type: ChatEnvelopeType.attachmentReject,
        conversationId: message.conversationId,
        payload: {
          'messageId': message.messageId,
          'attachmentId': attachmentId,
        },
      );
    }
    await selectConversation(message.conversationId);
    await _logger.warn(
      'attachment.reject',
      '拒绝接收附件',
      networkKey: senderPeer?.networkKey,
      extra: {
        'messageId': message.messageId,
        'attachmentId': attachmentId,
      },
    );
  }

  Future<void> startVoiceNoteRecording() async {
    if (!await _ensureChatAudioAvailable('录制语音消息')) {
      return;
    }
    try {
      final tempPath = await _repository.ensureTemporaryVoiceFile(
        extension: _audio.preferredVoiceFileExtension,
      );
      _voiceRecordingStartedAt = DateTime.now();
      await _audio.startVoiceNoteRecording(tempPath);
      notifyListeners();
    } catch (error) {
      _pushStatus(_audio.userMessageForError(error, action: '开始录音'));
      await _logger.error('voice.note', '开始录音失败', extra: {
        'error': error.toString(),
      });
    }
  }

  Future<void> finishVoiceNoteRecording() async {
    final conversation = selectedConversation;
    if (conversation == null || !_audio.isVoiceRecording) {
      return;
    }
    final filePath = await _audio.stopVoiceNoteRecording();
    if (filePath == null || filePath.isEmpty) {
      return;
    }
    final startedAt = _voiceRecordingStartedAt ?? DateTime.now();
    _voiceRecordingStartedAt = null;
    final duration = DateTime.now().difference(startedAt);
    if (duration.inMilliseconds < 500) {
      await _repository.deleteFileIfExists(filePath);
      notifyListeners();
      return;
    }
    final imported = await _repository.importOutgoingFile(filePath);
    await _repository.deleteFileIfExists(filePath);
    await _sendOutgoingAttachment(
      conversation: conversation,
      localPath: imported.path,
      fileName: path.basename(imported.path),
      kind: ChatMessageKind.voiceNote,
    );
    notifyListeners();
    await _logger.info(
      'voice.note',
      '完成语音消息录制并发送 offer',
      networkKey: conversation.networkKey,
      extra: {
        'conversationId': conversation.conversationId,
        'durationMs': duration.inMilliseconds,
      },
    );
  }

  Future<void> cancelVoiceNoteRecording() async {
    if (!_audio.isVoiceRecording) {
      return;
    }
    _voiceRecordingStartedAt = null;
    await _audio.cancelVoiceNoteRecording();
    notifyListeners();
  }

  Future<void> playVoiceMessage(ChatMessage message) async {
    if (!await _ensureChatAudioAvailable('播放语音消息')) {
      return;
    }
    if (message.attachmentId == null) {
      return;
    }
    final attachment = await _repository.getAttachment(message.attachmentId!);
    if (attachment == null || attachment.localPath.isEmpty) {
      return;
    }
    try {
      await _audio.playVoiceFile(attachment.localPath);
      await _logger.info(
        'voice.note',
        '播放语音消息',
        networkKey: message.networkKey,
        extra: {
          'messageId': message.messageId,
          'attachmentId': attachment.attachmentId,
        },
      );
    } catch (error) {
      _pushStatus(_audio.userMessageForError(error, action: '播放语音消息'));
      await _logger.error(
        'voice.note',
        '播放语音消息失败',
        networkKey: message.networkKey,
        extra: {
          'messageId': message.messageId,
          'attachmentId': attachment.attachmentId,
          'error': error.toString(),
        },
      );
    }
  }

  Future<void> requestRemoteControl(ChatPeer peer) async {
    await _startRemoteAssist(peer, RemoteAssistMode.requestControl);
  }

  Future<void> inviteRemoteControl(ChatPeer peer) async {
    await _startRemoteAssist(peer, RemoteAssistMode.inviteControl);
  }

  String _generateRemoteAssistSessionToken({int length = 16}) {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var index = 0; index < length; index++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  Future<void> _cleanupRemoteAssistRuntime({
    int? listenPort,
    required String reason,
  }) async {
    try {
      if (debugCleanupRemoteAssistRuntime != null) {
        await debugCleanupRemoteAssistRuntime!(listenPort: listenPort);
      } else {
        await _remoteAssist.cleanupManagedSessionState(
          listenPort: listenPort ?? RemoteAssistService.listenPort,
        );
      }
      await _logRemoteAssistInfo(
        '已清理内置 RustDesk 会话态',
        extra: {
          'cleanupReason': reason,
          'listenPort': listenPort ?? RemoteAssistService.listenPort,
        },
      );
    } catch (error, stackTrace) {
      await _logger.warn(
        'remote_assist.cleanup',
        '清理内置 RustDesk 会话态失败',
        extra: {
          'cleanupReason': reason,
          'listenPort': listenPort ?? RemoteAssistService.listenPort,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  Future<void> _startRemoteAssist(
    ChatPeer peer,
    RemoteAssistMode mode,
  ) async {
    final unsupportedReason = await remoteAssistUnsupportedReason(peer);
    if (unsupportedReason != null) {
      _pushStatus(unsupportedReason);
      return;
    }
    final localPeerId = _localPeerIdForNetwork(peer.networkKey);
    final localVirtualIp = _services[peer.networkKey]?.localVirtualIp;
    if (localPeerId == null ||
        localVirtualIp == null ||
        localVirtualIp.isEmpty) {
      _pushStatus('当前网络尚未就绪，暂时无法发起远程协助');
      return;
    }
    await openDirectConversation(peer);
    final now = DateTime.now();
    final sessionId = _uuid.v4();
    final isRequestControl = mode == RemoteAssistMode.requestControl;
    final session = RemoteAssistSession(
      sessionId: sessionId,
      networkKey: peer.networkKey,
      peerId: peer.peerId,
      peerVirtualIp: peer.virtualIp,
      controllerPeerId: isRequestControl ? localPeerId : peer.peerId,
      controlledPeerId: isRequestControl ? peer.peerId : localPeerId,
      controllerVirtualIp: isRequestControl ? localVirtualIp : peer.virtualIp,
      controlledVirtualIp: isRequestControl ? peer.virtualIp : localVirtualIp,
      mode: mode,
      listenPort: RemoteAssistService.listenPort,
      sessionToken: _generateRemoteAssistSessionToken(),
      state: RemoteAssistState.pending,
      isIncoming: false,
      createdAt: now,
      updatedAt: now,
    );
    remoteAssistSession = session;
    _lastRemoteAssistHostError = null;
    _lastRemoteAssistConnectError = null;
    _lastRemoteAssistHostReadySucceeded = null;
    _lastRemoteAssistReadySentAt = null;
    _lastRemoteAssistReadyReceivedAt = null;
    _lastRemoteAssistFirewallBlockedReady = false;
    await _refreshRemoteAssistRuntimeDetails(listenPort: session.listenPort);
    notifyListeners();
    await _logRemoteAssistInfo(
      '发起远程协助邀请',
      session: session,
      extra: {
        'peerId': peer.peerId,
        'peerVirtualIp': peer.virtualIp,
        'conversationId': ChatIds.directConversationId(
          peer.networkKey,
          localPeerId,
          peer.peerId,
        ),
      },
    );
    await _sendEnvelopeToPeer(
      networkKey: peer.networkKey,
      peerId: peer.peerId,
      type: ChatEnvelopeType.remoteAssistInvite,
      conversationId: ChatIds.directConversationId(
        peer.networkKey,
        localPeerId,
        peer.peerId,
      ),
      payload: {
        'sessionId': session.sessionId,
        'mode': mode.name,
        'controllerPeerId': session.controllerPeerId,
        'controlledPeerId': session.controlledPeerId,
        'controllerVirtualIp': session.controllerVirtualIp,
        'controlledVirtualIp': session.controlledVirtualIp,
        'listenPort': session.listenPort,
        'sessionToken': session.sessionToken,
      },
    );
    _pushStatus(
      mode == RemoteAssistMode.requestControl
          ? '已向对方发送控制请求，等待同意'
          : '已邀请对方来控制当前设备，等待对方确认',
    );
  }

  Future<void> acceptRemoteAssist() async {
    final session = remoteAssistSession;
    if (session == null ||
        !session.isIncoming ||
        session.state != RemoteAssistState.pending ||
        !_processingRemoteAssistAcceptSessionIds.add(session.sessionId)) {
      return;
    }
    try {
      await _refreshRemoteAssistRuntimeDetails(listenPort: session.listenPort);
      await _logRemoteAssistInfo(
        '开始处理远程协助同意',
        session: session,
      );
      WindowsFirewallEnsureResult? firewallResult;
      if (session.isControlledLocal) {
        firewallResult = await _prepareControlledLocalRemoteAssistHost(session);
        remoteAssistSession = session.copyWith(
          state: RemoteAssistState.ready,
          updatedAt: DateTime.now(),
        );
      } else {
        remoteAssistSession = session.copyWith(
          state: RemoteAssistState.accepted,
          updatedAt: DateTime.now(),
        );
      }
      notifyListeners();
      await _sendEnvelopeToPeer(
        networkKey: session.networkKey,
        peerId: session.peerId,
        type: ChatEnvelopeType.remoteAssistAccept,
        conversationId: selectedConversationId,
        payload: {
          'sessionId': session.sessionId,
          'mode': session.mode.name,
          'listenPort': session.listenPort,
          'sessionToken': session.sessionToken,
        },
      );
      if (session.isControlledLocal) {
        await _sendEnvelopeToPeer(
          networkKey: session.networkKey,
          peerId: session.peerId,
          type: ChatEnvelopeType.remoteAssistReady,
          conversationId: selectedConversationId,
          payload: {
            'sessionId': session.sessionId,
            'listenPort': session.listenPort,
            'sessionToken': session.sessionToken,
          },
        );
        _lastRemoteAssistReadySentAt = DateTime.now();
        await _logRemoteAssistInfo(
          '已发送 remoteAssistReady',
          session: remoteAssistSession,
          extra: {
            'firewallFailureKind': firewallResult?.failureKind.name ??
                WindowsFirewallEnsureFailureKind.none.name,
          },
        );
        await _logRemoteAssistInfo(
          '受控端已就绪并发送 ready',
          session: remoteAssistSession,
        );
        _pushStatus(
          _remoteAssistControlledReadyStatusMessage(
            firewallResult ??
                const WindowsFirewallEnsureResult(
                  success: true,
                  promptedForElevation: false,
                  includeRemoteAssist: true,
                  targetedRules: const [],
                  allowedRules: const [],
                  missingRules: const [],
                ),
          ),
        );
      } else {
        _pushStatus('已同意远程协助，正在等待对方启动桌面服务');
      }
    } catch (error) {
      _lastRemoteAssistHostError = error.toString();
      _lastRemoteAssistHostReadySucceeded = false;
      remoteAssistSession = session.copyWith(
        state: RemoteAssistState.failed,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
      await _logger.error(
        'remote_assist.host',
        '远程协助 host 就绪失败',
        networkKey: session.networkKey,
        extra: {
          'sessionId': session.sessionId,
          'listenPort': session.listenPort,
          'error': error.toString(),
          if (_lastRemoteAssistBundledRuntimePath != null)
            'bundledRuntime': _lastRemoteAssistBundledRuntimePath,
          if (_lastRemoteAssistInstalledRuntimePath != null)
            'installedRuntime': _lastRemoteAssistInstalledRuntimePath,
        },
      );
      await _cleanupRemoteAssistRuntime(
        listenPort: session.listenPort,
        reason: 'accept_failed',
      );
      _pushStatus('启动远程协助失败: $error');
    } finally {
      _processingRemoteAssistAcceptSessionIds.remove(session.sessionId);
    }
  }

  Future<void> rejectRemoteAssist() async {
    final session = remoteAssistSession;
    if (session == null || !session.isIncoming) {
      return;
    }
    remoteAssistSession = session.copyWith(
      state: RemoteAssistState.rejected,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    await _sendEnvelopeToPeer(
      networkKey: session.networkKey,
      peerId: session.peerId,
      type: ChatEnvelopeType.remoteAssistReject,
      conversationId: selectedConversationId,
      payload: {'sessionId': session.sessionId},
    );
    await _cleanupRemoteAssistRuntime(
      listenPort: session.listenPort,
      reason: 'reject_local',
    );
  }

  Future<void> cancelRemoteAssist() async {
    final session = remoteAssistSession;
    if (session == null) {
      return;
    }
    remoteAssistSession = session.copyWith(
      state: RemoteAssistState.ended,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    await _sendEnvelopeToPeer(
      networkKey: session.networkKey,
      peerId: session.peerId,
      type: ChatEnvelopeType.remoteAssistCancel,
      conversationId: selectedConversationId,
      payload: {'sessionId': session.sessionId},
    );
    await _cleanupRemoteAssistRuntime(
      listenPort: session.listenPort,
      reason: 'cancel_local',
    );
  }

  Future<void> startPrivateCall(ChatPeer peer) async {
    if (callSession != null && callSession!.state != ChatCallState.ended) {
      return;
    }
    if (!await _ensureChatAudioAvailable(
      '发起一对一语音',
      networkKey: peer.networkKey,
      extra: {'peerId': peer.peerId},
    )) {
      return;
    }
    final conversationId = ChatIds.directConversationId(
      peer.networkKey,
      _localPeerIdForNetwork(peer.networkKey)!,
      peer.peerId,
    );
    await openDirectConversation(peer);
    final now = DateTime.now();
    final callId = _uuid.v4();
    callSession = ChatCallSession(
      callId: callId,
      networkKey: peer.networkKey,
      type: ChatCallType.direct,
      state: ChatCallState.dialing,
      peerId: peer.peerId,
      channelId: null,
      isIncoming: false,
      joinedVoice: true,
      participants: [peer.peerId],
      startedAt: now,
    );
    await _repository.upsertCallLog(
      ChatCallLog(
        callId: callId,
        conversationId: conversationId,
        networkKey: peer.networkKey,
        type: ChatCallType.direct,
        peerId: peer.peerId,
        channelId: null,
        state: ChatCallState.dialing,
        startedAt: now,
      ),
    );
    notifyListeners();
    try {
      await _sendEnvelopeToPeer(
        networkKey: peer.networkKey,
        peerId: peer.peerId,
        type: ChatEnvelopeType.callInvite,
        conversationId: conversationId,
        payload: {
          'callId': callId,
          'mode': ChatCallType.direct.name,
        },
      );
      await _logger.info(
        'voice.call',
        '发起一对一语音呼叫',
        networkKey: peer.networkKey,
        extra: {
          'callId': callId,
          'peerId': peer.peerId,
          'conversationId': conversationId,
        },
      );
    } catch (error) {
      _pushStatus('无法发起语音呼叫: $error');
      await _logger.error(
        'voice.call',
        '发起一对一语音呼叫失败',
        networkKey: peer.networkKey,
        extra: {
          'callId': callId,
          'peerId': peer.peerId,
          'error': error.toString(),
        },
      );
    }
  }

  Future<void> acceptIncomingCall() async {
    final session = callSession;
    if (session == null ||
        !session.isIncoming ||
        session.type != ChatCallType.direct) {
      return;
    }
    if (!await _ensureChatAudioAvailable(
      '接听一对一语音',
      networkKey: session.networkKey,
      extra: {
        'callId': session.callId,
        'peerId': session.peerId,
      },
    )) {
      return;
    }
    try {
      await _audio.startIncomingStreamPlayback();
      await _audio.startMicrophoneStream((bytes) {
        unawaited(_sendDirectCallAudio(bytes));
      });
      await _sendEnvelopeToPeer(
        networkKey: session.networkKey,
        peerId: session.peerId!,
        type: ChatEnvelopeType.callAccept,
        conversationId: selectedConversationId,
        payload: {'callId': session.callId},
      );
      callSession = session.copyWith(state: ChatCallState.active);
      notifyListeners();
      await _logger.info(
        'voice.call',
        '接听一对一语音呼叫',
        networkKey: session.networkKey,
        extra: {
          'callId': session.callId,
          'peerId': session.peerId,
        },
      );
    } catch (error) {
      await _stopAudioStreams();
      callSession = session.copyWith(state: ChatCallState.ended);
      notifyListeners();
      try {
        await _sendEnvelopeToPeer(
          networkKey: session.networkKey,
          peerId: session.peerId!,
          type: ChatEnvelopeType.callReject,
          conversationId: selectedConversationId,
          payload: {'callId': session.callId},
        );
      } catch (_) {}
      _pushStatus(_audio.userMessageForError(error, action: '接听语音'));
      await _logger.error(
        'voice.call',
        '接听一对一语音呼叫失败',
        networkKey: session.networkKey,
        extra: {
          'callId': session.callId,
          'peerId': session.peerId,
          'error': error.toString(),
        },
      );
    }
  }

  Future<void> rejectIncomingCall() async {
    final session = callSession;
    if (session == null ||
        !session.isIncoming ||
        session.type != ChatCallType.direct) {
      return;
    }
    await _sendEnvelopeToPeer(
      networkKey: session.networkKey,
      peerId: session.peerId!,
      type: ChatEnvelopeType.callReject,
      conversationId: selectedConversationId,
      payload: {'callId': session.callId},
    );
    callSession = session.copyWith(state: ChatCallState.ended);
    notifyListeners();
    await _logger.warn(
      'voice.call',
      '拒绝一对一语音呼叫',
      networkKey: session.networkKey,
      extra: {
        'callId': session.callId,
        'peerId': session.peerId,
      },
    );
  }

  Future<void> hangupCall() async {
    final session = callSession;
    if (session == null) {
      return;
    }
    if (session.type == ChatCallType.direct && session.peerId != null) {
      await _sendEnvelopeToPeer(
        networkKey: session.networkKey,
        peerId: session.peerId!,
        type: ChatEnvelopeType.callHangup,
        conversationId: selectedConversationId,
        payload: {'callId': session.callId},
      );
    }
    await _stopAudioStreams();
    callSession = session.copyWith(state: ChatCallState.ended);
    notifyListeners();
    await _logger.info(
      'voice.call',
      '挂断语音呼叫',
      networkKey: session.networkKey,
      extra: {
        'callId': session.callId,
        'peerId': session.peerId,
      },
    );
  }

  Future<void> joinChannelVoice(ChatChannel channel) async {
    if (!await _ensureChatAudioAvailable(
      '加入频道语音',
      networkKey: channel.networkKey,
      extra: {'channelId': channel.channelId},
    )) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == null) {
      return;
    }
    if (callSession != null &&
        callSession!.type == ChatCallType.direct &&
        callSession!.state == ChatCallState.active) {
      return;
    }
    final existing = callSession;
    final participants = <String>{
      localPeerId,
      if (existing?.channelId == channel.channelId) ...existing!.participants,
    }.toList()
      ..sort();
    final nextSession = ChatCallSession(
      callId: existing?.channelId == channel.channelId
          ? existing!.callId
          : _uuid.v4(),
      networkKey: channel.networkKey,
      type: ChatCallType.channel,
      state: ChatCallState.active,
      peerId: null,
      channelId: channel.channelId,
      isIncoming: false,
      joinedVoice: true,
      speakerPeerId: existing?.speakerPeerId,
      participants: participants,
      startedAt: existing?.startedAt ?? DateTime.now(),
    );
    try {
      await _audio.startIncomingStreamPlayback();
      callSession = nextSession;
      final members = await _repository.listChannelMembers(channel.channelId);
      await _broadcastToPeers(
        networkKey: channel.networkKey,
        peers: members.map((member) => member.peerId).toList(),
        type: ChatEnvelopeType.presence,
        channelId: channel.channelId,
        payload: {
          'kind': 'voice_join',
          'channelId': channel.channelId,
          'peerId': localPeerId,
          'callId': nextSession.callId,
        },
      );
      notifyListeners();
      await _logger.info(
        'voice.channel',
        '加入频道语音',
        networkKey: channel.networkKey,
        extra: {
          'channelId': channel.channelId,
          'participants': participants.length,
        },
      );
    } catch (error) {
      await _audio.stopIncomingStreamPlayback();
      callSession = existing;
      _pushStatus(_audio.userMessageForError(error, action: '加入频道语音'));
      await _logger.error(
        'voice.channel',
        '加入频道语音失败',
        networkKey: channel.networkKey,
        extra: {
          'channelId': channel.channelId,
          'error': error.toString(),
        },
      );
    }
  }

  Future<void> leaveChannelVoice() async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.channel ||
        session.channelId == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == null) {
      return;
    }
    await releasePtt();
    await _audio.stopIncomingStreamPlayback();
    final members = await _repository.listChannelMembers(session.channelId!);
    await _broadcastToPeers(
      networkKey: session.networkKey,
      peers: members.map((member) => member.peerId).toList(),
      type: ChatEnvelopeType.presence,
      channelId: session.channelId,
      payload: {
        'kind': 'voice_leave',
        'channelId': session.channelId,
        'peerId': localPeerId,
        'callId': session.callId,
      },
    );
    callSession = session.copyWith(
      joinedVoice: false,
      participants: session.participants
          .where((peerId) => peerId != localPeerId)
          .toList(),
      speakerPeerId:
          session.speakerPeerId == localPeerId ? '' : session.speakerPeerId,
    );
    notifyListeners();
    await _logger.info(
      'voice.channel',
      '离开频道语音',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
      },
    );
  }

  Future<void> requestPtt() async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.channel ||
        session.channelId == null ||
        !session.joinedVoice) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == null) {
      return;
    }
    final coordinator = _coordinatorPeerId(session);
    if (coordinator == null) {
      return;
    }
    if (coordinator == localPeerId) {
      await _grantPtt(session, localPeerId);
      return;
    }
    await _sendEnvelopeToPeer(
      networkKey: session.networkKey,
      peerId: coordinator,
      type: ChatEnvelopeType.pttRequest,
      channelId: session.channelId,
      payload: {
        'callId': session.callId,
        'peerId': localPeerId,
      },
    );
    await _logger.info(
      'voice.ptt',
      '请求发言权',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'coordinator': coordinator,
      },
    );
  }

  Future<void> releasePtt() async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.channel ||
        session.channelId == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == null || session.speakerPeerId != localPeerId) {
      return;
    }
    await _audio.stopMicrophoneStream();
    final coordinator = _coordinatorPeerId(session);
    if (coordinator == null) {
      return;
    }
    if (coordinator == localPeerId) {
      await _broadcastPttRelease(session, localPeerId);
      return;
    }
    await _sendEnvelopeToPeer(
      networkKey: session.networkKey,
      peerId: coordinator,
      type: ChatEnvelopeType.pttRelease,
      channelId: session.channelId,
      payload: {
        'callId': session.callId,
        'peerId': localPeerId,
      },
    );
    await _logger.info(
      'voice.ptt',
      '释放发言权',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
      },
    );
  }

  Future<void> _grantPtt(ChatCallSession session, String holderPeerId) async {
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == holderPeerId) {
      try {
        await _audio.startMicrophoneStream((bytes) {
          unawaited(_broadcastChannelAudio(bytes, session));
        });
      } catch (error) {
        await _logger.error(
          'voice.ptt',
          '授予本地发言权后启动麦克风失败',
          networkKey: session.networkKey,
          extra: {
            'channelId': session.channelId,
            'holderPeerId': holderPeerId,
            'error': error.toString(),
          },
        );
        _pushStatus(_audio.userMessageForError(error, action: '开启频道发言'));
        final coordinator = _coordinatorPeerId(session);
        if (coordinator == localPeerId) {
          await _broadcastPttRelease(session, holderPeerId);
        } else if (coordinator != null) {
          await _sendEnvelopeToPeer(
            networkKey: session.networkKey,
            peerId: coordinator,
            type: ChatEnvelopeType.pttRelease,
            channelId: session.channelId,
            payload: {
              'callId': session.callId,
              'holderPeerId': holderPeerId,
            },
          );
        }
        return;
      }
    }
    callSession = session.copyWith(speakerPeerId: holderPeerId);
    notifyListeners();
    final members = session.participants;
    await _broadcastToPeers(
      networkKey: session.networkKey,
      peers: members,
      type: ChatEnvelopeType.pttGrant,
      channelId: session.channelId,
      payload: {
        'callId': session.callId,
        'holderPeerId': holderPeerId,
      },
    );
    await _logger.info(
      'voice.ptt',
      '授予发言权',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'holderPeerId': holderPeerId,
      },
    );
  }

  Future<void> _broadcastPttRelease(
    ChatCallSession session,
    String holderPeerId,
  ) async {
    callSession = session.copyWith(speakerPeerId: '');
    notifyListeners();
    await _broadcastToPeers(
      networkKey: session.networkKey,
      peers: session.participants,
      type: ChatEnvelopeType.pttRelease,
      channelId: session.channelId,
      payload: {
        'callId': session.callId,
        'holderPeerId': holderPeerId,
      },
    );
    await _logger.info(
      'voice.ptt',
      '广播发言权释放',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'holderPeerId': holderPeerId,
      },
    );
  }

  String? _coordinatorPeerId(ChatCallSession session) {
    final participants = [...session.participants];
    if (participants.isEmpty) {
      return null;
    }
    participants.sort();
    return participants.first;
  }

  Future<void> _sendDirectCallAudio(Uint8List bytes) async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.direct ||
        session.peerId == null) {
      return;
    }
    final peer = await _repository.getPeer(session.peerId!);
    if (peer == null) {
      return;
    }
    await _services[session.networkKey]?.sendMediaPacket(
      remoteIp: peer.virtualIp,
      packet: {
        'callId': session.callId,
        'type': ChatCallType.direct.name,
        'channelId': null,
        'samples': base64Encode(bytes),
      },
    );
  }

  Future<void> _broadcastChannelAudio(
    Uint8List bytes,
    ChatCallSession session,
  ) async {
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == null || session.channelId == null) {
      return;
    }
    for (final peerId in session.participants) {
      if (peerId == localPeerId) {
        continue;
      }
      final peer = await _repository.getPeer(peerId);
      if (peer == null || !peer.isOnline) {
        continue;
      }
      await _services[session.networkKey]?.sendMediaPacket(
        remoteIp: peer.virtualIp,
        packet: {
          'callId': session.callId,
          'type': ChatCallType.channel.name,
          'channelId': session.channelId,
          'samples': base64Encode(bytes),
        },
      );
    }
  }

  Future<void> _stopAudioStreams() async {
    await _audio.stopMicrophoneStream();
    await _audio.stopIncomingStreamPlayback();
  }

  Future<void> _sendEnvelopeToPeer({
    required String networkKey,
    required String peerId,
    required ChatEnvelopeType type,
    String? conversationId,
    String? channelId,
    Map<String, dynamic> payload = const {},
  }) async {
    if (debugSendEnvelopeToPeer != null) {
      await debugSendEnvelopeToPeer!(
        networkKey: networkKey,
        peerId: peerId,
        type: type,
        conversationId: conversationId,
        channelId: channelId,
        payload: payload,
      );
      return;
    }
    final peer = await _repository.getPeer(peerId);
    if (peer == null || !chatPeerIsEffectivelyOnline(peer)) {
      throw StateError('目标设备不在线');
    }
    final service = _services[networkKey];
    if (service == null) {
      throw StateError('网络服务未启动');
    }
    await service.sendEnvelope(
      remoteIp: peer.virtualIp,
      envelope: ChatEnvelope(
        messageId: _uuid.v4(),
        type: type,
        fromVirtualIp: service.localVirtualIp,
        fromDeviceName: service.localDeviceName,
        toVirtualIp: peer.virtualIp,
        conversationId: conversationId,
        channelId: channelId,
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: payload,
      ),
    );
  }

  Future<ChatBroadcastResult> _broadcastToPeers({
    required String networkKey,
    required List<String> peers,
    required ChatEnvelopeType type,
    String? conversationId,
    String? channelId,
    Map<String, dynamic> payload = const {},
  }) async {
    final localPeerId = _localPeerIdForNetwork(networkKey);
    final service = _services[networkKey];
    if (service == null) {
      return const ChatBroadcastResult.empty();
    }
    final remoteIps = <String>[];
    for (final peerId in peers.toSet()) {
      if (peerId == localPeerId) {
        continue;
      }
      final peer = await _repository.getPeer(peerId);
      if (peer != null && chatPeerIsEffectivelyOnline(peer)) {
        remoteIps.add(peer.virtualIp);
      }
    }
    return service.broadcastEnvelope(
      remoteIps: remoteIps,
      envelope: ChatEnvelope(
        messageId: _uuid.v4(),
        type: type,
        fromVirtualIp: service.localVirtualIp,
        fromDeviceName: service.localDeviceName,
        conversationId: conversationId,
        channelId: channelId,
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> onEnvelopeReceived({
    required String networkKey,
    required String remoteIp,
    required ChatEnvelope envelope,
  }) async {
    final peerId = ChatIds.peerId(networkKey, envelope.fromVirtualIp);
    final now = DateTime.now();
    final existingPeer = await _repository.getPeer(peerId);
    await _repository.upsertPeer(
      ChatPeer(
        peerId: peerId,
        networkKey: networkKey,
        virtualIp: envelope.fromVirtualIp,
        deviceName: envelope.fromDeviceName.isNotEmpty
            ? envelope.fromDeviceName
            : (existingPeer?.deviceName ?? envelope.fromVirtualIp),
        remark: existingPeer?.remark ?? '',
        isOnline: true,
        lastSeenAt: now,
        capabilities: ((envelope.payload['capabilities'] as List?) ??
                existingPeer?.capabilities ??
                const [])
            .map((value) => value.toString())
            .toList(),
        createdAt: existingPeer?.createdAt ?? now,
        updatedAt: now,
      ),
    );
    await _logger.info(
      'envelope',
      '收到聊天消息',
      networkKey: networkKey,
      extra: {
        'type': envelope.type.name,
        'peerId': peerId,
        'remoteIp': remoteIp,
        'messageId': envelope.messageId,
      },
    );
    if (await _shouldIgnoreBlockedEnvelope(peerId, envelope.type)) {
      await _logger.warn(
        'envelope',
        '已忽略被拉黑设备的聊天消息',
        networkKey: networkKey,
        extra: {
          'type': envelope.type.name,
          'peerId': peerId,
          'messageId': envelope.messageId,
        },
      );
      await _reloadSidebar();
      return;
    }
    switch (envelope.type) {
      case ChatEnvelopeType.hello:
        final profileCapabilities = [
          'text',
          'image',
          'file',
          'voice_note',
          'voice_call',
          'channels',
          ...await _remoteAssist.localCapabilities(),
        ];
        await _sendEnvelopeToPeer(
          networkKey: networkKey,
          peerId: peerId,
          type: ChatEnvelopeType.profileSync,
          payload: {
            'capabilities': profileCapabilities,
          },
        );
        await _syncKnownPublicChannelsToPeer(
          networkKey: networkKey,
          peerId: peerId,
        );
        break;
      case ChatEnvelopeType.profileSync:
        break;
      case ChatEnvelopeType.friendRequest:
        await _repository.upsertFriend(
          ChatFriend(
            peerId: peerId,
            status: ChatFriendStatus.pending,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case ChatEnvelopeType.friendAccept:
        await _repository.upsertFriend(
          ChatFriend(
            peerId: peerId,
            status: ChatFriendStatus.friend,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case ChatEnvelopeType.friendReject:
      case ChatEnvelopeType.friendRemove:
        await _repository.upsertFriend(
          ChatFriend(
            peerId: peerId,
            status: ChatFriendStatus.stranger,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case ChatEnvelopeType.friendBlock:
        await _repository.upsertFriend(
          ChatFriend(
            peerId: peerId,
            status: ChatFriendStatus.blocked,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case ChatEnvelopeType.dmMessage:
        await _handleIncomingTextMessage(networkKey, peerId, envelope);
        break;
      case ChatEnvelopeType.channelAnnounce:
      case ChatEnvelopeType.channelInvite:
      case ChatEnvelopeType.channelCreate:
        await _handleIncomingChannel(networkKey, peerId, envelope);
        break;
      case ChatEnvelopeType.channelJoin:
        await _handleIncomingChannelJoin(envelope);
        break;
      case ChatEnvelopeType.channelLeave:
        await _handleIncomingChannelLeave(envelope);
        break;
      case ChatEnvelopeType.channelArchive:
        await _handleIncomingChannelArchive(envelope);
        break;
      case ChatEnvelopeType.attachmentOffer:
      case ChatEnvelopeType.voiceNoteOffer:
        await _handleIncomingAttachmentOffer(networkKey, peerId, envelope);
        break;
      case ChatEnvelopeType.attachmentAccept:
        await _handleAttachmentAccept(peerId, envelope);
        break;
      case ChatEnvelopeType.attachmentReject:
        await _handleAttachmentReject(envelope);
        break;
      case ChatEnvelopeType.callInvite:
        await _handleCallInvite(networkKey, peerId, envelope);
        break;
      case ChatEnvelopeType.callAccept:
        await _handleCallAccept(envelope);
        break;
      case ChatEnvelopeType.callReject:
        await _handleCallReject(envelope);
        break;
      case ChatEnvelopeType.callHangup:
        await _handleCallHangup(envelope);
        break;
      case ChatEnvelopeType.remoteAssistInvite:
        await _handleRemoteAssistInvite(networkKey, peerId, envelope);
        break;
      case ChatEnvelopeType.remoteAssistAccept:
        await _handleRemoteAssistAccept(envelope);
        break;
      case ChatEnvelopeType.remoteAssistReject:
        await _handleRemoteAssistReject(envelope);
        break;
      case ChatEnvelopeType.remoteAssistCancel:
      case ChatEnvelopeType.remoteAssistEnd:
        await _handleRemoteAssistEnd(envelope);
        break;
      case ChatEnvelopeType.remoteAssistReady:
        await _handleRemoteAssistReady(envelope);
        break;
      case ChatEnvelopeType.presence:
        await _handlePresence(peerId, envelope);
        break;
      case ChatEnvelopeType.pttRequest:
        await _handlePttRequest(peerId, envelope);
        break;
      case ChatEnvelopeType.pttGrant:
        await _handlePttGrant(envelope);
        break;
      case ChatEnvelopeType.pttRelease:
        await _handlePttRelease(envelope);
        break;
      case ChatEnvelopeType.ack:
        await _handleAck(envelope);
        break;
    }
    await _reloadSidebar();
  }

  Future<bool> _shouldIgnoreBlockedEnvelope(
    String peerId,
    ChatEnvelopeType type,
  ) async {
    final friend = await _repository.getFriend(peerId);
    if (friend?.status != ChatFriendStatus.blocked) {
      return false;
    }
    return switch (type) {
      ChatEnvelopeType.friendRequest => true,
      ChatEnvelopeType.dmMessage => true,
      ChatEnvelopeType.attachmentOffer => true,
      ChatEnvelopeType.voiceNoteOffer => true,
      ChatEnvelopeType.callInvite => true,
      ChatEnvelopeType.remoteAssistInvite => true,
      _ => false,
    };
  }

  Future<void> _handleIncomingTextMessage(
    String networkKey,
    String senderPeerId,
    ChatEnvelope envelope,
  ) async {
    final kind = ChatMessageKind.values.byName(
      (envelope.payload['kind'] as String?) ?? ChatMessageKind.text.name,
    );
    final sender = await _repository.getPeer(senderPeerId);
    final conversationId = envelope.conversationId ??
        ChatIds.directConversationId(
          networkKey,
          _localPeerIdForNetwork(networkKey)!,
          senderPeerId,
        );
    final existing = await _repository.getMessage(
      (envelope.payload['messageId'] as String?) ?? envelope.messageId,
    );
    if (existing != null) {
      return;
    }
    await _repository.replaceMessage(
      ChatMessage(
        messageId:
            (envelope.payload['messageId'] as String?) ?? envelope.messageId,
        conversationId: conversationId,
        networkKey: networkKey,
        senderPeerId: senderPeerId,
        kind: kind,
        direction: ChatMessageDirection.incoming,
        status: ChatMessageStatus.delivered,
        text: (envelope.payload['text'] as String?) ?? '',
        attachmentId: null,
        peerId: envelope.channelId == null ? senderPeerId : null,
        channelId: envelope.channelId,
        metadata: const {},
        sentAt: DateTime.fromMillisecondsSinceEpoch(envelope.sentAt),
        receivedAt: DateTime.now(),
        createdAt: DateTime.now(),
      ),
    );
    await _repository.touchConversation(
      conversationId: conversationId,
      networkKey: networkKey,
      type: envelope.channelId == null
          ? ChatConversationType.direct
          : ChatConversationType.channel,
      title: envelope.channelId == null
          ? (sender?.displayName ?? envelope.fromDeviceName)
          : ((await _repository.getChannel(envelope.channelId!))?.name ?? '频道'),
      peerId: envelope.channelId == null ? senderPeerId : null,
      channelId: envelope.channelId,
      preview: (envelope.payload['text'] as String?) ?? '',
      messageTime: DateTime.now(),
      incrementUnread: selectedConversationId != conversationId,
    );
    await _sendEnvelopeToPeer(
      networkKey: networkKey,
      peerId: senderPeerId,
      type: ChatEnvelopeType.ack,
      conversationId: conversationId,
      payload: {
        'targetMessageId': envelope.payload['messageId'] ?? envelope.messageId
      },
    );
    await _logger.info(
      'message.text',
      '收到文字消息',
      networkKey: networkKey,
      extra: {
        'conversationId': conversationId,
        'messageId': envelope.payload['messageId'] ?? envelope.messageId,
        'senderPeerId': senderPeerId,
        'kind': kind.name,
      },
    );
  }

  Future<void> _handleIncomingChannel(
    String networkKey,
    String senderPeerId,
    ChatEnvelope envelope,
  ) async {
    final channelId =
        (envelope.payload['channelId'] as String?) ?? envelope.channelId;
    if (channelId == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(networkKey);
    final now = DateTime.now();
    final isPrivate = (envelope.payload['isPrivate'] as bool?) ?? false;
    final joined = envelope.type == ChatEnvelopeType.channelInvite;
    final existing = await _repository.getChannel(channelId);
    await _repository.upsertChannel(
      existing?.copyWith(
            name: (envelope.payload['name'] as String?) ?? existing.name,
            joined: joined ? true : existing.joined,
            updatedAt: now,
          ) ??
          ChatChannel(
            channelId: channelId,
            networkKey: networkKey,
            name: (envelope.payload['name'] as String?) ?? '频道',
            ownerPeerId:
                (envelope.payload['ownerPeerId'] as String?) ?? senderPeerId,
            isPrivate: isPrivate,
            joined: joined,
            archived: false,
            createdAt: now,
            updatedAt: now,
          ),
    );
    await _repository.upsertConversation(
      ChatConversationSummary(
        conversationId: ChatIds.channelConversationId(networkKey, channelId),
        networkKey: networkKey,
        type: ChatConversationType.channel,
        title: (envelope.payload['name'] as String?) ?? '频道',
        peerId: null,
        channelId: channelId,
        unreadCount: 0,
        lastPreview: '',
        lastMessageAt: null,
        archived: false,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _repository.upsertChannelMember(
      ChatChannelMember(
        channelId: channelId,
        peerId: senderPeerId,
        role: senderPeerId ==
                ((envelope.payload['ownerPeerId'] as String?) ?? senderPeerId)
            ? 'owner'
            : 'member',
        joinedAt: now,
        updatedAt: now,
      ),
    );
    if (joined && localPeerId != null) {
      await _repository.upsertChannelMember(
        ChatChannelMember(
          channelId: channelId,
          peerId: localPeerId,
          role: 'member',
          joinedAt: now,
          updatedAt: now,
        ),
      );
    }
    await _logger.info(
      'channel',
      '收到频道元数据',
      networkKey: networkKey,
      extra: {
        'channelId': channelId,
        'name': envelope.payload['name'],
        'joined': joined,
        'type': envelope.type.name,
      },
    );
  }

  Future<void> _handleIncomingChannelJoin(ChatEnvelope envelope) async {
    final channelId = envelope.payload['channelId'] as String?;
    final peerId = envelope.payload['peerId'] as String?;
    if (channelId == null || peerId == null) {
      return;
    }
    await _repository.upsertChannelMember(
      ChatChannelMember(
        channelId: channelId,
        peerId: peerId,
        role: 'member',
        joinedAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await _logger.info(
      'channel',
      '收到频道加入通知',
      extra: {
        'channelId': channelId,
        'peerId': peerId,
      },
    );
  }

  Future<void> _handleIncomingChannelLeave(ChatEnvelope envelope) async {
    final channelId = envelope.payload['channelId'] as String?;
    final peerId = envelope.payload['peerId'] as String?;
    if (channelId == null || peerId == null) {
      return;
    }
    await _repository.removeChannelMember(channelId, peerId);
    final channel = await _repository.getChannel(channelId);
    if (channel == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(channel.networkKey);
    if (localPeerId == peerId) {
      if (callSession?.type == ChatCallType.channel &&
          callSession?.channelId == channelId) {
        await leaveChannelVoice();
      }
      await _repository.upsertChannel(
        channel.copyWith(
          joined: false,
          updatedAt: DateTime.now(),
        ),
      );
    }
    await _logger.warn(
      'channel',
      '收到频道离开通知',
      extra: {
        'channelId': channelId,
        'peerId': peerId,
      },
    );
  }

  Future<void> _handleIncomingChannelArchive(ChatEnvelope envelope) async {
    final channelId = envelope.payload['channelId'] as String?;
    if (channelId == null) {
      return;
    }
    final channel = await _repository.getChannel(channelId);
    if (channel == null) {
      return;
    }
    await _repository.upsertChannel(
      channel.copyWith(archived: true, updatedAt: DateTime.now()),
    );
    await _logger.warn(
      'channel',
      '收到频道归档通知',
      networkKey: channel.networkKey,
      extra: {
        'channelId': channelId,
      },
    );
  }

  Future<void> _handleIncomingAttachmentOffer(
    String networkKey,
    String senderPeerId,
    ChatEnvelope envelope,
  ) async {
    final attachmentId = envelope.payload['attachmentId'] as String?;
    final messageId = envelope.payload['messageId'] as String?;
    if (attachmentId == null || messageId == null) {
      return;
    }
    final kind = ChatMessageKind.values.byName(
      (envelope.payload['kind'] as String?) ?? ChatMessageKind.file.name,
    );
    final sender = await _repository.getPeer(senderPeerId);
    final conversationId = envelope.conversationId ??
        ChatIds.directConversationId(
          networkKey,
          _localPeerIdForNetwork(networkKey)!,
          senderPeerId,
        );
    final existing = await _repository.getMessage(messageId);
    if (existing != null) {
      return;
    }
    final now = DateTime.now();
    await _repository.upsertAttachment(
      ChatAttachment(
        attachmentId: attachmentId,
        messageId: messageId,
        direction: ChatMessageDirection.incoming.name,
        type: kind.name,
        fileName: (envelope.payload['fileName'] as String?) ?? '',
        mimeType: (envelope.payload['mimeType'] as String?) ??
            'application/octet-stream',
        size: (envelope.payload['size'] as num?)?.toInt() ?? 0,
        sha256: (envelope.payload['sha256'] as String?) ?? '',
        localPath: '',
        remotePath: sender?.virtualIp ?? envelope.fromVirtualIp,
        offerStatus: ChatMessageStatus.awaitingAccept,
        transferStatus: ChatMessageStatus.pending,
        createdAt: now,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (envelope.payload['expiresAt'] as num?)?.toInt() ??
              now.add(_attachmentExpiry).millisecondsSinceEpoch,
        ),
      ),
    );
    await _repository.replaceMessage(
      ChatMessage(
        messageId: messageId,
        conversationId: conversationId,
        networkKey: networkKey,
        senderPeerId: senderPeerId,
        kind: kind,
        direction: ChatMessageDirection.incoming,
        status: ChatMessageStatus.awaitingAccept,
        text: kind == ChatMessageKind.voiceNote ? '[语音消息]' : '',
        attachmentId: attachmentId,
        peerId: envelope.channelId == null ? senderPeerId : null,
        channelId: envelope.channelId,
        metadata: {'fileName': envelope.payload['fileName']},
        sentAt: DateTime.fromMillisecondsSinceEpoch(envelope.sentAt),
        receivedAt: now,
        createdAt: now,
      ),
    );
    await _repository.touchConversation(
      conversationId: conversationId,
      networkKey: networkKey,
      type: envelope.channelId == null
          ? ChatConversationType.direct
          : ChatConversationType.channel,
      title: envelope.channelId == null
          ? (sender?.displayName ?? envelope.fromDeviceName)
          : ((await _repository.getChannel(envelope.channelId!))?.name ?? '频道'),
      peerId: envelope.channelId == null ? senderPeerId : null,
      channelId: envelope.channelId,
      preview: _repository.buildPreview(
        kind,
        '',
        fileName: envelope.payload['fileName'] as String?,
      ),
      messageTime: now,
      incrementUnread: selectedConversationId != conversationId,
    );
    await _logger.info(
      'attachment.offer',
      '收到附件 offer',
      networkKey: networkKey,
      extra: {
        'conversationId': conversationId,
        'messageId': messageId,
        'attachmentId': attachmentId,
        'kind': kind.name,
        'fileName': envelope.payload['fileName'],
        'size': envelope.payload['size'],
      },
    );
  }

  Future<void> _handleAttachmentAccept(
    String requestingPeerId,
    ChatEnvelope envelope,
  ) async {
    final attachmentId = envelope.payload['attachmentId'] as String?;
    final messageId = envelope.payload['messageId'] as String?;
    if (attachmentId == null || messageId == null) {
      return;
    }
    final attachment = await _repository.getAttachment(attachmentId);
    final message = await _repository.getMessage(messageId);
    final peer = await _repository.getPeer(requestingPeerId);
    if (attachment == null || message == null || peer == null) {
      return;
    }
    await _repository.upsertAttachment(
      attachment.copyWith(
        offerStatus: ChatMessageStatus.accepted,
        transferStatus: ChatMessageStatus.accepted,
      ),
    );
    final header = {
      'attachmentId': attachmentId,
      'messageId': messageId,
      'conversationId': message.conversationId,
      'networkKey': message.networkKey,
      'kind': message.kind.name,
      'fileName': attachment.fileName,
      'mimeType': attachment.mimeType,
      'size': attachment.size,
      'sha256': attachment.sha256,
      'senderPeerId': message.senderPeerId,
      'channelId': message.channelId,
      'peerId': message.peerId,
    };
    final service = _services[message.networkKey];
    if (service == null) {
      return;
    }
    try {
      await service.sendAttachment(
        remoteIp: peer.virtualIp,
        header: header,
        filePath: attachment.localPath,
      );
      await _repository.upsertAttachment(
        attachment.copyWith(transferStatus: ChatMessageStatus.transferred),
      );
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.transferred),
      );
      await _logger.info(
        'attachment.transfer',
        '附件传输完成',
        networkKey: message.networkKey,
        extra: {
          'messageId': messageId,
          'attachmentId': attachmentId,
          'remotePeerId': requestingPeerId,
        },
      );
    } catch (error, stackTrace) {
      await _repository.upsertAttachment(
        attachment.copyWith(transferStatus: ChatMessageStatus.failed),
      );
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.failed),
      );
      await _logger.error(
        'attachment.transfer',
        '附件传输失败',
        networkKey: message.networkKey,
        extra: {
          'messageId': messageId,
          'attachmentId': attachmentId,
          'remotePeerId': requestingPeerId,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
    await _reloadSidebar();
  }

  Future<void> _handleAttachmentReject(ChatEnvelope envelope) async {
    final attachmentId = envelope.payload['attachmentId'] as String?;
    final messageId = envelope.payload['messageId'] as String?;
    if (attachmentId == null || messageId == null) {
      return;
    }
    final attachment = await _repository.getAttachment(attachmentId);
    final message = await _repository.getMessage(messageId);
    if (attachment != null) {
      await _repository.upsertAttachment(
        attachment.copyWith(
          offerStatus: ChatMessageStatus.rejected,
          transferStatus: ChatMessageStatus.rejected,
        ),
      );
    }
    if (message != null) {
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.rejected),
      );
    }
    await _logger.warn(
      'attachment.reject',
      '对方拒绝接收附件',
      extra: {
        'messageId': messageId,
        'attachmentId': attachmentId,
      },
    );
  }

  Future<void> _handleCallInvite(
    String networkKey,
    String senderPeerId,
    ChatEnvelope envelope,
  ) async {
    final callId = envelope.payload['callId'] as String?;
    if (callId == null) {
      return;
    }
    callSession = ChatCallSession(
      callId: callId,
      networkKey: networkKey,
      type: ChatCallType.direct,
      state: ChatCallState.ringing,
      peerId: senderPeerId,
      channelId: null,
      isIncoming: true,
      joinedVoice: true,
      participants: [senderPeerId],
      startedAt: DateTime.now(),
    );
    notifyListeners();
    await _logger.info(
      'voice.call',
      '收到一对一语音呼叫',
      networkKey: networkKey,
      extra: {
        'callId': callId,
        'peerId': senderPeerId,
      },
    );
  }

  Future<void> _handleCallAccept(ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null || session.type != ChatCallType.direct) {
      return;
    }
    try {
      await _audio.startIncomingStreamPlayback();
      await _audio.startMicrophoneStream((bytes) {
        unawaited(_sendDirectCallAudio(bytes));
      });
      callSession = session.copyWith(state: ChatCallState.active);
      notifyListeners();
      await _logger.info(
        'voice.call',
        '对方已接听语音呼叫',
        networkKey: session.networkKey,
        extra: {
          'callId': session.callId,
          'peerId': session.peerId,
        },
      );
    } catch (error) {
      await _stopAudioStreams();
      callSession = session.copyWith(state: ChatCallState.ended);
      notifyListeners();
      try {
        await _sendEnvelopeToPeer(
          networkKey: session.networkKey,
          peerId: session.peerId!,
          type: ChatEnvelopeType.callHangup,
          conversationId: selectedConversationId,
          payload: {'callId': session.callId},
        );
      } catch (_) {}
      _pushStatus(_audio.userMessageForError(error, action: '启动语音通话音频'));
      await _logger.error(
        'voice.call',
        '对方接听后本地音频启动失败',
        networkKey: session.networkKey,
        extra: {
          'callId': session.callId,
          'peerId': session.peerId,
          'error': error.toString(),
        },
      );
    }
  }

  Future<void> _handleCallReject(ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null) {
      return;
    }
    callSession = session.copyWith(state: ChatCallState.ended);
    await _stopAudioStreams();
    notifyListeners();
    await _logger.warn(
      'voice.call',
      '对方拒绝语音呼叫',
      networkKey: session.networkKey,
      extra: {
        'callId': session.callId,
        'peerId': session.peerId,
      },
    );
  }

  Future<void> _handleCallHangup(ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null) {
      return;
    }
    await _stopAudioStreams();
    callSession = session.copyWith(state: ChatCallState.ended);
    notifyListeners();
    await _logger.info(
      'voice.call',
      '收到挂断通知',
      networkKey: session.networkKey,
      extra: {
        'callId': session.callId,
        'peerId': session.peerId,
      },
    );
  }

  Future<void> _handleRemoteAssistInvite(
    String networkKey,
    String senderPeerId,
    ChatEnvelope envelope,
  ) async {
    final peer = await _repository.getPeer(senderPeerId);
    if (peer == null) {
      return;
    }
    await openDirectConversation(peer);
    final now = DateTime.now();
    _lastRemoteAssistHostError = null;
    _lastRemoteAssistConnectError = null;
    _lastRemoteAssistHostReadySucceeded = null;
    _lastRemoteAssistReadySentAt = null;
    _lastRemoteAssistReadyReceivedAt = null;
    _lastRemoteAssistFirewallBlockedReady = false;
    remoteAssistSession = RemoteAssistSession(
      sessionId:
          (envelope.payload['sessionId'] as String?) ?? envelope.messageId,
      networkKey: networkKey,
      peerId: senderPeerId,
      peerVirtualIp: peer.virtualIp,
      controllerPeerId:
          (envelope.payload['controllerPeerId'] as String?) ?? senderPeerId,
      controlledPeerId:
          (envelope.payload['controlledPeerId'] as String?) ?? senderPeerId,
      controllerVirtualIp:
          (envelope.payload['controllerVirtualIp'] as String?) ?? '',
      controlledVirtualIp:
          (envelope.payload['controlledVirtualIp'] as String?) ?? '',
      mode: RemoteAssistMode.values.byName(
        (envelope.payload['mode'] as String?) ??
            RemoteAssistMode.requestControl.name,
      ),
      listenPort: (envelope.payload['listenPort'] as num?)?.toInt() ??
          RemoteAssistService.listenPort,
      sessionToken: (envelope.payload['sessionToken'] as String?) ?? '',
      state: RemoteAssistState.pending,
      isIncoming: true,
      createdAt: now,
      updatedAt: now,
    );
    await _refreshRemoteAssistRuntimeDetails(
      listenPort: (envelope.payload['listenPort'] as num?)?.toInt() ??
          RemoteAssistService.listenPort,
    );
    notifyListeners();
    await _logRemoteAssistInfo(
      '收到远程协助邀请',
      session: remoteAssistSession,
      extra: {
        'peerId': senderPeerId,
        'peerVirtualIp': peer.virtualIp,
      },
    );
    _pushStatus(
      remoteAssistSession?.mode == RemoteAssistMode.requestControl
          ? '${peer.displayName} 请求控制当前设备'
          : '${peer.displayName} 邀请你去控制其设备',
    );
  }

  Future<void> _handleRemoteAssistAccept(ChatEnvelope envelope) async {
    final session = remoteAssistSession;
    if (session == null) {
      return;
    }
    try {
      await _logRemoteAssistInfo(
        '收到远程协助 accept',
        session: session,
      );
      final envelopeSessionId = envelope.payload['sessionId'] as String?;
      if (envelopeSessionId != null && envelopeSessionId != session.sessionId) {
        return;
      }
      if (session.state != RemoteAssistState.pending ||
          !_processingRemoteAssistAcceptSessionIds.add(session.sessionId)) {
        return;
      }
      await _refreshRemoteAssistRuntimeDetails(listenPort: session.listenPort);
      WindowsFirewallEnsureResult? firewallResult;
      if (session.isControlledLocal) {
        firewallResult = await _prepareControlledLocalRemoteAssistHost(session);
        remoteAssistSession = session.copyWith(
          state: RemoteAssistState.ready,
          updatedAt: DateTime.now(),
        );
        notifyListeners();
        await _sendEnvelopeToPeer(
          networkKey: session.networkKey,
          peerId: session.peerId,
          type: ChatEnvelopeType.remoteAssistReady,
          conversationId: selectedConversationId,
          payload: {
            'sessionId': session.sessionId,
            'listenPort': session.listenPort,
            'sessionToken': session.sessionToken,
          },
        );
        _lastRemoteAssistReadySentAt = DateTime.now();
        await _logRemoteAssistInfo(
          '已发送 remoteAssistReady',
          session: remoteAssistSession,
          extra: {
            'firewallFailureKind': firewallResult?.failureKind.name ??
                WindowsFirewallEnsureFailureKind.none.name,
          },
        );
        await _logRemoteAssistInfo(
          '发起方受控端已就绪并发送 ready',
          session: remoteAssistSession,
        );
        _pushStatus(
          _remoteAssistControlledReadyStatusMessage(
            firewallResult ??
                const WindowsFirewallEnsureResult(
                  success: true,
                  promptedForElevation: false,
                  includeRemoteAssist: true,
                  targetedRules: const [],
                  allowedRules: const [],
                  missingRules: const [],
                ),
          ),
        );
        return;
      }
      remoteAssistSession = session.copyWith(
        state: RemoteAssistState.accepted,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
      await _logRemoteAssistInfo(
        '收到远程协助 accept，等待对方 ready',
        session: remoteAssistSession,
      );
      _pushStatus('已同意远程协助，正在等待对方启动桌面服务');
    } catch (error) {
      _lastRemoteAssistHostError = error.toString();
      _lastRemoteAssistHostReadySucceeded = false;
      remoteAssistSession = session.copyWith(
        state: RemoteAssistState.failed,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
      await _logger.error(
        'remote_assist.host',
        '远程协助发起方 host 就绪失败',
        networkKey: session.networkKey,
        extra: {
          'sessionId': session.sessionId,
          'listenPort': session.listenPort,
          'error': error.toString(),
          if (_lastRemoteAssistBundledRuntimePath != null)
            'bundledRuntime': _lastRemoteAssistBundledRuntimePath,
          if (_lastRemoteAssistInstalledRuntimePath != null)
            'installedRuntime': _lastRemoteAssistInstalledRuntimePath,
        },
      );
      await _cleanupRemoteAssistRuntime(
        listenPort: session.listenPort,
        reason: 'handle_accept_failed',
      );
      _pushStatus('启动远程协助失败: $error');
    } finally {
      _processingRemoteAssistAcceptSessionIds.remove(session.sessionId);
    }
  }

  Future<void> _handleRemoteAssistReady(ChatEnvelope envelope) async {
    final session = remoteAssistSession;
    if (session == null) {
      return;
    }
    try {
      final envelopeSessionId = envelope.payload['sessionId'] as String?;
      if (envelopeSessionId != null && envelopeSessionId != session.sessionId) {
        return;
      }
      _lastRemoteAssistReadyReceivedAt = DateTime.now();
      await _logRemoteAssistInfo(
        '已收到 remoteAssistReady',
        session: session,
      );
      if (session.isControllerLocal) {
        if (session.state == RemoteAssistState.active) {
          await _logRemoteAssistInfo(
            '重复收到 remoteAssistReady，当前控制端已处于 active',
            session: session,
          );
          return;
        }
        await _refreshRemoteAssistRuntimeDetails(
            listenPort: session.listenPort);
        await _logRemoteAssistInfo(
          '控制端准备连接远程桌面',
          session: session,
          extra: {
            'targetAddress':
                '${session.controlledVirtualIp}:${session.listenPort}',
          },
        );
        if (debugLaunchRemoteAssistController != null) {
          await debugLaunchRemoteAssistController!(
            session.controlledVirtualIp,
            session.sessionToken,
          );
        } else {
          await _remoteAssist.launchController(
            session.controlledVirtualIp,
            sessionToken: session.sessionToken,
          );
        }
        _lastRemoteAssistConnectError = null;
        remoteAssistSession = session.copyWith(
          state: RemoteAssistState.active,
          updatedAt: DateTime.now(),
        );
        await _logRemoteAssistInfo(
          '控制端已拉起远程桌面',
          session: remoteAssistSession,
          extra: {
            'targetAddress':
                '${session.controlledVirtualIp}:${session.listenPort}',
          },
        );
      } else {
        remoteAssistSession = session.copyWith(
          state: RemoteAssistState.ready,
          updatedAt: DateTime.now(),
        );
        await _logRemoteAssistInfo(
          '已收到 remoteAssistReady，等待控制端接入',
          session: remoteAssistSession,
        );
      }
      notifyListeners();
      _pushStatus('远程协助会话已启动，请在 RustDesk 窗口中继续操作');
    } catch (error) {
      _lastRemoteAssistConnectError = error.toString();
      remoteAssistSession = session.copyWith(
        state: RemoteAssistState.failed,
        updatedAt: DateTime.now(),
      );
      notifyListeners();
      await _logger.error(
        'remote_assist.controller',
        '拉起远程桌面控制端失败',
        networkKey: session.networkKey,
        extra: {
          'sessionId': session.sessionId,
          'listenPort': session.listenPort,
          'targetAddress':
              '${session.controlledVirtualIp}:${session.listenPort}',
          'error': error.toString(),
          if (_lastRemoteAssistBundledRuntimePath != null)
            'bundledRuntime': _lastRemoteAssistBundledRuntimePath,
        },
      );
      await _cleanupRemoteAssistRuntime(
        listenPort: session.listenPort,
        reason: 'controller_launch_failed',
      );
      _pushStatus('拉起远程协助失败: $error');
    }
  }

  @visibleForTesting
  Future<void> debugHandleRemoteAssistAcceptForTest({
    required String sessionId,
  }) async {
    await _handleRemoteAssistAccept(
      ChatEnvelope(
        messageId: 'debug-remote-assist-accept-$sessionId',
        type: ChatEnvelopeType.remoteAssistAccept,
        fromVirtualIp: '10.0.0.2',
        fromDeviceName: 'debug-peer',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'sessionId': sessionId,
        },
      ),
    );
  }

  @visibleForTesting
  Future<void> debugHandleRemoteAssistReadyForTest({
    required String sessionId,
  }) async {
    await _handleRemoteAssistReady(
      ChatEnvelope(
        messageId: 'debug-remote-assist-ready-$sessionId',
        type: ChatEnvelopeType.remoteAssistReady,
        fromVirtualIp: '10.0.0.2',
        fromDeviceName: 'debug-peer',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: {
          'sessionId': sessionId,
        },
      ),
    );
  }

  @visibleForTesting
  Future<void> debugHandleRemoteAssistRejectForTest() async {
    await _handleRemoteAssistReject(
      ChatEnvelope(
        messageId: 'debug-remote-assist-reject',
        type: ChatEnvelopeType.remoteAssistReject,
        fromVirtualIp: '10.0.0.2',
        fromDeviceName: 'debug-peer',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: const {},
      ),
    );
  }

  @visibleForTesting
  Future<void> debugHandleRemoteAssistEndForTest() async {
    await _handleRemoteAssistEnd(
      ChatEnvelope(
        messageId: 'debug-remote-assist-end',
        type: ChatEnvelopeType.remoteAssistEnd,
        fromVirtualIp: '10.0.0.2',
        fromDeviceName: 'debug-peer',
        sentAt: DateTime.now().millisecondsSinceEpoch,
        payload: const {},
      ),
    );
  }

  @visibleForTesting
  void debugResetRemoteAssistTestState() {
    remoteAssistSession = null;
    _remoteAssistRuntimeReady = false;
    _lastRemoteAssistHostError = null;
    _lastRemoteAssistConnectError = null;
    _lastRemoteAssistBundledRuntimePath = null;
    _lastRemoteAssistInstalledRuntimePath = null;
    _lastRemoteAssistListenPort = null;
    _lastChatFirewallResult = null;
    _lastRemoteAssistFirewallResult = null;
    _lastRemoteAssistFirewallBlockedReady = false;
    _lastRemoteAssistHostReadySucceeded = null;
    _lastRemoteAssistReadySentAt = null;
    _lastRemoteAssistReadyReceivedAt = null;
    _processingRemoteAssistAcceptSessionIds.clear();
    debugRefreshRemoteAssistRuntime = null;
    debugEnsureRemoteAssistFirewallResult = null;
    debugEnsureRemoteAssistHostReady = null;
    debugLaunchRemoteAssistController = null;
    debugCleanupRemoteAssistRuntime = null;
    debugSendEnvelopeToPeer = null;
    statusMessage = null;
    statusVersion = 0;
    _lastConsumedStatusVersion = -1;
    _lastPushedStatusMessage = null;
    _lastPushedStatusAt = null;
  }

  Future<void> _handleRemoteAssistReject(ChatEnvelope envelope) async {
    final session = remoteAssistSession;
    if (session == null) {
      return;
    }
    remoteAssistSession = session.copyWith(
      state: RemoteAssistState.rejected,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    await _cleanupRemoteAssistRuntime(
      listenPort: session.listenPort,
      reason: 'reject_remote',
    );
    _pushStatus('对方拒绝了远程协助请求');
  }

  Future<void> _handleRemoteAssistEnd(ChatEnvelope envelope) async {
    final session = remoteAssistSession;
    if (session == null) {
      return;
    }
    remoteAssistSession = session.copyWith(
      state: RemoteAssistState.ended,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
    await _cleanupRemoteAssistRuntime(
      listenPort: session.listenPort,
      reason: 'end_remote',
    );
    _pushStatus('远程协助会话已结束');
  }

  Future<void> _handlePresence(String peerId, ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.channel ||
        session.channelId == null) {
      return;
    }
    final kind = envelope.payload['kind'] as String?;
    if (kind == 'voice_join') {
      final participants = {...session.participants, peerId}.toList()..sort();
      callSession = session.copyWith(participants: participants);
      notifyListeners();
      final localPeerId = _localPeerIdForNetwork(session.networkKey);
      final isReply = envelope.payload['reply'] == true;
      if (!isReply &&
          localPeerId != null &&
          localPeerId != peerId &&
          session.joinedVoice) {
        await _sendEnvelopeToPeer(
          networkKey: session.networkKey,
          peerId: peerId,
          type: ChatEnvelopeType.presence,
          channelId: session.channelId,
          payload: {
            'kind': 'voice_join',
            'channelId': session.channelId,
            'peerId': localPeerId,
            'callId': session.callId,
            'reply': true,
          },
        );
      }
      await _logger.info(
        'voice.channel',
        '收到频道语音加入通知',
        networkKey: session.networkKey,
        extra: {
          'channelId': session.channelId,
          'peerId': peerId,
          'participants': participants.length,
        },
      );
    } else if (kind == 'voice_leave') {
      final participants =
          session.participants.where((id) => id != peerId).toList();
      callSession = session.copyWith(participants: participants);
      notifyListeners();
      await _logger.info(
        'voice.channel',
        '收到频道语音离开通知',
        networkKey: session.networkKey,
        extra: {
          'channelId': session.channelId,
          'peerId': peerId,
          'participants': participants.length,
        },
      );
    }
  }

  Future<void> _handlePttRequest(String peerId, ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null ||
        session.type != ChatCallType.channel ||
        session.channelId == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId != _coordinatorPeerId(session) ||
        session.speakerPeerId?.isNotEmpty == true) {
      return;
    }
    await _grantPtt(session, peerId);
    await _logger.info(
      'voice.ptt',
      '收到发言权申请',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'peerId': peerId,
      },
    );
  }

  Future<void> _handlePttGrant(ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null) {
      return;
    }
    final holderPeerId = envelope.payload['holderPeerId'] as String?;
    if (holderPeerId == null) {
      return;
    }
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == holderPeerId) {
      try {
        await _audio.startMicrophoneStream((bytes) {
          unawaited(_broadcastChannelAudio(bytes, session));
        });
      } catch (error) {
        callSession = session.copyWith(speakerPeerId: '');
        notifyListeners();
        final coordinator = _coordinatorPeerId(session);
        if (coordinator != null && coordinator != localPeerId) {
          await _sendEnvelopeToPeer(
            networkKey: session.networkKey,
            peerId: coordinator,
            type: ChatEnvelopeType.pttRelease,
            channelId: session.channelId,
            payload: {
              'callId': session.callId,
              'holderPeerId': holderPeerId,
            },
          );
        }
        _pushStatus(_audio.userMessageForError(error, action: '开启频道发言'));
        await _logger.error(
          'voice.ptt',
          '收到发言权后启动麦克风失败',
          networkKey: session.networkKey,
          extra: {
            'channelId': session.channelId,
            'holderPeerId': holderPeerId,
            'error': error.toString(),
          },
        );
        return;
      }
    }
    callSession = session.copyWith(speakerPeerId: holderPeerId);
    notifyListeners();
    await _logger.info(
      'voice.ptt',
      '收到发言权授予',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'holderPeerId': holderPeerId,
      },
    );
  }

  Future<void> _handlePttRelease(ChatEnvelope envelope) async {
    final session = callSession;
    if (session == null) {
      return;
    }
    final holderPeerId = envelope.payload['holderPeerId'] as String?;
    final localPeerId = _localPeerIdForNetwork(session.networkKey);
    if (localPeerId == holderPeerId) {
      await _audio.stopMicrophoneStream();
    }
    callSession = session.copyWith(speakerPeerId: '');
    notifyListeners();
    await _logger.info(
      'voice.ptt',
      '收到发言权释放',
      networkKey: session.networkKey,
      extra: {
        'channelId': session.channelId,
        'holderPeerId': holderPeerId,
      },
    );
  }

  Future<void> _handleAck(ChatEnvelope envelope) async {
    final targetId = envelope.payload['targetMessageId'] as String?;
    if (targetId == null) {
      return;
    }
    final message = await _repository.getMessage(targetId);
    if (message == null) {
      return;
    }
    await _repository.replaceMessage(
      message.copyWith(status: ChatMessageStatus.delivered),
    );
    await _logger.info(
      'message.ack',
      '收到消息回执',
      networkKey: message.networkKey,
      extra: {
        'messageId': targetId,
        'conversationId': message.conversationId,
      },
    );
  }

  @override
  Future<String?> prepareIncomingAttachmentPath({
    required String networkKey,
    required Map<String, dynamic> header,
  }) async {
    final fileName = (header['fileName'] as String?) ?? 'file.bin';
    final target = await _repository.createIncomingFile(fileName);
    return target.path;
  }

  @override
  Future<void> onAttachmentReceived({
    required String networkKey,
    required Map<String, dynamic> header,
    required String localPath,
    required int bytesReceived,
  }) async {
    final attachmentId = header['attachmentId'] as String?;
    final messageId = header['messageId'] as String?;
    if (attachmentId == null || messageId == null) {
      return;
    }
    final attachment = await _repository.getAttachment(attachmentId);
    final message = await _repository.getMessage(messageId);
    if (attachment == null || message == null) {
      return;
    }
    final actualSha = await _repository.computeSha256(localPath);
    if (actualSha != attachment.sha256) {
      await _repository.deleteFileIfExists(localPath);
      await _repository.upsertAttachment(
        attachment.copyWith(transferStatus: ChatMessageStatus.failed),
      );
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.failed),
      );
      await _logger.error(
        'attachment.receive',
        '附件校验失败',
        networkKey: networkKey,
        extra: {
          'messageId': messageId,
          'attachmentId': attachmentId,
          'expectedSha256': attachment.sha256,
          'actualSha256': actualSha,
        },
      );
      await _reloadSidebar();
      return;
    }
    await _repository.upsertAttachment(
      attachment.copyWith(
        localPath: localPath,
        transferStatus: ChatMessageStatus.transferred,
        offerStatus: ChatMessageStatus.accepted,
      ),
    );
    await _repository.replaceMessage(
      message.copyWith(status: ChatMessageStatus.transferred),
    );
    await _logger.info(
      'attachment.receive',
      '附件接收完成并校验通过',
      networkKey: networkKey,
      extra: {
        'messageId': messageId,
        'attachmentId': attachmentId,
        'localPath': localPath,
        'bytesReceived': bytesReceived,
      },
    );
    await _reloadSidebar();
  }

  @override
  Future<void> onAttachmentFailed({
    required String networkKey,
    required Map<String, dynamic>? header,
    required Object error,
  }) async {
    final attachmentId = header?['attachmentId'] as String?;
    if (attachmentId == null) {
      return;
    }
    final attachment = await _repository.getAttachment(attachmentId);
    if (attachment == null) {
      return;
    }
    final message = await _repository.getMessage(attachment.messageId);
    await _repository.upsertAttachment(
      attachment.copyWith(transferStatus: ChatMessageStatus.failed),
    );
    if (message != null) {
      await _repository.replaceMessage(
        message.copyWith(status: ChatMessageStatus.failed),
      );
    }
    await _logger.error(
      'attachment.receive',
      '附件接收失败',
      networkKey: networkKey,
      extra: {
        'attachmentId': attachmentId,
        'error': error.toString(),
      },
    );
    await _reloadSidebar();
  }

  @override
  Future<void> onMediaPacketReceived({
    required String networkKey,
    required String remoteIp,
    required Map<String, dynamic> packet,
  }) async {
    final session = callSession;
    if (session == null) {
      return;
    }
    final callType = ChatCallType.values.byName(
      (packet['type'] as String?) ?? ChatCallType.direct.name,
    );
    if (callType != session.type) {
      return;
    }
    if ((packet['callId'] as String?) != session.callId) {
      return;
    }
    final samples = packet['samples'] as String?;
    if (samples == null) {
      return;
    }
    final bytes = base64Decode(samples);
    await _audio.playIncomingPcm(bytes);
    _mediaPlaybackPackets++;
    if (_mediaPlaybackPackets == 1 || _mediaPlaybackPackets % 25 == 0) {
      await _logger.info(
        'voice.media',
        '已播放实时语音包',
        networkKey: networkKey,
        extra: {
          'callId': packet['callId'],
          'type': packet['type'],
          'packetCount': _mediaPlaybackPackets,
          'remoteIp': remoteIp,
        },
      );
    }
  }

  @override
  void onNetworkWarning(String networkKey, Object error,
      [StackTrace? stackTrace]) {
    debugPrint('[$networkKey] chat network warning: $error');
    unawaited(_logger.error(
      'network.warning',
      '聊天室网络异常',
      networkKey: networkKey,
      extra: {
        'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      },
    ));
    final lower = error.toString().toLowerCase();
    if (lower.contains('permission') || lower.contains('microphone')) {
      _pushStatus('聊天室音频异常，请检查麦克风权限或音频设备');
      return;
    }
    if (lower.contains('bind') || lower.contains('socket')) {
      _pushStatus('聊天室网络异常，请查看联调诊断和 chat-debug.log');
      return;
    }
    _pushStatus('聊天室运行异常，请查看联调诊断和 chat-debug.log');
  }
}

final ChatManager chatManager = ChatManager.instance;

extension _FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

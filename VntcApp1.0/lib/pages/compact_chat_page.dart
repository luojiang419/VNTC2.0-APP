import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/screenshot/system_screenshot_service.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/toast_utils.dart';

class CompactChatPage extends StatefulWidget {
  const CompactChatPage({super.key});

  @override
  State<CompactChatPage> createState() => _CompactChatPageState();
}

class _CompactChatPageState extends State<CompactChatPage> {
  final ChatManager _manager = ChatManager.instance;
  final TextEditingController _textController = TextEditingController();
  String? _openingHallId;
  String? _pendingScreenshotPath;
  bool _sending = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_manager.start());
  }

  @override
  void dispose() {
    final pendingScreenshotPath = _pendingScreenshotPath;
    if (pendingScreenshotPath != null && !_sending) {
      unawaited(_deletePendingScreenshot(pendingScreenshotPath));
    }
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: context.canvasBackground,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: _manager,
          builder: (context, _) {
            if (!_manager.supported) {
              return _buildCenteredMessage(
                isDark,
                icon: Icons.desktop_mac_outlined,
                text: '当前平台暂未接入聊天室',
              );
            }
            final conversation = _resolveHallConversation();
            if (conversation == null) {
              _openFirstHallWhenReady();
              return _buildCenteredMessage(
                isDark,
                icon: _manager.loading
                    ? Icons.sync_rounded
                    : Icons.forum_outlined,
                text: _emptyMessage,
              );
            }
            _ensureConversationOpen(conversation);
            final messages = _manager.selectedConversationId == conversation.id
                ? _manager.selectedMessages
                : const <ChatMessageRecord>[];
            return Padding(
              padding: EdgeInsets.fromLTRB(
                context.spacingSmall,
                context.spacingSmall,
                context.spacingSmall,
                context.spacingSmall,
              ),
              child: Container(
                key: const ValueKey('compact-chat-panel'),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.darkCardBackground
                      : AppTheme.lightCardBackground,
                  borderRadius: BorderRadius.circular(context.cardRadius),
                ),
                child: Column(
                  children: [
                    _buildHeader(isDark, conversation),
                    Expanded(
                      child: messages.isEmpty
                          ? Center(
                              child: Text(
                                '还没有消息',
                                style: TextStyle(
                                  color: isDark
                                      ? AppTheme.darkTextSecondary
                                      : AppTheme.lightTextSecondary,
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: EdgeInsets.all(context.cardPaddingSmall),
                              itemCount: messages.length,
                              itemBuilder: (context, index) =>
                                  _buildMessageBubble(
                                isDark,
                                messages[index],
                              ),
                            ),
                    ),
                    _buildComposer(isDark, conversation),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, ChatConversation conversation) {
    final outline = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    return Container(
      padding: EdgeInsets.only(
        left: context.spacingMedium,
        right: context.spacingXSmall,
        top: context.spacingXSmall,
        bottom: context.spacingXSmall,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('compact-chat-clear-button'),
            onPressed: _clearing
                ? null
                : () => _confirmClearHallMessages(conversation),
            tooltip: '清空聊天大厅内容',
            icon: _clearing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
    );
  }

  String get _emptyMessage {
    if (_manager.loading) {
      return '正在连接组网聊天室…';
    }
    final issue = _manager.chatStartupIssue;
    if (issue != null) {
      return issue;
    }
    return _manager.hasActiveVntConnections ? '正在读取当前组网大厅…' : '连接组网后即可开始聊天';
  }

  ChatConversation? _resolveHallConversation() {
    if (_manager.halls.isEmpty) {
      return null;
    }
    final selectedHallId = _manager.selectedHallId;
    final hallId = _manager.halls.any((hall) => hall.id == selectedHallId)
        ? selectedHallId!
        : _manager.halls.first.id;
    for (final conversation in _manager.conversations) {
      if (conversation.type == ChatConversationType.hall &&
          (conversation.id == hallId || conversation.hallId == hallId)) {
        return conversation;
      }
    }
    return null;
  }

  void _openFirstHallWhenReady() {
    if (_manager.halls.isEmpty) {
      return;
    }
    final hallId = _manager.halls.first.id;
    if (_openingHallId == hallId) {
      return;
    }
    _openingHallId = hallId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _manager.selectHall(hallId);
      } finally {
        _openingHallId = null;
      }
    });
  }

  void _ensureConversationOpen(ChatConversation conversation) {
    if (_manager.selectedConversationId == conversation.id ||
        _openingHallId == conversation.hallId) {
      return;
    }
    _openingHallId = conversation.hallId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _manager.selectHall(conversation.hallId);
      } finally {
        _openingHallId = null;
      }
    });
  }

  Widget _buildCenteredMessage(
    bool isDark, {
    required IconData icon,
    required String text,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 84),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: context.iconXLarge,
              color: Theme.of(context).primaryColor,
            ),
            SizedBox(height: context.spacingSmall),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.spacingLarge),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(bool isDark, ChatMessageRecord message) {
    final outgoing = message.direction == ChatMessageDirection.outgoing;
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.72,
        ),
        margin: EdgeInsets.only(bottom: context.spacingSmall),
        padding: EdgeInsets.all(context.spacingSmall),
        decoration: BoxDecoration(
          color: outgoing
              ? Theme.of(context).primaryColor.withValues(alpha: 0.14)
              : isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(context.cardRadius),
        ),
        child: Column(
          crossAxisAlignment:
              outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!outgoing)
              Text(
                message.senderName,
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
            if (message.contentType == ChatMessageContentType.image &&
                message.attachment?.payloadAvailable == true)
              FutureBuilder<String>(
                future: _manager.resolveAttachmentPath(message.attachment!),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  return Column(
                    crossAxisAlignment: outgoing
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(context.radius(10)),
                        child: Image.file(
                          File(snapshot.data!),
                          width: 260,
                          cacheWidth: 520,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              _buildAttachmentLabel(message, textColor),
                        ),
                      ),
                      if (message.attachmentCaption case final caption?) ...[
                        SizedBox(height: context.spacingXSmall),
                        Text(caption, style: TextStyle(color: textColor)),
                      ],
                    ],
                  );
                },
              )
            else if (message.contentType == ChatMessageContentType.text)
              Text(message.text, style: TextStyle(color: textColor))
            else
              _buildAttachmentLabel(message, textColor),
            if (message.status == ChatMessageStatus.failed)
              Text(
                '发送失败',
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: Colors.red,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentLabel(ChatMessageRecord message, Color textColor) {
    final isImage = message.contentType == ChatMessageContentType.image;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
          color: textColor,
          size: context.iconSmall,
        ),
        SizedBox(width: context.spacingXSmall),
        Flexible(
          child: Text(
            message.attachment?.fileName ?? message.text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor),
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(bool isDark, ChatConversation conversation) {
    final outline = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    return Container(
      key: const ValueKey('compact-chat-composer'),
      padding: EdgeInsets.all(context.spacingSmall),
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: outline))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pendingScreenshotPath case final screenshotPath?) ...[
            _buildPendingScreenshot(isDark, screenshotPath),
            SizedBox(height: context.spacingSmall),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                key: const ValueKey('compact-chat-screenshot-button'),
                onPressed: _sending ? null : _captureScreenshot,
                tooltip: '截取屏幕',
                icon: const Icon(Icons.screenshot_monitor_outlined),
              ),
              IconButton(
                key: const ValueKey('compact-chat-file-button'),
                onPressed: _sending ? null : () => _pickAndSend(conversation),
                tooltip: '发送文件',
                icon: const Icon(Icons.attach_file_rounded),
              ),
              Expanded(
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(
                      LogicalKeyboardKey.enter,
                      includeRepeats: false,
                    ): _CompactSubmitIntent(),
                    SingleActivator(
                      LogicalKeyboardKey.numpadEnter,
                      includeRepeats: false,
                    ): _CompactSubmitIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _CompactSubmitIntent:
                          CallbackAction<_CompactSubmitIntent>(
                        onInvoke: (_) {
                          unawaited(_sendMessage(conversation));
                          return null;
                        },
                      ),
                    },
                    child: TextField(
                      key: const ValueKey('compact-chat-text-input'),
                      controller: _textController,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      enabled: !_sending,
                      decoration: const InputDecoration(
                        hintText: '输入消息',
                        isDense: true,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: context.spacingXSmall),
              IconButton.filled(
                key: const ValueKey('compact-chat-send-button'),
                onPressed: _sending ? null : () => _sendMessage(conversation),
                tooltip: '发送',
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPendingScreenshot(bool isDark, String screenshotPath) {
    final outline = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.12);
    return Align(
      alignment: Alignment.centerLeft,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            key: const ValueKey('compact-chat-screenshot-preview'),
            width: 112,
            height: 72,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              border: Border.all(color: outline),
              borderRadius: BorderRadius.circular(context.radius(10)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radius(7)),
              child: Image.file(
                File(screenshotPath),
                fit: BoxFit.cover,
                cacheWidth: 224,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ),
          Positioned(
            right: -10,
            top: -10,
            child: IconButton.filled(
              key: const ValueKey('compact-chat-remove-screenshot-button'),
              onPressed: _sending ? null : _removePendingScreenshot,
              tooltip: '移除截图',
              icon: const Icon(Icons.close_rounded, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendMessage(ChatConversation conversation) async {
    final text = _textController.text.trim();
    final composing = _textController.value.composing;
    final screenshotPath = _pendingScreenshotPath;
    if ((text.isEmpty && screenshotPath == null) ||
        (composing.isValid && !composing.isCollapsed)) {
      return;
    }
    final completed = await _runSend(
      screenshotPath == null
          ? () => _manager.sendText(
                conversationId: conversation.id,
                text: text,
              )
          : () => _manager.sendAttachment(
                conversationId: conversation.id,
                sourceFilePath: screenshotPath,
                explicitContentType: ChatMessageContentType.image,
                caption: text,
              ),
      failurePrefix: screenshotPath == null ? '消息发送失败' : '截图发送失败',
      savedPath: screenshotPath,
    );
    if (!mounted) {
      if (screenshotPath != null) {
        await _deletePendingScreenshot(screenshotPath);
      }
      return;
    }
    if (!completed) {
      return;
    }
    _textController.clear();
    if (screenshotPath != null) {
      setState(() => _pendingScreenshotPath = null);
      unawaited(_deletePendingScreenshot(screenshotPath));
    }
  }

  Future<void> _captureScreenshot() async {
    final capture = await SystemScreenshotService.instance.captureInteractive();
    if (capture.isCanceled) {
      return;
    }
    if (!capture.isSuccess) {
      if (mounted) {
        showTopToast(context, '截图失败: ${capture.error}', isSuccess: false);
      }
      return;
    }
    final previousPath = _pendingScreenshotPath;
    if (!mounted) {
      await _deletePendingScreenshot(capture.filePath!);
      return;
    }
    setState(() => _pendingScreenshotPath = capture.filePath);
    if (previousPath != null && previousPath != capture.filePath) {
      unawaited(_deletePendingScreenshot(previousPath));
    }
  }

  Future<void> _pickAndSend(ChatConversation conversation) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
      );
      final filePath = picked?.files.single.path;
      if (filePath == null || filePath.trim().isEmpty) {
        return;
      }
      await _runSend(
        () => _manager.sendAttachment(
          conversationId: conversation.id,
          sourceFilePath: filePath,
        ),
        failurePrefix: '文件发送失败',
      );
    } catch (error) {
      if (mounted) {
        showTopToast(context, '选择文件失败: $error', isSuccess: false);
      }
    }
  }

  Future<bool> _runSend(
    Future<ChatSendResult> Function() operation, {
    required String failurePrefix,
    String? savedPath,
  }) async {
    if (_sending) {
      return false;
    }
    setState(() => _sending = true);
    try {
      final result = await operation();
      if (!mounted) {
        return true;
      }
      if (result.isFailure ||
          result.isPartialSuccess ||
          result.hadNoRecipients) {
        final message = result.hadNoRecipients
            ? savedPath == null
                ? '当前大厅没有可接收消息的在线设备'
                : '截图已保存，但当前大厅没有可接收图片的在线设备'
            : result.isPartialSuccess
                ? '内容仅部分送达'
                : failurePrefix;
        showTopToast(context, message, isSuccess: result.isPartialSuccess);
      } else if (savedPath != null) {
        showTopToast(context, '截图已发送', isSuccess: true);
      }
      return true;
    } catch (error) {
      if (mounted) {
        showTopToast(context, '$failurePrefix: $error', isSuccess: false);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _confirmClearHallMessages(ChatConversation conversation) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('清空聊天大厅内容'),
            content: Text(
              '确定清空“${conversation.title}”中的全部聊天内容吗？\n\n'
              '此操作只清理本机记录，且无法撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _clearing = true);
    try {
      final clearedCount = await _manager.clearConversationMessages(
        conversation.id,
      );
      if (mounted) {
        showTopToast(
          context,
          clearedCount > 0 ? '已清空 $clearedCount 条聊天内容' : '聊天大厅已经为空',
          isSuccess: true,
        );
      }
    } catch (error) {
      if (mounted) {
        showTopToast(context, '清空聊天大厅失败: $error', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  void _removePendingScreenshot() {
    final screenshotPath = _pendingScreenshotPath;
    if (screenshotPath == null) {
      return;
    }
    setState(() => _pendingScreenshotPath = null);
    unawaited(_deletePendingScreenshot(screenshotPath));
  }

  Future<void> _deletePendingScreenshot(String screenshotPath) async {
    try {
      final file = File(screenshotPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 截图缓存稍后由统一缓存清理流程处理。
    }
  }
}

class _CompactSubmitIntent extends Intent {
  const _CompactSubmitIntent();
}

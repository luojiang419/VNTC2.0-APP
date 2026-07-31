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
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_manager.start());
  }

  @override
  void dispose() {
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
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(context.radius(10)),
                    child: Image.file(
                      File(snapshot.data!),
                      width: 260,
                      cacheWidth: 520,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          _buildAttachmentLabel(message, textColor),
                    ),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            key: const ValueKey('compact-chat-screenshot-button'),
            onPressed: _sending ? null : () => _captureAndSend(conversation),
            tooltip: '截图并发送',
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
                  _CompactSubmitIntent: CallbackAction<_CompactSubmitIntent>(
                    onInvoke: (_) {
                      unawaited(_sendText(conversation));
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
            onPressed: _sending ? null : () => _sendText(conversation),
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
    );
  }

  Future<void> _sendText(ChatConversation conversation) async {
    final text = _textController.text.trim();
    final composing = _textController.value.composing;
    if (text.isEmpty || (composing.isValid && !composing.isCollapsed)) {
      return;
    }
    _textController.clear();
    await _runSend(
      () => _manager.sendText(conversationId: conversation.id, text: text),
      failurePrefix: '消息发送失败',
      restoreText: text,
    );
  }

  Future<void> _captureAndSend(ChatConversation conversation) async {
    final capture = await SystemScreenshotService.instance.captureFullScreen();
    if (!capture.isSuccess) {
      if (mounted) {
        showTopToast(context, '截图失败: ${capture.error}', isSuccess: false);
      }
      return;
    }
    await _runSend(
      () => _manager.sendAttachment(
        conversationId: conversation.id,
        sourceFilePath: capture.filePath!,
        explicitContentType: ChatMessageContentType.image,
      ),
      failurePrefix: '截图发送失败',
      savedPath: capture.filePath,
    );
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

  Future<void> _runSend(
    Future<ChatSendResult> Function() operation, {
    required String failurePrefix,
    String? restoreText,
    String? savedPath,
  }) async {
    if (_sending) {
      return;
    }
    setState(() => _sending = true);
    try {
      final result = await operation();
      if (!mounted) {
        return;
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
        showTopToast(context, '截图已保存并发送', isSuccess: true);
      }
    } catch (error) {
      if (restoreText != null && _textController.text.isEmpty) {
        _textController.text = restoreText;
      }
      if (mounted) {
        showTopToast(context, '$failurePrefix: $error', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }
}

class _CompactSubmitIntent extends Intent {
  const _CompactSubmitIntent();
}

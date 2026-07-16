class ChatConstants {
  ChatConstants._();

  // 使用 IANA 动态/私有端口，避开部分 Android 内核保留的 500xx 端口段。
  static const int presencePort = 61018;
  static const int transportPort = 61019;
  static const int smallAttachmentMaxBytes = 10 * 1024 * 1024;
  static const int maxTransportPacketBytes = 16 * 1024 * 1024;
  static const int syncBatchSize = 100;
  static const Duration presenceBroadcastInterval = Duration(seconds: 5);
  static const Duration presenceExpiry = Duration(seconds: 18);
  static const Duration transportReadTimeout = Duration(seconds: 10);
  static const int attachmentTransferMaxAttempts = 3;
  static const Duration attachmentTransferRetryDelay = Duration(seconds: 1);
  static const Duration attachmentProgressUpdateInterval = Duration(
    milliseconds: 200,
  );
  static const Duration refreshInterval = Duration(seconds: 3);
  static const Duration syncInterval = Duration(seconds: 12);

  static const String presencePacketType = 'vnt_chat_presence_v1';
  static const String chatRuleNameTcp = 'VNTC Chat TCP 61019';
  static const String chatRuleNameUdp = 'VNTC Chat UDP 61018';
}

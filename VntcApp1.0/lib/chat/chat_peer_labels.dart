import 'chat_models.dart';

String chatPeerPrimaryName(ChatPeer peer) {
  final deviceName = peer.deviceName.trim();
  if (deviceName.isNotEmpty) {
    return deviceName;
  }
  return peer.virtualIp;
}

String buildOnlinePeerSubtitle(
  ChatPeer peer, {
  required bool hasMultipleNetworks,
  required ChatFriendStatus friendStatus,
}) {
  final parts = <String>[];
  final remark = peer.remark.trim();
  if (remark.isNotEmpty) {
    parts.add('备注：$remark');
  }
  parts.add(peer.virtualIp);
  if (hasMultipleNetworks) {
    parts.add(peer.networkKey);
  }
  if (friendStatus == ChatFriendStatus.friend) {
    parts.add('好友');
  }
  return parts.join(' · ');
}

String buildMemberPeerSubtitle(
  ChatPeer peer, {
  required bool hasMultipleNetworks,
  String? suffix,
}) {
  final parts = <String>[];
  final remark = peer.remark.trim();
  if (remark.isNotEmpty) {
    parts.add('备注：$remark');
  }
  parts.add(peer.virtualIp);
  if (hasMultipleNetworks) {
    parts.add(peer.networkKey);
  }
  final trimmedSuffix = suffix?.trim() ?? '';
  if (trimmedSuffix.isNotEmpty) {
    parts.add(trimmedSuffix);
  }
  return parts.join(' · ');
}

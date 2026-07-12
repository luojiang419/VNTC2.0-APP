import 'remote_assist_models.dart';

int? ipv4NetmaskToPrefix(String netmask) {
  final parts = netmask.trim().split('.');
  if (parts.length != 4) {
    return null;
  }

  final bits = StringBuffer();
  for (final part in parts) {
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < 0 || parsed > 255) {
      return null;
    }
    bits.write(parsed.toRadixString(2).padLeft(8, '0'));
  }

  final bitString = bits.toString();
  if (!RegExp(r'^1*0*$').hasMatch(bitString)) {
    return null;
  }
  return '1'.allMatches(bitString).length;
}

bool isValidIpv4(String value) {
  final parts = value.trim().split('.');
  if (parts.length != 4) {
    return false;
  }

  for (final part in parts) {
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < 0 || parsed > 255) {
      return false;
    }
  }
  return true;
}

String? cidrFromNetworkAndMask(String network, String netmask) {
  final trimmedNetwork = network.trim();
  final prefix = ipv4NetmaskToPrefix(netmask);
  if (!isValidIpv4(trimmedNetwork) || prefix == null) {
    return null;
  }
  return '$trimmedNetwork/$prefix';
}

String normalizeRemoteAssistDisplayName(
  String? name, {
  required String fallbackIp,
}) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == fallbackIp) {
    return '未命名设备';
  }
  return trimmed;
}

RemoteAssistPlatform inferRemoteAssistPlatformFromDeviceName(String name) {
  final normalized = name.trim().toLowerCase();
  if (RegExp(r'(^|[\s._-])linux([\s._-]|$)').hasMatch(normalized) ||
      normalized.contains('ubuntu') ||
      normalized.contains('debian') ||
      normalized.contains('centos') ||
      normalized.contains('fedora')) {
    return RemoteAssistPlatform.linux;
  }
  return RemoteAssistPlatform.unsupported;
}

String buildRemoteAssistPeerKey({
  required String networkName,
  required String virtualIp,
}) {
  return '$networkName::$virtualIp';
}

String trimToEmpty(Object? value) {
  return value?.toString().trim() ?? '';
}

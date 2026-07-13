import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const int _chatRoomPasswordIterations = 20000;

String createChatRoomPasswordMetadata(String password) {
  final normalized = password.trim();
  if (normalized.isEmpty) {
    return '{}';
  }
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final hash = _deriveChatRoomPasswordHash(
    normalized,
    salt,
    _chatRoomPasswordIterations,
  );
  return jsonEncode(<String, Object>{
    'passwordVersion': 1,
    'passwordIterations': _chatRoomPasswordIterations,
    'passwordSalt': base64Encode(salt),
    'passwordHash': base64Encode(hash),
  });
}

bool chatRoomRequiresPassword(String metadataJson) {
  final metadata = _decodeRoomMetadata(metadataJson);
  return (metadata['passwordHash'] ?? '').toString().isNotEmpty &&
      (metadata['passwordSalt'] ?? '').toString().isNotEmpty;
}

bool verifyChatRoomPassword(String password, String metadataJson) {
  final metadata = _decodeRoomMetadata(metadataJson);
  try {
    final salt = base64Decode((metadata['passwordSalt'] ?? '').toString());
    final expected = base64Decode((metadata['passwordHash'] ?? '').toString());
    final iterations = int.tryParse(
          (metadata['passwordIterations'] ?? '').toString(),
        ) ??
        _chatRoomPasswordIterations;
    if (salt.isEmpty || expected.isEmpty || iterations < 1) {
      return false;
    }
    final actual = _deriveChatRoomPasswordHash(
      password.trim(),
      salt,
      iterations,
    );
    if (actual.length != expected.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < actual.length; index += 1) {
      difference |= actual[index] ^ expected[index];
    }
    return difference == 0;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic> _decodeRoomMetadata(String metadataJson) {
  try {
    final decoded = jsonDecode(metadataJson);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}

List<int> _deriveChatRoomPasswordHash(
  String password,
  List<int> salt,
  int iterations,
) {
  final passwordBytes = utf8.encode(password);
  var digest = sha256.convert(<int>[...salt, ...passwordBytes]).bytes;
  for (var round = 1; round < iterations; round += 1) {
    digest = sha256.convert(<int>[...digest, ...salt, ...passwordBytes]).bytes;
  }
  return digest;
}

bool isChatRemoteAddressConsistent({
  required String remoteAddress,
  required String declaredVirtualIp,
}) {
  final remote = remoteAddress.trim();
  final declared = declaredVirtualIp.trim();
  if (remote.isEmpty || declared.isEmpty) {
    return false;
  }
  if (remote == declared) {
    return true;
  }

  final remoteParsed = InternetAddress.tryParse(remote);
  final declaredParsed = InternetAddress.tryParse(declared);
  if (remoteParsed == null || declaredParsed == null) {
    return false;
  }
  return remoteParsed.address == declaredParsed.address;
}

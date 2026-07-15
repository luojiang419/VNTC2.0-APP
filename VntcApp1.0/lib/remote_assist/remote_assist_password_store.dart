import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class RemoteAssistSecretStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterRemoteAssistSecretStorage implements RemoteAssistSecretStorage {
  const FlutterRemoteAssistSecretStorage({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class RemoteAssistPasswordStore {
  RemoteAssistPasswordStore(this._storage);

  static final RemoteAssistPasswordStore instance = RemoteAssistPasswordStore(
    const FlutterRemoteAssistSecretStorage(),
  );

  static const String _keyPrefix = 'remote_assist_peer_password_v1_';
  static const String _accessPasswordKey = 'remote_assist_access_password_v1';

  final RemoteAssistSecretStorage _storage;

  Future<String> load(String peerKey) async {
    return await _storage.read(storageKeyForPeer(peerKey)) ?? '';
  }

  Future<void> save(String peerKey, String password) async {
    final key = storageKeyForPeer(peerKey);
    if (password.isEmpty) {
      await _storage.delete(key);
      return;
    }
    await _storage.write(key, password);
  }

  Future<void> delete(String peerKey) async {
    await _storage.delete(storageKeyForPeer(peerKey));
  }

  Future<String> loadAccessPassword() async {
    return await _storage.read(_accessPasswordKey) ?? '';
  }

  Future<void> saveAccessPassword(String password) async {
    if (password.isEmpty) {
      await _storage.delete(_accessPasswordKey);
      return;
    }
    await _storage.write(_accessPasswordKey, password);
  }

  Future<void> deleteAccessPassword() async {
    await _storage.delete(_accessPasswordKey);
  }

  static String storageKeyForPeer(String peerKey) {
    final normalized = peerKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(peerKey, 'peerKey', '设备标识不能为空');
    }
    final digest = sha256.convert(utf8.encode(normalized));
    return '$_keyPrefix$digest';
  }
}

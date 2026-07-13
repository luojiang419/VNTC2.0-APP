import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_password_store.dart';

void main() {
  group('RemoteAssistPasswordStore', () {
    late _MemorySecretStorage backend;
    late RemoteAssistPasswordStore store;

    setUp(() {
      backend = _MemorySecretStorage();
      store = RemoteAssistPasswordStore(backend);
    });

    test('按设备标识隔离保存和读取密码', () async {
      await store.save('network-a::10.0.0.2', 'password-a');
      await store.save('network-a::10.0.0.3', 'password-b');

      expect(await store.load('network-a::10.0.0.2'), 'password-a');
      expect(await store.load('network-a::10.0.0.3'), 'password-b');
    });

    test('保存新密码会更新已有密码', () async {
      const peerKey = 'network-a::10.0.0.2';
      await store.save(peerKey, 'old-password');
      await store.save(peerKey, 'new-password');

      expect(await store.load(peerKey), 'new-password');
    });

    test('删除或保存空密码会清除凭据', () async {
      const peerKey = 'network-a::10.0.0.2';
      await store.save(peerKey, 'password');
      await store.delete(peerKey);
      expect(await store.load(peerKey), isEmpty);

      await store.save(peerKey, 'password');
      await store.save(peerKey, '');
      expect(await store.load(peerKey), isEmpty);
    });

    test('存储键不暴露网络名和虚拟 IP', () {
      const peerKey = 'private-network::10.26.0.8';
      final storageKey = RemoteAssistPasswordStore.storageKeyForPeer(peerKey);

      expect(storageKey, isNot(contains('private-network')));
      expect(storageKey, isNot(contains('10.26.0.8')));
      expect(storageKey, startsWith('remote_assist_peer_password_v1_'));
    });
  });
}

class _MemorySecretStorage implements RemoteAssistSecretStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

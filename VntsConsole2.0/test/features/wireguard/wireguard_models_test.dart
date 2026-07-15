import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/features/wireguard/domain/wireguard_models.dart';

void main() {
  test('生成配置包含完整 WireGuard 客户端字段且不改写一次性密钥', () {
    final config = GeneratedWireGuardConfig.fromJson({
      'peer': {
        'network_code': 'alpha',
        'peer_id': 'phone',
        'public_key': 'client-public=',
        'enabled': true,
        'ip': '10.26.0.8',
        'created_at': 1,
        'updated_at': 1,
      },
      'private_key': 'one-time-private=',
      'server_public_key': 'server-public=',
      'listen_addr': '0.0.0.0:51820',
      'endpoint': 'vpn.example.com:51820',
      'allowed_ips': '10.26.0.0/24',
    });

    expect(config.clientConfig, contains('PrivateKey = one-time-private='));
    expect(config.clientConfig, contains('Address = 10.26.0.8/32'));
    expect(config.clientConfig, contains('PublicKey = server-public='));
    expect(config.clientConfig, contains('Endpoint = vpn.example.com:51820'));
    expect(config.clientConfig, contains('AllowedIPs = 10.26.0.0/24'));
  });
}

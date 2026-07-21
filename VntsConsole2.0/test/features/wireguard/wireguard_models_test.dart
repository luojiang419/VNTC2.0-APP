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
        'dns_servers': ['1.1.1.1', '2606:4700:4700::1111'],
        'dns_inherited': false,
        'persistent_keepalive': 15,
        'routes': [
          {'lan_network': '192.168.10.0/24', 'vnt_cli_ip': '10.26.0.10'},
        ],
        'config_available': true,
        'online': true,
        'status': 'online',
      },
      'private_key': 'one-time-private=',
      'server_public_key': 'server-public=',
      'listen_addr': '0.0.0.0:51820',
      'endpoint': 'vpn.example.com:51820',
      'allowed_ips': '10.26.0.0/24',
      'dns_servers': ['1.1.1.1'],
      'persistent_keepalive': 15,
      'routes': [
        {'lan_network': '192.168.10.0/24', 'vnt_cli_ip': '10.26.0.10'},
      ],
    });

    expect(config.clientConfig, contains('PrivateKey = one-time-private='));
    expect(config.clientConfig, contains('Address = 10.26.0.8/32'));
    expect(config.clientConfig, contains('PublicKey = server-public='));
    expect(config.clientConfig, contains('Endpoint = vpn.example.com:51820'));
    expect(config.clientConfig, contains('AllowedIPs = 10.26.0.0/24'));
    expect(config.clientConfig, contains('DNS = 1.1.1.1'));
    expect(config.clientConfig, contains('PersistentKeepalive = 15'));
    expect(config.peer.online, isTrue);
    expect(config.peer.status, 'online');
    expect(config.peer.routes.single.lanNetwork, '192.168.10.0/24');
  });

  test('Profile 序列化保留显式空 DNS 与路由字段', () {
    const profile = WireGuardPeerProfile(
      dnsServers: [],
      persistentKeepalive: 0,
      routes: [
        WireGuardRoute(lanNetwork: '172.16.0.0/16', vntClientIp: '10.26.0.20'),
      ],
    );
    expect(profile.toJson(), {
      'dns_servers': <String>[],
      'persistent_keepalive': 0,
      'routes': [
        {'lan_network': '172.16.0.0/16', 'vnt_cli_ip': '10.26.0.20'},
      ],
    });
  });
}

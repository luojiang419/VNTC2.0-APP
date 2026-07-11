import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/network_config_input_page.dart';

void main() {
  test('旧版配置升级后仍能推导出 2.0 核心默认值', () {
    final config = NetworkConfig.fromJson({
      'itemKey': 'legacy-1',
      'config_name': '旧配置',
      'token': 'group-1',
      'name': 'legacy-node',
      'server_address': 'legacy.example.com:29872',
      'stun_server': ['stun.miwifi.com'],
      'in_ips': [],
      'out_ips': [],
      'mapping': [],
      'password': '',
      'server_encrypt': false,
      'protocol': 'UDP',
      'finger': false,
      'cipher_model': 'xor',
      'device_id': 'device-1',
      'device_name': 'vnt-tun-1',
      'mtu': 1410,
      'ports': [],
      'first_latency': false,
      'no_proxy': true,
      'dns': [],
      'packet_loss': 0.0,
      'packet_delay': 0,
      'punch_model': 'all',
      'use_channel': 'all',
      'compressor': 'none',
      'allow_wire_guard': false,
      'local_dev': '',
      'disable_relay': false,
    });

    expect(config.primaryServerAddress, 'legacy.example.com:29872');
    expect(config.serverList, ['legacy.example.com:29872']);
    expect(config.normalizedProtocol, 'QUIC');
    expect(config.v2CompatiblePrimaryServerAddress,
        'quic://legacy.example.com:29872');
    expect(config.ctrlPort, 21233);
    expect(config.certMode, 'skip');
    expect(config.effectiveCertMode, 'skip');
    expect(config.coreNoProxy, isTrue);
    expect(config.coreUseChannelType, 'all');
    expect(config.coreCompressor, 'none');
  });

  test('2.0 风格配置字段可被旧客户端兼容层读取并保留', () {
    final config = NetworkConfig.fromJson({
      'itemKey': 'core-1',
      'config_name': '新核心配置',
      'network_code': 'game',
      'display_device_name': 'desktop-node',
      'tun_name': 'vnt-tun-2',
      'server': ['quic://127.0.0.1:2222', 'tcp://127.0.0.1:2223'],
      'udp_stun': ['stun1.example.com'],
      'tcp_stun': ['stun2.example.com'],
      'password': 'secret',
      'cert_mode': 'skip',
      'ctrl_port': 22345,
      'rtx': true,
      'compress': true,
      'fec': true,
      'no_punch': true,
      'no_nat': true,
      'no_tun': true,
      'allow_mapping': true,
      'local_ipv4': '192.168.1.20',
      'updated_at': '2026-04-30T10:00:00Z',
    });

    expect(config.token, 'game');
    expect(config.primaryServerAddress, 'quic://127.0.0.1:2222');
    expect(config.normalizedProtocol, 'QUIC');
    expect(config.v2CompatiblePrimaryServerAddress, 'quic://127.0.0.1:2222');
    expect(
      config.v2CompatibleServerList,
      ['quic://127.0.0.1:2222', 'tcp://127.0.0.1:2223'],
    );
    expect(config.effectiveUdpStun, ['stun1.example.com']);
    expect(config.effectiveTcpStun, ['stun2.example.com']);
    expect(config.ctrlPort, 22345);
    expect(config.effectiveCertMode, 'skip');
    expect(config.coreNoProxy, isTrue);
    expect(config.coreUseChannelType, 'relay');
    expect(config.coreCompressor, 'lz4');
    expect(config.resolvedLocalBindIpv4, '192.168.1.20');
    expect(config.bridgeCipherModelPayload, contains('__vnt_bridge_json__='));

    final json = config.toJson();
    expect(json['server'], ['quic://127.0.0.1:2222', 'tcp://127.0.0.1:2223']);
    expect(json['ctrl_port'], 22345);
    expect(json['local_ipv4'], '192.168.1.20');
  });

  test('未配置 TCP STUN 时不会复用 UDP STUN 地址', () {
    final config = NetworkConfig.fromJson({
      'stun_server': ['udp-stun.example.com:3478'],
    });

    expect(config.effectiveUdpStun, ['udp-stun.example.com:3478']);
    expect(config.effectiveTcpStun, isEmpty);
    expect(config.bridgeCipherModelPayload, contains('"tcp_stun":[]'));
  });

  test('旧协议前缀与动态地址可归一化为 2.0 服务端语义', () {
    final config = NetworkConfig.fromJson({
      'itemKey': 'legacy-2',
      'config_name': '动态地址配置',
      'token': 'group-2',
      'name': 'legacy-dynamic',
      'server_address': 'txt:edge.example.com',
      'protocol': 'UDP',
      'cipher_model': 'aes_gcm',
      'cert_mode': 'finger:abc123',
      'device_id': 'device-2',
      'device_name': 'vnt-tun-2',
      'mtu': 1410,
      'ports': [],
      'dns': [],
      'stun_server': [],
      'in_ips': [],
      'out_ips': [],
      'mapping': [],
      'packet_loss': 0.0,
      'packet_delay': 0,
      'punch_model': 'all',
      'use_channel': 'all',
      'compressor': 'none',
      'allow_wire_guard': false,
      'disable_relay': false,
    });

    expect(config.normalizedProtocol, 'DYNAMIC');
    expect(
        config.v2CompatiblePrimaryServerAddress, 'dynamic://edge.example.com');
    expect(config.effectiveCertMode, 'finger:abc123');
  });

  test('WireGuard 允许访问字段在配置和表单单选值之间保持正向映射', () {
    final enabled = NetworkConfig.fromJson({'allow_wire_guard': true});
    final disabled = NetworkConfig.fromJson({'allow_wire_guard': false});

    expect(enabled.allowWg, isTrue);
    expect(disabled.allowWg, isFalse);
    expect(enabled.toJson()['allow_wire_guard'], isTrue);
    expect(disabled.toJson()['allow_wire_guard'], isFalse);
    expect(allowWgToRadioValue(true), 'TRUE');
    expect(allowWgToRadioValue(false), 'FALSE');
    expect(allowWgFromRadioValue('TRUE'), isTrue);
    expect(allowWgFromRadioValue('FALSE'), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/features/peer_servers/domain/peer_server_models.dart';

void main() {
  test('互联服务器模型保持出入站方向、连接状态与真实延迟', () {
    final snapshot = PeerServerSnapshot.fromJson({
      'outbound': [
        {
          'addr': '192.0.2.10:29873',
          'latency_ms': 16,
          'connected': true,
          'is_outbound': true,
        },
      ],
      'inbound': [
        {
          'addr': '192.0.2.20:50000',
          'latency_ms': 21,
          'connected': true,
          'is_outbound': false,
        },
      ],
    });

    expect(snapshot.outbound.single.outbound, isTrue);
    expect(snapshot.inbound.single.outbound, isFalse);
    expect(snapshot.all.length, 2);
    expect(snapshot.all.last.latencyMs, 21);
  });
}

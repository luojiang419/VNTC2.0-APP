import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/services/vnt_service_client.dart';

void main() {
  test('VntServiceStatus parses service IPC payload', () {
    final status = VntServiceStatus.fromJson(<String, dynamic>{
      'serviceState': 'running',
      'connectionState': 'connected',
      'configKey': 'default',
      'revision': '1:2',
      'virtualIp': '10.0.0.8',
      'connectTarget': 'quic://server.example:29872',
      'lastError': '',
      'updatedAtUnixMs': 123,
    });

    expect(status.serviceState, 'running');
    expect(status.isConnected, isTrue);
    expect(status.virtualIp, '10.0.0.8');
    expect(status.updatedAtUnixMs, 123);
  });

  test('VntServiceStatus tolerates missing fields from an older service', () {
    final status = VntServiceStatus.fromJson(<String, dynamic>{});

    expect(status.isConnected, isFalse);
    expect(status.lastError, isEmpty);
    expect(status.updatedAtUnixMs, 0);
  });
}

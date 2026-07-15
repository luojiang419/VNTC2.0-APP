import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/networking/api_client.dart';
import 'package:vnts_console/features/networks/data/network_repository.dart';

void main() {
  test('网络与设备仓库按服务端契约解析真实字段并编码查询参数', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Uri>[];
    final handling = server.listen((request) async {
      requests.add(request.uri);
      request.response.headers.contentType = ContentType.json;
      final Object data;
      if (request.uri.path == '/api/networks') {
        data = [
          {
            'network_code': 'alpha network',
            'gateway': '10.26.0.1',
            'netmask': 24,
            'net': '10.26.0.0/24',
            'lease_duration': 86400,
            'source': 'database',
            'all_count': 2,
            'online_count': 1,
          },
        ];
      } else {
        data = [
          {
            'device_id': 'node-1',
            'device_name': 'Windows 节点',
            'device_version': '2.0.0',
            'ip': '10.26.0.2',
            'status': 'online',
            'last_connect_time': '2026-07-15T10:00:00Z',
            'disconnect_time': null,
            'latency_ms': 12,
            'server_addr': null,
            'tx_bytes': 1024,
            'rx_bytes': 2048,
          },
        ];
      }
      request.response.write(
        jsonEncode({'code': 200, 'msg': 'success', 'data': data}),
      );
      await request.response.close();
    });
    addTearDown(handling.cancel);

    final client = ApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
    );
    addTearDown(client.close);
    final repository = NetworkRepository(client);

    final networks = await repository.listNetworks();
    final devices = await repository.listDevices(networks.single.code);

    expect(networks.single.onlineDevices, 1);
    expect(devices.single.isOnline, isTrue);
    expect(devices.single.rxBytes, 2048);
    expect(requests.last.queryParameters['code'], 'alpha network');
  });
}

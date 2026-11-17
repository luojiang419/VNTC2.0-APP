import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/services/vnt_service_client.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

void main() {
  test('真实服务快照可供设备列表、聊天大厅和远程协助读取', () async {
    final root = Platform.environment['ProgramData']!;
    final json = jsonDecode(
            await File('$root/VNTC APP2.0/config/networks.json').readAsString())
        as Map;
    final configs = (json['configs'] as List)
        .map((raw) =>
            NetworkConfig.fromJson(Map<String, dynamic>.from(raw as Map)))
        .toList();
    final status = await VntServiceClient().getStatus();
    expect(status.isConnected, isTrue);
    expect(status.network, isNotEmpty);
    final manager = VntManager();
    manager.applySystemServiceStatus(status, configs);
    final box = manager.get(status.configKey);
    expect(box, isNotNull);
    expect(box!.currentDevice()['virtualIp'], status.virtualIp);
    expect(box.currentDevice()['virtualNetwork'], isNotEmpty);
    expect(box.currentDevice()['virtualNetmask'], isNotEmpty);
    expect(box.currentDevice()['connectServer'], isNotEmpty);
    final peers = box.peerDeviceList();
    expect(peers.length, (status.network['peers'] as List).length);
    // 本机验收网络须存在另一名在线用户，避免空列表误通过。
    final online =
        peers.where((p) => p.status.toLowerCase() == 'online').toList();
    expect(online, isNotEmpty);
    for (final peer in online) {
      expect(box.route(peer.virtualIp), isNotNull);
    }
    expect(box.p2pDiagnostics()['onlinePeerCount'], online.length);
    expect(box.getNetConfig()!.itemKey, status.configKey);
  },
      skip: !Platform.isWindows ||
          Platform.environment['VNT_LIVE_SERVICE_TEST'] != '1');
}

import 'dart:convert';
import 'dart:io';
import 'package:vnt_app/services/vnt_service_client.dart';

/// 只读诊断：不写配置、不重载服务、不输出口令或设备名称。
Future<void> main() async {
  final status = await VntServiceClient().getStatus();
  final network = status.network;
  final peers = (network['peers'] as List?) ?? const [];
  stdout.writeln(jsonEncode({
    'connected': status.isConnected,
    'hasNetworkSnapshot': network.isNotEmpty,
    'peerCount': peers.length,
    'onlinePeerCount': peers
        .where((p) =>
            (p['status'] ?? '').toString().trim().toLowerCase() == 'online')
        .length,
    'routeCount': (network['routes'] as List?)?.length ?? 0,
    'virtualIp': status.virtualIp,
  }));
}

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';

/// GUI 本地核心与 Windows 后台服务共用的连接读取契约。
abstract class VntConnection {
  NetworkConfig get networkConfig;
  NetworkConfig? getNetConfig();
  Future<void> close();
  bool isClosed();
  Map<String, dynamic> currentDevice();
  Map<String, dynamic> p2pDiagnostics();
  List<RustPeerClientInfo> peerDeviceList();
  List<(String, List<RustRoute>)> routeList();
  RustRoute? route(String ip);
  RustNatInfo? peerNatInfo(String ip);
  String upStream();
  String downStream();
  List<(String, BigInt, BigInt)> streamAll();
  Uint64List upStreamLine({required String ip});
  Uint64List downStreamLine({required String ip});
  String ipUpStreamTotal({required String ip});
  String ipDownStreamTotal({required String ip});
}

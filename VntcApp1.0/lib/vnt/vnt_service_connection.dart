import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/services/vnt_service_client.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'vnt_connection.dart';

/// 只读取服务快照，不在 GUI 中创建网络核心或第二张虚拟网卡。
class VntServiceConnection extends VntConnection {
  VntServiceConnection(this._status, this.networkConfig, this._disconnect);
  VntServiceStatus _status;
  @override
  NetworkConfig networkConfig;
  final Future<void> Function() _disconnect;
  bool _detached = false;
  void detach() => _detached = true;
  void update(VntServiceStatus status, NetworkConfig config) {
    _detached = false;
    _status = status;
    networkConfig = config;
  }

  Map<String, dynamic> get _network => _status.network;
  @override
  NetworkConfig getNetConfig() => networkConfig;
  @override
  Future<void> close() => _disconnect();
  @override
  bool isClosed() => _detached || !_status.isConnected;
  @override
  Map<String, dynamic> currentDevice() => {
        ..._object(_network['currentDevice']),
        'virtualIp': _status.virtualIp,
        'connectServer': _object(_network['currentDevice'])['connectServer'] ??
            _status.connectTarget,
        'status': _object(_network['currentDevice'])['status'] ??
            (_status.isConnected ? 'Online' : 'Offline'),
        ..._object(_network['natInfo']),
        'p2pDiagnostics': p2pDiagnostics(),
      };
  @override
  Map<String, dynamic> p2pDiagnostics() => _object(_network['diagnostics']);
  @override
  List<RustPeerClientInfo> peerDeviceList() =>
      _list(_network['peers']).map((raw) {
        final peer = _object(raw);
        return RustPeerClientInfo(
            virtualIp: _text(peer['virtualIp']),
            name: _text(peer['name']),
            status: _text(peer['status']),
            clientSecret: peer['clientSecret'] == true);
      }).toList(growable: false);
  @override
  List<(String, List<RustRoute>)> routeList() => _list(_network['routes'])
      .where((r) => r is List && r.length == 2)
      .map((r) => (
            _text(r[0]),
            _list(r[1]).map((raw) {
              final route = _object(raw);
              return RustRoute(
                  protocol: _text(route['protocol']),
                  addr: _text(route['addr']),
                  metric: _integer(route['metric']),
                  rt: _integer(route['rt']));
            }).toList(growable: false)
          ))
      .toList(growable: false);
  @override
  RustRoute? route(String ip) =>
      routeList().where((r) => r.$1 == ip).firstOrNull?.$2.firstOrNull;
  @override
  RustNatInfo? peerNatInfo(String ip) {
    final raw = _object(_network['peerNat'])[ip];
    if (raw is! Map) return null;
    final nat = _object(raw);
    return RustNatInfo(
        publicIps: _list(nat['publicIps']).map(_text).toList(),
        natType: _text(nat['natType']),
        localIpv4: nat['localIpv4'] as String?,
        ipv6: nat['ipv6'] as String?);
  }

  @override
  String upStream() => _text(_network['upStream']);
  @override
  String downStream() => _text(_network['downStream']);
  @override
  List<(String, BigInt, BigInt)> streamAll() => _list(_network['traffic'])
      .where((r) => r is List && r.length == 3)
      .map((r) => (_text(r[0]), _bigInt(r[1]), _bigInt(r[2])))
      .toList(growable: false);
  (String, BigInt, BigInt)? _traffic(String ip) =>
      streamAll().where((r) => r.$1 == ip).firstOrNull;
  @override
  Uint64List upStreamLine({required String ip}) {
    final row = _traffic(ip);
    return Uint64List.fromList(row == null ? [] : [row.$2.toInt()]);
  }

  @override
  Uint64List downStreamLine({required String ip}) {
    final row = _traffic(ip);
    return Uint64List.fromList(row == null ? [] : [row.$3.toInt()]);
  }

  @override
  String ipUpStreamTotal({required String ip}) =>
      '${_traffic(ip)?.$2 ?? BigInt.zero} B';
  @override
  String ipDownStreamTotal({required String ip}) =>
      '${_traffic(ip)?.$3 ?? BigInt.zero} B';
}

Map<String, dynamic> _object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<dynamic> _list(dynamic value) => value is List ? value : const [];
String _text(dynamic value) => value?.toString() ?? '';
int _integer(dynamic value) => int.tryParse(_text(value)) ?? 0;
BigInt _bigInt(dynamic value) => BigInt.tryParse(_text(value)) ?? BigInt.zero;

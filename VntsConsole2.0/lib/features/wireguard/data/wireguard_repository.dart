import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../networks/data/network_repository.dart';
import '../../networks/domain/network_models.dart';
import '../domain/wireguard_models.dart';

class WireGuardRepository {
  WireGuardRepository(this._client) : _networks = NetworkRepository(_client);

  final ApiClient _client;
  final NetworkRepository _networks;

  Future<List<NetworkInfo>> listNetworks() => _networks.listNetworks();

  Future<List<WireGuardPeer>> listPeers(String networkCode) async {
    final data = await _client.getObject(
      'wireguard/peers?${_query({'network_code': networkCode})}',
    );
    return _decodeList(data, WireGuardPeer.fromJson, 'WireGuard Peer');
  }

  Future<List<WireGuardPeerIp>> listPeerIps(String networkCode) async {
    final data = await _client.getObject(
      'wireguard/peer_ips?${_query({'network_code': networkCode})}',
    );
    return _decodeList(data, WireGuardPeerIp.fromJson, 'WireGuard IP');
  }

  Future<void> createPeer({
    required String networkCode,
    required String peerId,
    required String publicKey,
    required bool enabled,
  }) async {
    await _client.postObject('wireguard/peers', {
      'network_code': networkCode,
      'peer_id': peerId,
      'public_key': publicKey,
      'enabled': enabled,
    });
  }

  Future<GeneratedWireGuardConfig> generatePeer({
    required String networkCode,
    required String peerId,
  }) async {
    final data = await _client.postObject('wireguard/peers/generated', {
      'network_code': networkCode,
      'peer_id': peerId,
      'enabled': true,
    });
    try {
      return GeneratedWireGuardConfig.fromJson(
        Map<String, Object?>.from(data as Map),
      );
    } on (TypeError, FormatException) {
      throw const ApiException(
        ApiErrorKind.invalidResponse,
        '一次性 WireGuard 配置响应无效',
      );
    }
  }

  Future<void> setEnabled({
    required String networkCode,
    required String peerId,
    required bool enabled,
  }) async {
    await _client.putObject('wireguard/peers/enabled', {
      'network_code': networkCode,
      'peer_id': peerId,
      'enabled': enabled,
    });
  }

  Future<void> deletePeer(String networkCode, String peerId) async {
    await _client.deleteObject(
      'wireguard/peers?${_query({'network_code': networkCode, 'peer_id': peerId})}',
    );
  }

  Future<void> reserveIp({
    required String networkCode,
    required String peerId,
    required String ip,
  }) async {
    await _client.putObject('wireguard/peer_ips', {
      'network_code': networkCode,
      'peer_id': peerId,
      'ip': ip,
    });
  }

  Future<void> releaseIp(String networkCode, String peerId) async {
    await _client.deleteObject(
      'wireguard/peer_ips?${_query({'network_code': networkCode, 'peer_id': peerId})}',
    );
  }

  static String _query(Map<String, String> values) {
    return Uri(queryParameters: values).query;
  }
}

List<T> _decodeList<T>(
  Object? data,
  T Function(Map<String, Object?>) decode,
  String label,
) {
  if (data is! List) {
    throw ApiException(ApiErrorKind.invalidResponse, '$label 列表响应无效');
  }
  try {
    return data
        .map((item) => decode(Map<String, Object?>.from(item as Map)))
        .toList(growable: false);
  } on (TypeError, FormatException) {
    throw ApiException(ApiErrorKind.invalidResponse, '$label 列表字段无效');
  }
}

import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../domain/peer_server_models.dart';

class PeerServerRepository {
  const PeerServerRepository(this._client);

  final ApiClient _client;

  Future<PeerServerSnapshot> list() async {
    final data = await _client.getObject('peer_servers');
    try {
      return PeerServerSnapshot.fromJson(
        Map<String, Object?>.from(data as Map),
      );
    } on (TypeError, FormatException) {
      throw const ApiException(ApiErrorKind.invalidResponse, '互联服务器列表响应无效');
    }
  }

  Future<void> add(String address) async {
    await _client.postObject('peer_servers', {'server_addr': address});
  }

  Future<void> delete(String address) async {
    await _client.deleteObject('peer_servers/${Uri.encodeComponent(address)}');
  }
}

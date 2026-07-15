import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../domain/network_models.dart';

class NetworkRepository {
  const NetworkRepository(this._client);

  final ApiClient _client;

  Future<List<NetworkInfo>> listNetworks() async {
    final data = await _client.getObject('networks');
    return _decodeList(data, NetworkInfo.fromJson, '网络');
  }

  Future<void> createNetwork({
    required String code,
    required String gateway,
    required int netmask,
    required int leaseDurationSeconds,
  }) async {
    await _client.postObject('networks', {
      'network_code': code,
      'gateway': gateway,
      'netmask': netmask,
      'lease_duration': leaseDurationSeconds,
    });
  }

  Future<void> updateNetwork({
    required String code,
    required String gateway,
    required int netmask,
    required int leaseDurationSeconds,
  }) async {
    await _client.putObject('networks/${Uri.encodeComponent(code)}', {
      'gateway': gateway,
      'netmask': netmask,
      'lease_duration': leaseDurationSeconds,
    });
  }

  Future<void> deleteNetwork(String code) async {
    await _client.deleteObject('networks/${Uri.encodeComponent(code)}');
  }

  Future<List<DeviceInfo>> listDevices(String networkCode) async {
    final query = Uri(queryParameters: {'code': networkCode}).query;
    final data = await _client.getObject('devices?$query');
    return _decodeList(data, DeviceInfo.fromJson, '设备');
  }

  Future<void> deleteDevice(String networkCode, String deviceId) async {
    final query = Uri(
      queryParameters: {'code': networkCode, 'device_id': deviceId},
    ).query;
    await _client.deleteObject('devices?$query');
  }
}

List<T> _decodeList<T>(
  Object? data,
  T Function(Map<String, Object?>) decode,
  String label,
) {
  if (data is! List) {
    throw ApiException(ApiErrorKind.invalidResponse, '$label列表响应无效');
  }
  try {
    return data
        .map((item) => decode(Map<String, Object?>.from(item as Map)))
        .toList(growable: false);
  } on (TypeError, FormatException) {
    throw ApiException(ApiErrorKind.invalidResponse, '$label列表字段无效');
  }
}

class NetworkInfo {
  const NetworkInfo({
    required this.code,
    required this.gateway,
    required this.netmask,
    required this.network,
    required this.leaseDurationSeconds,
    required this.source,
    required this.totalDevices,
    required this.onlineDevices,
  });

  factory NetworkInfo.fromJson(Map<String, Object?> json) {
    return NetworkInfo(
      code: _string(json, 'network_code'),
      gateway: _string(json, 'gateway'),
      netmask: _integer(json, 'netmask'),
      network: _string(json, 'net'),
      leaseDurationSeconds: _integer(json, 'lease_duration'),
      source: json['source']?.toString() ?? 'unknown',
      totalDevices: _integer(json, 'all_count'),
      onlineDevices: _integer(json, 'online_count'),
    );
  }

  final String code;
  final String gateway;
  final int netmask;
  final String network;
  final int leaseDurationSeconds;
  final String source;
  final int totalDevices;
  final int onlineDevices;
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.ip,
    required this.status,
    required this.lastConnectedAt,
    required this.disconnectedAt,
    required this.latencyMs,
    required this.serverAddress,
    required this.txBytes,
    required this.rxBytes,
  });

  factory DeviceInfo.fromJson(Map<String, Object?> json) {
    return DeviceInfo(
      id: _string(json, 'device_id'),
      name: _string(json, 'device_name'),
      version: _string(json, 'device_version'),
      ip: json['ip'] as String?,
      status: _string(json, 'status'),
      lastConnectedAt: _string(json, 'last_connect_time'),
      disconnectedAt: json['disconnect_time'] as String?,
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      serverAddress: json['server_addr'] as String?,
      txBytes: _integer(json, 'tx_bytes'),
      rxBytes: _integer(json, 'rx_bytes'),
    );
  }

  final String id;
  final String name;
  final String version;
  final String? ip;
  final String status;
  final String lastConnectedAt;
  final String? disconnectedAt;
  final int? latencyMs;
  final String? serverAddress;
  final int txBytes;
  final int rxBytes;

  bool get isOnline => status.toLowerCase() == 'online';
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('字段 $key 不是字符串');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  throw FormatException('字段 $key 不是整数');
}

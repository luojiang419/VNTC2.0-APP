class WireGuardPeer {
  const WireGuardPeer({
    required this.networkCode,
    required this.peerId,
    required this.publicKey,
    required this.enabled,
    required this.ip,
    required this.createdAt,
    required this.updatedAt,
  });

  factory WireGuardPeer.fromJson(Map<String, Object?> json) {
    return WireGuardPeer(
      networkCode: _string(json, 'network_code'),
      peerId: _string(json, 'peer_id'),
      publicKey: _string(json, 'public_key'),
      enabled: _boolean(json, 'enabled'),
      ip: json['ip'] as String?,
      createdAt: _integer(json, 'created_at'),
      updatedAt: _integer(json, 'updated_at'),
    );
  }

  final String networkCode;
  final String peerId;
  final String publicKey;
  final bool enabled;
  final String? ip;
  final int createdAt;
  final int updatedAt;
}

class WireGuardPeerIp {
  const WireGuardPeerIp({required this.peerId, required this.ip});

  factory WireGuardPeerIp.fromJson(Map<String, Object?> json) {
    return WireGuardPeerIp(
      peerId: _string(json, 'peer_id'),
      ip: _string(json, 'ip'),
    );
  }

  final String peerId;
  final String ip;
}

class GeneratedWireGuardConfig {
  const GeneratedWireGuardConfig({
    required this.peer,
    required this.privateKey,
    required this.serverPublicKey,
    required this.endpoint,
    required this.allowedIps,
  });

  factory GeneratedWireGuardConfig.fromJson(Map<String, Object?> json) {
    return GeneratedWireGuardConfig(
      peer: WireGuardPeer.fromJson(
        Map<String, Object?>.from(json['peer'] as Map),
      ),
      privateKey: _string(json, 'private_key'),
      serverPublicKey: _string(json, 'server_public_key'),
      endpoint: _string(json, 'endpoint'),
      allowedIps: _string(json, 'allowed_ips'),
    );
  }

  final WireGuardPeer peer;
  final String privateKey;
  final String serverPublicKey;
  final String endpoint;
  final String allowedIps;

  String get clientConfig {
    final address = peer.ip == null ? '' : '${peer.ip}/32';
    return '[Interface]\n'
        'PrivateKey = $privateKey\n'
        'Address = $address\n\n'
        '[Peer]\n'
        'PublicKey = $serverPublicKey\n'
        'Endpoint = $endpoint\n'
        'AllowedIPs = $allowedIps\n'
        'PersistentKeepalive = 25\n';
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('字段 $key 不是字符串');
}

bool _boolean(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('字段 $key 不是布尔值');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  throw FormatException('字段 $key 不是整数');
}

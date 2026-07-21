class WireGuardPeer {
  const WireGuardPeer({
    required this.networkCode,
    required this.peerId,
    required this.publicKey,
    required this.enabled,
    required this.ip,
    required this.createdAt,
    required this.updatedAt,
    required this.dnsServers,
    required this.dnsInherited,
    required this.persistentKeepalive,
    required this.routes,
    required this.configAvailable,
    required this.online,
    required this.status,
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
      dnsServers: _stringList(json['dns_servers']),
      dnsInherited: _optionalBoolean(json, 'dns_inherited', true),
      persistentKeepalive: _optionalInteger(json, 'persistent_keepalive', 25),
      routes: _routes(json['routes']),
      configAvailable: _optionalBoolean(json, 'config_available', false),
      online: _optionalBoolean(json, 'online', false),
      status:
          json['status'] as String? ??
          (_boolean(json, 'enabled') ? 'offline' : 'disabled'),
    );
  }

  final String networkCode;
  final String peerId;
  final String publicKey;
  final bool enabled;
  final String? ip;
  final int createdAt;
  final int updatedAt;
  final List<String> dnsServers;
  final bool dnsInherited;
  final int persistentKeepalive;
  final List<WireGuardRoute> routes;
  final bool configAvailable;
  final bool online;
  final String status;

  WireGuardPeerProfile get profile => WireGuardPeerProfile(
    dnsServers: dnsInherited ? null : dnsServers,
    persistentKeepalive: persistentKeepalive,
    routes: routes,
  );
}

class WireGuardRoute {
  const WireGuardRoute({required this.lanNetwork, required this.vntClientIp});

  factory WireGuardRoute.fromJson(Map<String, Object?> json) {
    return WireGuardRoute(
      lanNetwork: _string(json, 'lan_network'),
      vntClientIp: _string(json, 'vnt_cli_ip'),
    );
  }

  final String lanNetwork;
  final String vntClientIp;

  Map<String, Object?> toJson() => {
    'lan_network': lanNetwork,
    'vnt_cli_ip': vntClientIp,
  };
}

class WireGuardPeerProfile {
  const WireGuardPeerProfile({
    this.dnsServers,
    this.persistentKeepalive = 25,
    this.routes = const [],
  });

  final List<String>? dnsServers;
  final int persistentKeepalive;
  final List<WireGuardRoute> routes;

  Map<String, Object?> toJson() => {
    'dns_servers': dnsServers,
    'persistent_keepalive': persistentKeepalive,
    'routes': routes.map((route) => route.toJson()).toList(growable: false),
  };
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
    required this.dnsServers,
    required this.persistentKeepalive,
    required this.routes,
    required this.serverClientConfig,
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
      dnsServers: _stringList(json['dns_servers']),
      persistentKeepalive: _optionalInteger(json, 'persistent_keepalive', 25),
      routes: _routes(json['routes']),
      serverClientConfig: json['client_config'] as String?,
    );
  }

  final WireGuardPeer peer;
  final String privateKey;
  final String serverPublicKey;
  final String endpoint;
  final String allowedIps;
  final List<String> dnsServers;
  final int persistentKeepalive;
  final List<WireGuardRoute> routes;
  final String? serverClientConfig;

  String get clientConfig {
    if (serverClientConfig?.isNotEmpty ?? false) return serverClientConfig!;
    final address = peer.ip == null ? '' : '${peer.ip}/32';
    final dnsLine = dnsServers.isEmpty
        ? ''
        : 'DNS = ${dnsServers.join(', ')}\n';
    return '[Interface]\n'
        'PrivateKey = $privateKey\n'
        'Address = $address\n'
        '$dnsLine\n'
        '[Peer]\n'
        'PublicKey = $serverPublicKey\n'
        'Endpoint = $endpoint\n'
        'AllowedIPs = $allowedIps\n'
        'PersistentKeepalive = $persistentKeepalive\n';
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

int _optionalInteger(Map<String, Object?> json, String key, int fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is num) return value.toInt();
  throw FormatException('字段 $key 不是整数');
}

bool _optionalBoolean(Map<String, Object?> json, String key, bool fallback) {
  final value = json[key];
  if (value == null) return fallback;
  if (value is bool) return value;
  throw FormatException('字段 $key 不是布尔值');
}

List<String> _stringList(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('字段不是字符串列表');
  return value
      .map((item) {
        if (item is String) return item;
        throw const FormatException('列表元素不是字符串');
      })
      .toList(growable: false);
}

List<WireGuardRoute> _routes(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('routes 不是列表');
  return value
      .map(
        (item) =>
            WireGuardRoute.fromJson(Map<String, Object?>.from(item as Map)),
      )
      .toList(growable: false);
}

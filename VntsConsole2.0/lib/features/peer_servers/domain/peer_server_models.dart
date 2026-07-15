class PeerServerInfo {
  const PeerServerInfo({
    required this.address,
    required this.latencyMs,
    required this.connected,
    required this.outbound,
  });

  factory PeerServerInfo.fromJson(Map<String, Object?> json) {
    final address = json['addr'];
    final latency = json['latency_ms'];
    final connected = json['connected'];
    final outbound = json['is_outbound'];
    if (address is! String ||
        latency is! num ||
        connected is! bool ||
        outbound is! bool) {
      throw const FormatException('互联服务器字段无效');
    }
    return PeerServerInfo(
      address: address,
      latencyMs: latency.toInt(),
      connected: connected,
      outbound: outbound,
    );
  }

  final String address;
  final int latencyMs;
  final bool connected;
  final bool outbound;
}

class PeerServerSnapshot {
  const PeerServerSnapshot({required this.outbound, required this.inbound});

  factory PeerServerSnapshot.fromJson(Map<String, Object?> json) {
    return PeerServerSnapshot(
      outbound: _list(json['outbound']),
      inbound: _list(json['inbound']),
    );
  }

  final List<PeerServerInfo> outbound;
  final List<PeerServerInfo> inbound;

  List<PeerServerInfo> get all => [...outbound, ...inbound];

  static List<PeerServerInfo> _list(Object? value) {
    if (value is! List) throw const FormatException('互联服务器列表无效');
    return value
        .map(
          (item) =>
              PeerServerInfo.fromJson(Map<String, Object?>.from(item as Map)),
        )
        .toList(growable: false);
  }
}

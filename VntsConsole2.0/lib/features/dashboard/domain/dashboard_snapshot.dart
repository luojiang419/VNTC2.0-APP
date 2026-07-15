class DashboardSnapshot {
  const DashboardSnapshot({
    required this.sampledAt,
    required this.server,
    required this.listeners,
    required this.host,
    required this.process,
    required this.storage,
    required this.traffic,
    required this.topology,
    required this.peerServers,
    required this.wireGuard,
  });

  final DateTime sampledAt;
  final DashboardServer server;
  final DashboardListeners listeners;
  final DashboardHost host;
  final DashboardProcess process;
  final DashboardStorage storage;
  final DashboardTraffic traffic;
  final DashboardTopology topology;
  final DashboardPeerServers peerServers;
  final DashboardWireGuard wireGuard;

  factory DashboardSnapshot.fromJson(Map<String, Object?> json) {
    return DashboardSnapshot(
      sampledAt: DateTime.fromMillisecondsSinceEpoch(
        _integer(json, 'sampled_at_ms'),
      ),
      server: DashboardServer.fromJson(_map(json, 'server')),
      listeners: DashboardListeners.fromJson(_map(json, 'listeners')),
      host: DashboardHost.fromJson(_map(json, 'host')),
      process: DashboardProcess.fromJson(_map(json, 'process')),
      storage: DashboardStorage.fromJson(_map(json, 'storage')),
      traffic: DashboardTraffic.fromJson(_map(json, 'traffic')),
      topology: DashboardTopology.fromJson(_map(json, 'topology')),
      peerServers: DashboardPeerServers.fromJson(_map(json, 'peer_servers')),
      wireGuard: DashboardWireGuard.fromJson(_map(json, 'wireguard')),
    );
  }
}

class DashboardServer {
  const DashboardServer({
    required this.version,
    required this.uptimeSeconds,
    required this.persistenceEnabled,
    required this.databaseReady,
  });

  final String version;
  final int uptimeSeconds;
  final bool persistenceEnabled;
  final bool databaseReady;

  factory DashboardServer.fromJson(Map<String, Object?> json) =>
      DashboardServer(
        version: _string(json, 'version'),
        uptimeSeconds: _integer(json, 'uptime_seconds'),
        persistenceEnabled: _boolean(json, 'persistence_enabled'),
        databaseReady: _boolean(json, 'database_ready'),
      );
}

class DashboardListeners {
  const DashboardListeners({
    required this.web,
    required this.vntTcp,
    required this.vntQuic,
    required this.vntWebSocket,
    required this.peerServerQuic,
    required this.wireGuardUdp,
  });

  final bool web;
  final bool vntTcp;
  final bool vntQuic;
  final bool vntWebSocket;
  final bool peerServerQuic;
  final bool wireGuardUdp;

  factory DashboardListeners.fromJson(Map<String, Object?> json) =>
      DashboardListeners(
        web: _boolean(json, 'web'),
        vntTcp: _boolean(json, 'vnt_tcp'),
        vntQuic: _boolean(json, 'vnt_quic'),
        vntWebSocket: _boolean(json, 'vnt_websocket'),
        peerServerQuic: _boolean(json, 'peer_server_quic'),
        wireGuardUdp: _boolean(json, 'wireguard_udp'),
      );

  Map<String, bool> get labeled => {
    'Web': web,
    'VNT TCP': vntTcp,
    'VNT QUIC': vntQuic,
    'WebSocket': vntWebSocket,
    'Peer QUIC': peerServerQuic,
    'WireGuard UDP': wireGuardUdp,
  };
}

class DashboardHost {
  const DashboardHost({
    required this.cpuPercent,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
  });

  final double? cpuPercent;
  final int memoryUsedBytes;
  final int memoryTotalBytes;

  factory DashboardHost.fromJson(Map<String, Object?> json) => DashboardHost(
    cpuPercent: _nullableDouble(json, 'cpu_percent'),
    memoryUsedBytes: _integer(json, 'memory_used_bytes'),
    memoryTotalBytes: _integer(json, 'memory_total_bytes'),
  );
}

class DashboardProcess {
  const DashboardProcess({
    required this.cpuPercent,
    required this.memoryBytes,
    required this.threads,
    required this.handles,
  });

  final double? cpuPercent;
  final int memoryBytes;
  final int? threads;
  final int? handles;

  factory DashboardProcess.fromJson(Map<String, Object?> json) =>
      DashboardProcess(
        cpuPercent: _nullableDouble(json, 'cpu_percent'),
        memoryBytes: _integer(json, 'memory_bytes'),
        threads: _nullableInteger(json, 'threads'),
        handles: _nullableInteger(json, 'handles'),
      );
}

class DashboardStorage {
  const DashboardStorage({
    required this.volumeUsedBytes,
    required this.volumeTotalBytes,
    required this.dataBytes,
    required this.databaseBytes,
    required this.logsBytes,
  });

  final int? volumeUsedBytes;
  final int? volumeTotalBytes;
  final int? dataBytes;
  final int? databaseBytes;
  final int? logsBytes;

  factory DashboardStorage.fromJson(Map<String, Object?> json) =>
      DashboardStorage(
        volumeUsedBytes: _nullableInteger(json, 'volume_used_bytes'),
        volumeTotalBytes: _nullableInteger(json, 'volume_total_bytes'),
        dataBytes: _nullableInteger(json, 'data_bytes'),
        databaseBytes: _nullableInteger(json, 'database_bytes'),
        logsBytes: _nullableInteger(json, 'logs_bytes'),
      );
}

class DashboardTraffic {
  const DashboardTraffic({
    required this.txBytesTotal,
    required this.rxBytesTotal,
    required this.wireGuardDropsTotal,
  });

  final int txBytesTotal;
  final int rxBytesTotal;
  final int wireGuardDropsTotal;

  factory DashboardTraffic.fromJson(Map<String, Object?> json) =>
      DashboardTraffic(
        txBytesTotal: _integer(json, 'tx_bytes_total'),
        rxBytesTotal: _integer(json, 'rx_bytes_total'),
        wireGuardDropsTotal: _integer(json, 'wireguard_drops_total'),
      );
}

class DashboardTopology {
  const DashboardTopology({
    required this.networks,
    required this.nodesTotal,
    required this.nodesOnline,
    required this.nodesOffline,
    required this.vntOnline,
    required this.wireGuardOnline,
  });

  final int networks;
  final int nodesTotal;
  final int nodesOnline;
  final int nodesOffline;
  final int vntOnline;
  final int wireGuardOnline;

  factory DashboardTopology.fromJson(Map<String, Object?> json) =>
      DashboardTopology(
        networks: _integer(json, 'networks'),
        nodesTotal: _integer(json, 'nodes_total'),
        nodesOnline: _integer(json, 'nodes_online'),
        nodesOffline: _integer(json, 'nodes_offline'),
        vntOnline: _integer(json, 'vnt_online'),
        wireGuardOnline: _integer(json, 'wireguard_online'),
      );
}

class DashboardPeerServers {
  const DashboardPeerServers({
    required this.enabled,
    required this.total,
    required this.connected,
  });

  final bool enabled;
  final int total;
  final int connected;

  factory DashboardPeerServers.fromJson(Map<String, Object?> json) =>
      DashboardPeerServers(
        enabled: _boolean(json, 'enabled'),
        total: _integer(json, 'total'),
        connected: _integer(json, 'connected'),
      );
}

class DashboardWireGuard {
  const DashboardWireGuard({
    required this.configured,
    required this.running,
    required this.activePeers,
    required this.maxActivePeers,
  });

  final bool configured;
  final bool running;
  final int activePeers;
  final int maxActivePeers;

  factory DashboardWireGuard.fromJson(Map<String, Object?> json) =>
      DashboardWireGuard(
        configured: _boolean(json, 'configured'),
        running: _boolean(json, 'running'),
        activePeers: _integer(json, 'active_peers'),
        maxActivePeers: _integer(json, 'max_active_peers'),
      );
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) return value;
  throw FormatException('$key 必须是对象');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key 必须是字符串');
}

bool _boolean(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key 必须是布尔值');
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value >= 0) return value;
  throw FormatException('$key 必须是非负整数');
}

int? _nullableInteger(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _integer(json, key);
}

double? _nullableDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is num && value.isFinite && value >= 0) return value.toDouble();
  throw FormatException('$key 必须是非负数或 null');
}

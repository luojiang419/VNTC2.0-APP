import 'package:vnts_console/features/dashboard/domain/dashboard_snapshot.dart';

Map<String, Object?> dashboardJson({
  int sampledAtMs = 1000,
  int txBytes = 1000,
  int rxBytes = 2000,
}) => {
  'sampled_at_ms': sampledAtMs,
  'server': {
    'version': '2.0.0',
    'uptime_seconds': 3660,
    'persistence_enabled': true,
    'database_ready': true,
  },
  'listeners': {
    'web': true,
    'vnt_tcp': true,
    'vnt_quic': true,
    'vnt_websocket': true,
    'peer_server_quic': false,
    'wireguard_udp': true,
  },
  'host': {
    'cpu_percent': 12.5,
    'memory_used_bytes': 4 * 1024 * 1024 * 1024,
    'memory_total_bytes': 16 * 1024 * 1024 * 1024,
  },
  'process': {
    'cpu_percent': 2.5,
    'memory_bytes': 128 * 1024 * 1024,
    'threads': null,
    'handles': null,
  },
  'storage': {
    'volume_used_bytes': 100 * 1024 * 1024 * 1024,
    'volume_total_bytes': 500 * 1024 * 1024 * 1024,
    'data_bytes': 1024,
    'database_bytes': 512,
    'logs_bytes': 256,
  },
  'traffic': {
    'tx_bytes_total': txBytes,
    'rx_bytes_total': rxBytes,
    'wireguard_drops_total': 0,
  },
  'topology': {
    'networks': 2,
    'nodes_total': 5,
    'nodes_online': 4,
    'nodes_offline': 1,
    'vnt_online': 3,
    'wireguard_online': 1,
  },
  'peer_servers': {'enabled': true, 'total': 2, 'connected': 2},
  'wireguard': {
    'configured': true,
    'running': true,
    'active_peers': 1,
    'max_active_peers': 4096,
  },
};

DashboardSnapshot dashboardSnapshot({
  int sampledAtMs = 1000,
  int txBytes = 1000,
  int rxBytes = 2000,
}) => DashboardSnapshot.fromJson(
  dashboardJson(sampledAtMs: sampledAtMs, txBytes: txBytes, rxBytes: rxBytes),
);

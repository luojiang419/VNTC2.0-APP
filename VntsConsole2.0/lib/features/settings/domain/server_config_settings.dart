class ServerConfigSettings {
  const ServerConfigSettings({
    required this.tcpBind,
    required this.quicBind,
    required this.webSocketBind,
    required this.network,
    required this.whiteList,
    required this.leaseDurationSeconds,
    required this.persistence,
    required this.webEnabled,
    required this.webBind,
    required this.username,
    required this.hasPassword,
    required this.certificateFile,
    required this.privateKeyFile,
    required this.wireGuardEnabled,
    required this.wireGuardMasterKeyFile,
    required this.wireGuardBind,
    required this.wireGuardPublicEndpoint,
    required this.wireGuardMaxActivePeers,
    required this.serverQuicEnabled,
    required this.serverQuicBind,
    required this.peerServerCount,
    required this.hasServerToken,
  });

  final String tcpBind;
  final String quicBind;
  final String webSocketBind;
  final String network;
  final List<String> whiteList;
  final int leaseDurationSeconds;
  final bool persistence;
  final bool webEnabled;
  final String webBind;
  final String username;
  final bool hasPassword;
  final String certificateFile;
  final String privateKeyFile;
  final bool wireGuardEnabled;
  final String wireGuardMasterKeyFile;
  final String wireGuardBind;
  final String wireGuardPublicEndpoint;
  final int wireGuardMaxActivePeers;
  final bool serverQuicEnabled;
  final String serverQuicBind;
  final int peerServerCount;
  final bool hasServerToken;

  ServerConfigSettings copyWith({
    String? tcpBind,
    String? quicBind,
    String? webSocketBind,
    String? network,
    List<String>? whiteList,
    int? leaseDurationSeconds,
    bool? persistence,
    bool? webEnabled,
    String? webBind,
    String? username,
    bool? hasPassword,
    String? certificateFile,
    String? privateKeyFile,
    bool? wireGuardEnabled,
    String? wireGuardMasterKeyFile,
    String? wireGuardBind,
    String? wireGuardPublicEndpoint,
    int? wireGuardMaxActivePeers,
    bool? serverQuicEnabled,
    String? serverQuicBind,
    int? peerServerCount,
    bool? hasServerToken,
  }) {
    return ServerConfigSettings(
      tcpBind: tcpBind ?? this.tcpBind,
      quicBind: quicBind ?? this.quicBind,
      webSocketBind: webSocketBind ?? this.webSocketBind,
      network: network ?? this.network,
      whiteList: whiteList ?? this.whiteList,
      leaseDurationSeconds: leaseDurationSeconds ?? this.leaseDurationSeconds,
      persistence: persistence ?? this.persistence,
      webEnabled: webEnabled ?? this.webEnabled,
      webBind: webBind ?? this.webBind,
      username: username ?? this.username,
      hasPassword: hasPassword ?? this.hasPassword,
      certificateFile: certificateFile ?? this.certificateFile,
      privateKeyFile: privateKeyFile ?? this.privateKeyFile,
      wireGuardEnabled: wireGuardEnabled ?? this.wireGuardEnabled,
      wireGuardMasterKeyFile:
          wireGuardMasterKeyFile ?? this.wireGuardMasterKeyFile,
      wireGuardBind: wireGuardBind ?? this.wireGuardBind,
      wireGuardPublicEndpoint:
          wireGuardPublicEndpoint ?? this.wireGuardPublicEndpoint,
      wireGuardMaxActivePeers:
          wireGuardMaxActivePeers ?? this.wireGuardMaxActivePeers,
      serverQuicEnabled: serverQuicEnabled ?? this.serverQuicEnabled,
      serverQuicBind: serverQuicBind ?? this.serverQuicBind,
      peerServerCount: peerServerCount ?? this.peerServerCount,
      hasServerToken: hasServerToken ?? this.hasServerToken,
    );
  }
}

class ConfigValidationException implements Exception {
  const ConfigValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

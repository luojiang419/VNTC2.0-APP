import 'dart:convert';

class NetworkConfig {
  String itemKey;
  String configName;
  String token;
  String deviceName;
  String virtualIPv4;
  String serverAddress;
  List<String> serverList;
  List<String> stunServers;
  List<String> udpStun;
  List<String> tcpStun;
  List<String> inIps;
  List<String> outIps;
  List<String> portMappings;
  String groupPassword;
  bool isServerEncrypted;
  String protocol;
  bool dataFingerprintVerification;
  String encryptionAlgorithm;
  String deviceID;
  String virtualNetworkCardName;
  String certMode;
  int ctrlPort;
  int mtu;
  List<int> ports;
  bool firstLatency;
  bool noInIpProxy;
  bool rtx;
  bool compress;
  bool fec;
  bool noPunch;
  bool noNat;
  bool noTun;
  bool allowMapping;
  int tunnelPort;
  List<String> dns;
  double simulatedPacketLossRate;
  int simulatedLatency;
  String punchModel;
  String useChannelType;
  String compressor;
  bool allowWg;
  String localDev;
  String localIpv4;
  bool disableRelay;
  String updatedAt;

  NetworkConfig({
    required this.itemKey,
    required this.configName,
    required this.token,
    required this.deviceName,
    required this.virtualIPv4,
    required this.serverAddress,
    List<String>? serverList,
    List<String>? stunServers,
    List<String>? udpStun,
    List<String>? tcpStun,
    List<String>? inIps,
    List<String>? outIps,
    List<String>? portMappings,
    required this.groupPassword,
    required this.isServerEncrypted,
    required this.protocol,
    required this.dataFingerprintVerification,
    required this.encryptionAlgorithm,
    required this.deviceID,
    required this.virtualNetworkCardName,
    this.certMode = 'skip',
    this.ctrlPort = 21233,
    required this.mtu,
    List<int>? ports,
    required this.firstLatency,
    required this.noInIpProxy,
    this.rtx = false,
    this.compress = false,
    this.fec = false,
    this.noPunch = false,
    this.noNat = false,
    this.noTun = false,
    bool? allowMapping,
    this.tunnelPort = 0,
    List<String>? dns,
    required this.simulatedPacketLossRate,
    required this.simulatedLatency,
    required this.punchModel,
    required this.useChannelType,
    required this.compressor,
    required this.allowWg,
    this.localDev = '',
    this.localIpv4 = '',
    this.disableRelay = false,
    this.updatedAt = '',
  })  : serverList = List<String>.from(serverList ?? const []),
        stunServers = List<String>.from(stunServers ?? const []),
        udpStun = List<String>.from(udpStun ?? const []),
        tcpStun = List<String>.from(tcpStun ?? const []),
        inIps = List<String>.from(inIps ?? const []),
        outIps = List<String>.from(outIps ?? const []),
        portMappings = List<String>.from(portMappings ?? const []),
        ports = List<int>.from(ports ?? const []),
        allowMapping = allowMapping ?? ((portMappings?.isNotEmpty) ?? false),
        dns = List<String>.from(dns ?? const []) {
    if (this.serverList.isEmpty && serverAddress.isNotEmpty) {
      this.serverList = [serverAddress];
    }
    if (this.serverAddress.isEmpty && this.serverList.isNotEmpty) {
      this.serverAddress = this.serverList.first;
    }
    if (this.udpStun.isEmpty && this.stunServers.isNotEmpty) {
      this.udpStun = List<String>.from(this.stunServers);
    }
    if (this.compress == false && compressor == 'lz4') {
      this.compress = true;
    }
  }

  String get primaryServerAddress {
    if (serverList.isNotEmpty) {
      return serverList.first;
    }
    return serverAddress;
  }

  String get normalizedProtocol {
    return _normalizeProtocol(protocol, primaryServerAddress);
  }

  String get effectiveCertMode {
    final normalized = certMode.trim();
    if (normalized.isEmpty) {
      return 'skip';
    }
    if (normalized == 'skip' || normalized == 'standard') {
      return normalized;
    }
    if (normalized.startsWith('finger:')) {
      return normalized;
    }
    return 'skip';
  }

  String get v2CompatiblePrimaryServerAddress {
    return _normalizeServerAddress(
      primaryServerAddress,
      fallbackProtocol: normalizedProtocol,
    );
  }

  List<String> get v2CompatibleServerList {
    final source = effectiveServerList;
    if (source.isEmpty) {
      return const [];
    }
    return source
        .map(
          (address) => _normalizeServerAddress(
            address,
            fallbackProtocol: normalizedProtocol,
          ),
        )
        .toList(growable: false);
  }

  String get bridgeCipherModelPayload {
    return '__vnt_bridge_json__=${jsonEncode({
      'cert_mode': effectiveCertMode,
      'cipher_model': encryptionAlgorithm,
      'rtx': rtx,
      'fec': fec,
      'no_tun': noTun,
      'allow_mapping': allowMapping,
      'udp_stun': effectiveUdpStun,
      'tcp_stun': effectiveTcpStun,
      if (tunnelPort > 0) 'tunnel_port': tunnelPort,
    })}';
  }

  String? get bridgeLocalIpv4 {
    final ipv4 = resolvedLocalBindIpv4;
    return ipv4.isEmpty ? null : ipv4;
  }

  bool get coreNoProxy => noNat || noInIpProxy;

  String get coreUseChannelType {
    if (noPunch) {
      return 'relay';
    }
    if (disableRelay) {
      return 'p2p';
    }
    return useChannelType;
  }

  String get coreCompressor {
    if (compress) {
      return 'lz4';
    }
    return compressor.isEmpty ? 'none' : compressor;
  }

  String get resolvedLocalBindIpv4 {
    final normalizedLocalIpv4 = localIpv4.trim();
    if (_looksLikeIpv4(normalizedLocalIpv4)) {
      return normalizedLocalIpv4;
    }
    final legacyLocalDev = localDev.trim();
    if (_looksLikeIpv4(legacyLocalDev)) {
      return legacyLocalDev;
    }
    return '';
  }

  String get resolvedLocalBinding {
    final normalizedLocalIpv4 = localIpv4.trim();
    if (normalizedLocalIpv4.isNotEmpty) {
      return normalizedLocalIpv4;
    }
    return localDev.trim();
  }

  List<String> get effectiveServerList {
    if (serverList.isNotEmpty) {
      return List<String>.from(serverList);
    }
    if (serverAddress.isNotEmpty) {
      return [serverAddress];
    }
    return const [];
  }

  List<String> get effectiveUdpStun {
    if (udpStun.isNotEmpty) {
      return List<String>.from(udpStun);
    }
    return List<String>.from(stunServers);
  }

  List<String> get effectiveTcpStun {
    if (tcpStun.isNotEmpty) {
      return List<String>.from(tcpStun);
    }
    return List<String>.from(effectiveUdpStun);
  }

  Map<String, dynamic> toJson() {
    return {
      'itemKey': itemKey,
      'network_code': token,
      'config_name': configName,
      'token': token,
      'name': deviceName,
      'display_device_name': deviceName,
      'ip': virtualIPv4,
      'server_address': serverAddress,
      'server': effectiveServerList,
      'stun_server': stunServers,
      'udp_stun': udpStun,
      'tcp_stun': tcpStun,
      'in_ips': inIps,
      'input': inIps,
      'out_ips': outIps,
      'output': outIps,
      'mapping': portMappings,
      'port_mapping': portMappings,
      'password': groupPassword,
      'server_encrypt': isServerEncrypted,
      'protocol': protocol,
      'finger': dataFingerprintVerification,
      'cipher_model': encryptionAlgorithm,
      'device_id': deviceID,
      'device_name': virtualNetworkCardName,
      'tun_name': virtualNetworkCardName,
      'cert_mode': certMode,
      'ctrl_port': ctrlPort,
      'mtu': mtu,
      'ports': ports,
      'first_latency': firstLatency,
      'no_proxy': noInIpProxy,
      'rtx': rtx,
      'compress': compress,
      'fec': fec,
      'no_punch': noPunch,
      'no_nat': noNat,
      'no_tun': noTun,
      'allow_mapping': allowMapping,
      'tunnel_port': tunnelPort,
      'dns': dns,
      'packet_loss': simulatedPacketLossRate,
      'packet_delay': simulatedLatency,
      'punch_model': punchModel,
      'use_channel': useChannelType,
      'compressor': compressor,
      'allow_wire_guard': allowWg,
      'local_dev': localDev,
      'local_ipv4': localIpv4,
      'disable_relay': disableRelay,
      'updated_at': updatedAt,
    };
  }

  Map<String, dynamic> toJsonSimple() {
    return {
      if (configName.isNotEmpty) 'config_name': configName,
      if (token.isNotEmpty) 'network_code': token,
      if (token.isNotEmpty) 'token': token,
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (deviceName.isNotEmpty) 'display_device_name': deviceName,
      if (virtualIPv4.isNotEmpty) 'ip': virtualIPv4,
      if (serverAddress.isNotEmpty) 'server_address': serverAddress,
      if (serverList.isNotEmpty) 'server': effectiveServerList,
      if (stunServers.isNotEmpty) 'stun_server': stunServers,
      if (udpStun.isNotEmpty) 'udp_stun': udpStun,
      if (tcpStun.isNotEmpty) 'tcp_stun': tcpStun,
      if (inIps.isNotEmpty) 'in_ips': inIps,
      if (inIps.isNotEmpty) 'input': inIps,
      if (outIps.isNotEmpty) 'out_ips': outIps,
      if (outIps.isNotEmpty) 'output': outIps,
      if (portMappings.isNotEmpty) 'mapping': portMappings,
      if (portMappings.isNotEmpty) 'port_mapping': portMappings,
      if (groupPassword.isNotEmpty) 'password': groupPassword,
      if (isServerEncrypted) 'server_encrypt': isServerEncrypted,
      if (protocol.isNotEmpty) 'protocol': protocol,
      if (dataFingerprintVerification) 'finger': dataFingerprintVerification,
      if (encryptionAlgorithm.isNotEmpty) 'cipher_model': encryptionAlgorithm,
      if (deviceID.isNotEmpty) 'device_id': deviceID,
      if (virtualNetworkCardName.isNotEmpty) 'device_name': virtualNetworkCardName,
      if (virtualNetworkCardName.isNotEmpty) 'tun_name': virtualNetworkCardName,
      if (certMode.isNotEmpty) 'cert_mode': certMode,
      'ctrl_port': ctrlPort,
      if (mtu != 0) 'mtu': mtu,
      if (ports.isNotEmpty) 'ports': ports,
      if (firstLatency) 'first_latency': firstLatency,
      if (noInIpProxy) 'no_proxy': noInIpProxy,
      if (rtx) 'rtx': rtx,
      if (compress) 'compress': compress,
      if (fec) 'fec': fec,
      if (noPunch) 'no_punch': noPunch,
      if (noNat) 'no_nat': noNat,
      if (noTun) 'no_tun': noTun,
      if (allowMapping) 'allow_mapping': allowMapping,
      if (tunnelPort > 0) 'tunnel_port': tunnelPort,
      if (dns.isNotEmpty) 'dns': dns,
      if (simulatedPacketLossRate != 0) 'packet_loss': simulatedPacketLossRate,
      if (simulatedLatency != 0) 'packet_delay': simulatedLatency,
      if (punchModel.isNotEmpty) 'punch_model': punchModel,
      if (useChannelType.isNotEmpty) 'use_channel': useChannelType,
      if (compressor.isNotEmpty) 'compressor': compressor,
      if (allowWg) 'allow_wire_guard': allowWg,
      if (localDev.isNotEmpty) 'local_dev': localDev,
      if (localIpv4.isNotEmpty) 'local_ipv4': localIpv4,
      if (disableRelay) 'disable_relay': disableRelay,
      if (updatedAt.isNotEmpty) 'updated_at': updatedAt,
    };
  }

  factory NetworkConfig.fromJson(Map<String, dynamic> json) {
    final serverList = _stringList(json['server']);
    final serverAddress = _stringValue(
      json['server_address'],
      fallback: serverList.isNotEmpty ? serverList.first : '',
    );
    final deviceName = _stringValue(
      json['display_device_name'] ?? json['name'],
      fallback: _stringValue(json['device_name'], fallback: ''),
    );
    final portMappings = _stringList(json['mapping'] ?? json['port_mapping']);
    final virtualNetworkCardName = _stringValue(
      json['tun_name'] ?? json['device_name'],
      fallback: '',
    );
    return NetworkConfig(
      itemKey: _stringValue(json['itemKey'], fallback: ''),
      configName: _stringValue(json['config_name'], fallback: ''),
      token: _stringValue(json['token'] ?? json['network_code'], fallback: ''),
      deviceName: deviceName,
      virtualIPv4: _stringValue(json['ip'], fallback: ''),
      serverAddress: serverAddress,
      serverList: serverList,
      stunServers: _stringList(json['stun_server']),
      udpStun: _stringList(json['udp_stun']),
      tcpStun: _stringList(json['tcp_stun']),
      inIps: _stringList(json['in_ips'] ?? json['input']),
      outIps: _stringList(json['out_ips'] ?? json['output']),
      portMappings: portMappings,
      groupPassword: _stringValue(json['password'], fallback: ''),
      isServerEncrypted: _boolValue(json['server_encrypt']),
      protocol: _stringValue(json['protocol'], fallback: 'UDP'),
      dataFingerprintVerification: _boolValue(json['finger']),
      encryptionAlgorithm: _stringValue(
        json['cipher_model'],
        fallback: 'aes_gcm',
      ),
      deviceID: _stringValue(json['device_id'], fallback: ''),
      virtualNetworkCardName: virtualNetworkCardName,
      certMode: _stringValue(json['cert_mode'], fallback: 'skip'),
      ctrlPort: _intValue(json['ctrl_port'], fallback: 21233),
      mtu: _intValue(json['mtu'], fallback: 1410),
      ports: _intList(json['ports']),
      firstLatency: _boolValue(json['first_latency']),
      noInIpProxy: _boolValue(json['no_proxy']),
      rtx: _boolValue(json['rtx']),
      compress: _boolValue(json['compress']),
      fec: _boolValue(json['fec']),
      noPunch: _boolValue(json['no_punch']),
      noNat: _boolValue(json['no_nat']),
      noTun: _boolValue(json['no_tun']),
      allowMapping: json.containsKey('allow_mapping')
          ? _boolValue(json['allow_mapping'])
          : portMappings.isNotEmpty,
      tunnelPort: _intValue(json['tunnel_port']),
      dns: _stringList(json['dns']),
      simulatedPacketLossRate: _doubleValue(json['packet_loss']),
      simulatedLatency: _intValue(json['packet_delay']),
      punchModel: _stringValue(json['punch_model'], fallback: 'all'),
      useChannelType: _stringValue(json['use_channel'], fallback: 'all'),
      compressor: _stringValue(json['compressor'], fallback: 'none'),
      allowWg: _boolValue(json['allow_wire_guard']),
      localDev: _stringValue(json['local_dev'], fallback: ''),
      localIpv4: _stringValue(json['local_ipv4'], fallback: ''),
      disableRelay: _boolValue(json['disable_relay']),
      updatedAt: _stringValue(json['updated_at'], fallback: ''),
    );
  }

  static bool _looksLikeIpv4(String value) {
    final match = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(value);
    if (!match) {
      return false;
    }
    for (final segment in value.split('.')) {
      final number = int.tryParse(segment);
      if (number == null || number < 0 || number > 255) {
        return false;
      }
    }
    return true;
  }

  static String _stringValue(dynamic value, {String fallback = ''}) {
    if (value == null) {
      return fallback;
    }
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  static List<String> _stringList(dynamic value) {
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? const [] : [text];
    }
    if (value is! List) {
      return const [];
    }
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<int> _intList(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value
        .map((item) => _intValue(item))
        .where((item) => item > 0)
        .toList(growable: false);
  }

  static bool _boolValue(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' || normalized == '1';
    }
    return false;
  }

  static int _intValue(dynamic value, {int fallback = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? fallback;
    }
    return fallback;
  }

  static double _doubleValue(dynamic value, {double fallback = 0}) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value.trim()) ?? fallback;
    }
    return fallback;
  }

  static String _normalizeProtocol(String protocol, String serverAddress) {
    final normalizedAddress = serverAddress.trim().toLowerCase();
    if (normalizedAddress.startsWith('quic://') ||
        normalizedAddress.startsWith('udp://')) {
      return 'QUIC';
    }
    if (normalizedAddress.startsWith('txt:')) {
      return 'DYNAMIC';
    }
    if (normalizedAddress.startsWith('tcp://')) {
      return 'TCP';
    }
    if (normalizedAddress.startsWith('wss://') ||
        normalizedAddress.startsWith('ws://')) {
      return 'WSS';
    }
    if (normalizedAddress.startsWith('dynamic://')) {
      return 'DYNAMIC';
    }

    final upper = protocol.trim().toUpperCase();
    switch (upper) {
      case 'TCP':
        return 'TCP';
      case 'WSS':
      case 'WS':
        return 'WSS';
      case 'DYNAMIC':
        return 'DYNAMIC';
      case 'UDP':
      case 'QUIC':
      default:
        return 'QUIC';
    }
  }

  static String _normalizeServerAddress(
    String rawAddress, {
    required String fallbackProtocol,
  }) {
    final address = rawAddress.trim();
    if (address.isEmpty) {
      return '';
    }
    final lower = address.toLowerCase();
    if (lower.startsWith('quic://')) {
      return address;
    }
    if (lower.startsWith('txt:')) {
      return 'dynamic://${address.substring('txt:'.length)}';
    }
    if (lower.startsWith('udp://')) {
      return 'quic://${address.substring('udp://'.length)}';
    }
    if (lower.startsWith('tcp://')) {
      return address;
    }
    if (lower.startsWith('wss://')) {
      return address;
    }
    if (lower.startsWith('ws://')) {
      return 'wss://${address.substring('ws://'.length)}';
    }
    if (lower.startsWith('dynamic://')) {
      return address;
    }
    if (lower.contains('://')) {
      return address;
    }

    switch (fallbackProtocol) {
      case 'TCP':
        return 'tcp://$address';
      case 'WSS':
        return 'wss://$address';
      case 'DYNAMIC':
        return 'dynamic://$address';
      case 'QUIC':
      default:
        return 'quic://$address';
    }
  }
}

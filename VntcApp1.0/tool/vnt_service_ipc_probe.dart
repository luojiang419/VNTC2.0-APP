import 'dart:io';

import 'package:vnt_app/services/vnt_service_client.dart';
import 'package:vnt_app/network_config.dart';

Future<void> main() async {
  final client = VntServiceClient();
  await client.ping();
  final status = await client.getStatus();
  await client.replaceConfiguration(
    configs: <NetworkConfig>[_probeConfig()],
    autoConnect: false,
    defaultConfigKey: 'ipc-probe',
  );
  await client.reload();
  stdout.writeln(
    'IPC_OK service=${status.serviceState} connection=${status.connectionState}',
  );
}

NetworkConfig _probeConfig() {
  return NetworkConfig(
    itemKey: 'ipc-probe',
    configName: 'IPC Probe',
    token: 'probe-token',
    deviceName: 'ipc-probe',
    virtualIPv4: '',
    serverAddress: '127.0.0.1:29872',
    groupPassword: '',
    isServerEncrypted: false,
    protocol: 'UDP',
    dataFingerprintVerification: false,
    encryptionAlgorithm: 'aes_gcm',
    deviceID: 'ipc-probe-device',
    virtualNetworkCardName: 'VNT-IPC-PROBE',
    mtu: 1410,
    firstLatency: false,
    noInIpProxy: false,
    simulatedPacketLossRate: 0,
    simulatedLatency: 0,
    punchModel: 'all',
    useChannelType: 'all',
    compressor: 'none',
    allowWg: false,
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/data_persistence.dart';
import 'package:vnt_app/network_config.dart';

NetworkConfig _buildConfig({
  required String itemKey,
  required String configName,
  required String deviceId,
  String virtualIp = '',
}) {
  return NetworkConfig(
    itemKey: itemKey,
    configName: configName,
    token: 'group-1',
    deviceName: 'desktop-node',
    virtualIPv4: virtualIp,
    serverAddress: 'quic://127.0.0.1:2225',
    groupPassword: '',
    isServerEncrypted: false,
    protocol: 'QUIC',
    dataFingerprintVerification: false,
    encryptionAlgorithm: 'aes_gcm',
    deviceID: deviceId,
    virtualNetworkCardName: 'vnt-tun',
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

void main() {
  group('Windows runtime identity ownership', () {
    test('无注册标记且带有旧唯一身份时应触发旋转', () {
      final configs = [
        _buildConfig(
          itemKey: 'cfg-1',
          configName: '主配置',
          deviceId: 'legacy-device-id',
        ),
      ];

      final shouldRotate =
          DataPersistence.shouldRotateWindowsIdentityForCopiedRuntime(
        uniqueId: 'legacy-unique-id',
        configs: configs,
        hasRegistrationMarker: false,
      );

      expect(shouldRotate, isTrue);
    });

    test('已有注册标记时不应重复旋转', () {
      final configs = [
        _buildConfig(
          itemKey: 'cfg-1',
          configName: '主配置',
          deviceId: 'legacy-device-id',
        ),
      ];

      final shouldRotate =
          DataPersistence.shouldRotateWindowsIdentityForCopiedRuntime(
        uniqueId: 'legacy-unique-id',
        configs: configs,
        hasRegistrationMarker: true,
      );

      expect(shouldRotate, isFalse);
    });

    test('旋转后所有配置共享新的设备ID', () {
      final configs = [
        _buildConfig(
          itemKey: 'cfg-1',
          configName: '主配置',
          deviceId: 'legacy-1',
        ),
        _buildConfig(
          itemKey: 'cfg-2',
          configName: '备用配置',
          deviceId: 'legacy-2',
          virtualIp: '10.10.10.10',
        ),
      ];

      final rotated = DataPersistence.rebuildNetworkConfigsWithUniqueId(
        configs,
        'next-device-id',
      );

      expect(
        rotated.map((config) => config.deviceID).toSet(),
        {'next-device-id'},
      );
      expect(rotated[1].virtualIPv4, '10.10.10.10');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/services/windows_service_configuration.dart';

void main() {
  late Directory temporaryDirectory;
  late WindowsServiceConfigurationStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vnt_service_configuration_test_',
    );
    store = WindowsServiceConfigurationStore(
      rootDirectory: temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('writes and loads versioned machine configuration', () async {
    final config = _config('config-a');
    await store.write(
      configs: <NetworkConfig>[config],
      autoConnect: true,
      defaultConfigKey: config.itemKey,
      updatedAt: DateTime.utc(2026, 11, 1),
    );

    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.settings.schemaVersion, 1);
    expect(loaded.settings.autoConnect, isTrue);
    expect(loaded.settings.defaultConfigKey, 'config-a');
    expect(loaded.defaultConfig?.token, 'token-config-a');
    expect(loaded.configs.single.virtualNetworkCardName, 'VNT-TUN');
    expect(await store.dataDirectory.exists(), isTrue);
    expect(await store.logsDirectory.exists(), isTrue);
    expect(await File('${store.settingsFile.path}.tmp').exists(), isFalse);
  });

  test('rejects auto connect without a valid default config', () async {
    await expectLater(
      store.write(
        configs: <NetworkConfig>[_config('config-a')],
        autoConnect: true,
        defaultConfigKey: '',
      ),
      throwsFormatException,
    );
    await expectLater(
      store.write(
        configs: <NetworkConfig>[_config('config-a')],
        autoConnect: true,
        defaultConfigKey: 'missing',
      ),
      throwsFormatException,
    );
  });

  test('legacy migration does not overwrite an existing machine config',
      () async {
    await store.write(
      configs: <NetworkConfig>[_config('config-a')],
      autoConnect: true,
      defaultConfigKey: 'config-a',
    );

    final migrated = await store.migrateLegacyIfNeeded(
      configs: <NetworkConfig>[_config('config-b')],
      autoConnect: true,
      defaultConfigKey: 'config-b',
    );
    final loaded = await store.load();

    expect(migrated, isFalse);
    expect(loaded!.settings.defaultConfigKey, 'config-a');
  });
}

NetworkConfig _config(String key) {
  return NetworkConfig(
    itemKey: key,
    configName: '配置 $key',
    token: 'token-$key',
    deviceName: 'device-$key',
    virtualIPv4: '',
    serverAddress: '127.0.0.1:29872',
    groupPassword: '',
    isServerEncrypted: false,
    protocol: 'UDP',
    dataFingerprintVerification: false,
    encryptionAlgorithm: 'aes_gcm',
    deviceID: 'device-id-$key',
    virtualNetworkCardName: 'VNT-TUN',
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

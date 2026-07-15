import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/features/settings/data/server_config_repository.dart';
import 'package:vnts_console/features/settings/domain/server_config_settings.dart';

void main() {
  test('结构化配置保存保留秘密、注释和自定义区段并创建备份', () async {
    final directory = await Directory.systemTemp.createTemp('vnts2-config-');
    addTearDown(() => directory.delete(recursive: true));
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.toml',
    );
    await config.writeAsString('''
tcp_bind = "0.0.0.0:29870" # 保留注释
network = "10.26.0.0/24"
white_list = ["node-a"]
lease_duration = 86400
persistence = true
web_bind = "127.0.0.1:29871"
username = "admin"
password = "Secret#Value-2026"
wireguard_max_active_peers = 4096

[custom_nets]
branch = "10.88.0.0/24"
''');
    final repository = ServerConfigRepository(config);
    final loaded = await repository.load();

    expect(loaded.settings.hasPassword, isTrue);
    final result = await repository.save(
      loaded,
      loaded.settings.copyWith(leaseDurationSeconds: 7200),
    );
    final saved = await config.readAsString();

    expect(saved, contains('password = "Secret#Value-2026"'));
    expect(saved, contains('tcp_bind = "0.0.0.0:29870" # 保留注释'));
    expect(saved, contains('lease_duration = 7200'));
    expect(saved, contains('[custom_nets]'));
    expect(saved, contains('branch = "10.88.0.0/24"'));
    expect(await File(result.backupPath).exists(), isTrue);
  });

  test('Web 配置拒绝远程绑定', () async {
    final directory = await Directory.systemTemp.createTemp('vnts2-config-');
    addTearDown(() => directory.delete(recursive: true));
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.toml',
    );
    await config.writeAsString('''
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_max_active_peers = 4096
''');
    final repository = ServerConfigRepository(config);
    final loaded = await repository.load();
    expect(loaded.settings.webBind, '127.0.0.1:39871');
    final invalid = loaded.settings.copyWith(
      webEnabled: true,
      webBind: '0.0.0.0:29871',
      username: 'admin',
    );

    await expectLater(
      repository.save(loaded, invalid, newPassword: 'short'),
      throwsA(isA<ConfigValidationException>()),
    );
  });

  test('Web 配置允许非空短密码且不再限制 12 位', () async {
    final directory = await Directory.systemTemp.createTemp('vnts2-config-');
    addTearDown(() => directory.delete(recursive: true));
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.toml',
    );
    await config.writeAsString('''
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_max_active_peers = 4096
''');
    final repository = ServerConfigRepository(config);
    final loaded = await repository.load();
    final valid = loaded.settings.copyWith(
      webEnabled: true,
      webBind: '127.0.0.1:29871',
      username: 'admin',
    );

    await repository.save(loaded, valid, newPassword: 'x');
    expect(await config.readAsString(), contains('password = "x"'));
  });

  test('WireGuard 缺省值使用增强版独立端口并自动创建 32 字节主密钥', () async {
    final directory = await Directory.systemTemp.createTemp('vnts2-config-');
    addTearDown(() => directory.delete(recursive: true));
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.toml',
    );
    await config.writeAsString('''
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_max_active_peers = 4096
''');
    final repository = ServerConfigRepository(config);
    final loaded = await repository.load();

    expect(loaded.settings.wireGuardEnabled, isFalse);
    expect(
      loaded.settings.wireGuardMasterKeyFile,
      WireGuardDefaults.masterKeyFile,
    );
    expect(loaded.settings.wireGuardBind, '0.0.0.0:41195');
    expect(loaded.settings.wireGuardPublicEndpoint, endsWith(':41195'));
    expect(
      loaded.settings.wireGuardPublicEndpoint,
      isNot(matches(RegExp(r'^198\.(18|19)\.'))),
    );

    await repository.save(
      loaded,
      loaded.settings.copyWith(wireGuardEnabled: true),
    );
    final key = File(
      '${directory.path}${Platform.pathSeparator}wireguard-master.key',
    );
    final saved = await config.readAsString();
    expect(await key.length(), 32);
    expect(
      saved,
      contains('wireguard_master_key_file = "wireguard-master.key"'),
    );
    expect(saved, contains('wireguard_bind = "0.0.0.0:41195"'));
    expect(saved, contains('wireguard_public_endpoint = "'));
  });

  test('启用 WireGuard 时拒绝空外部访问地址', () async {
    final directory = await Directory.systemTemp.createTemp('vnts2-config-');
    addTearDown(() => directory.delete(recursive: true));
    final config = File(
      '${directory.path}${Platform.pathSeparator}config.toml',
    );
    await config.writeAsString('''
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_max_active_peers = 4096
''');
    final repository = ServerConfigRepository(config);
    final loaded = await repository.load();

    await expectLater(
      repository.save(
        loaded,
        loaded.settings.copyWith(
          wireGuardEnabled: true,
          wireGuardPublicEndpoint: '',
        ),
      ),
      throwsA(isA<ConfigValidationException>()),
    );
    expect(
      await File(
        '${directory.path}${Platform.pathSeparator}wireguard-master.key',
      ).exists(),
      isFalse,
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

class VntServiceSettings {
  const VntServiceSettings({
    this.schemaVersion = currentSchemaVersion,
    required this.autoConnect,
    required this.defaultConfigKey,
    required this.updatedAt,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final bool autoConnect;
  final String defaultConfigKey;
  final String updatedAt;

  factory VntServiceSettings.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException('不支持的 VNT 服务配置版本: $schemaVersion');
    }
    return VntServiceSettings(
      schemaVersion: schemaVersion as int,
      autoConnect: json['autoConnect'] == true,
      defaultConfigKey: (json['defaultConfigKey'] ?? '').toString().trim(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'autoConnect': autoConnect,
        'defaultConfigKey': defaultConfigKey,
        'updatedAt': updatedAt,
      };
}

class VntServiceConfigurationSnapshot {
  const VntServiceConfigurationSnapshot({
    required this.settings,
    required this.configs,
  });

  final VntServiceSettings settings;
  final List<NetworkConfig> configs;

  NetworkConfig? get defaultConfig {
    final targetKey = settings.defaultConfigKey;
    if (targetKey.isEmpty) {
      return null;
    }
    for (final config in configs) {
      if (config.itemKey == targetKey) {
        return config;
      }
    }
    return null;
  }
}

class WindowsServiceConfigurationStore {
  WindowsServiceConfigurationStore({Directory? rootDirectory})
      : rootDirectory = rootDirectory ??
            Directory(RuntimeStoragePaths.resolveWindowsMachineRootPathSync());

  static const String settingsFileName = 'service.json';
  static const String networksFileName = 'networks.json';
  static const int networksSchemaVersion = 1;

  final Directory rootDirectory;
  final Lock _lock = Lock();

  Directory get configDirectory => Directory(
        path.join(rootDirectory.path, 'config'),
      );
  Directory get dataDirectory =>
      Directory(path.join(rootDirectory.path, 'data'));
  Directory get logsDirectory =>
      Directory(path.join(rootDirectory.path, 'logs'));
  File get settingsFile =>
      File(path.join(configDirectory.path, settingsFileName));
  File get networksFile =>
      File(path.join(configDirectory.path, networksFileName));

  Future<VntServiceConfigurationSnapshot?> load() async {
    return _lock.synchronized(() async {
      if (!await settingsFile.exists() || !await networksFile.exists()) {
        return null;
      }
      final settingsJson = _decodeObject(await settingsFile.readAsString());
      final networksJson = _decodeObject(await networksFile.readAsString());
      if (networksJson['schemaVersion'] != networksSchemaVersion) {
        throw FormatException(
          '不支持的 VNT 网络配置版本: ${networksJson['schemaVersion']}',
        );
      }
      final rawConfigs = networksJson['configs'];
      if (rawConfigs is! List) {
        throw const FormatException('VNT 网络配置缺少 configs 数组');
      }
      final configs = rawConfigs.map((value) {
        if (value is! Map) {
          throw const FormatException('VNT 网络配置项必须是 JSON 对象');
        }
        return NetworkConfig.fromJson(
          value.map((key, item) => MapEntry(key.toString(), item)),
        );
      }).toList(growable: false);
      return VntServiceConfigurationSnapshot(
        settings: VntServiceSettings.fromJson(settingsJson),
        configs: configs,
      );
    });
  }

  Future<void> write({
    required List<NetworkConfig> configs,
    required bool autoConnect,
    required String defaultConfigKey,
    DateTime? updatedAt,
  }) async {
    await _lock.synchronized(() async {
      final normalizedDefaultKey = defaultConfigKey.trim();
      if (autoConnect && normalizedDefaultKey.isEmpty) {
        throw const FormatException('启用系统自动连接前必须设置默认配置');
      }
      if (normalizedDefaultKey.isNotEmpty &&
          !configs.any((config) => config.itemKey == normalizedDefaultKey)) {
        throw FormatException('默认配置不存在: $normalizedDefaultKey');
      }
      final keys = <String>{};
      for (final config in configs) {
        final key = config.itemKey.trim();
        if (key.isEmpty) {
          throw const FormatException('VNT 网络配置 itemKey 不能为空');
        }
        if (!keys.add(key)) {
          throw FormatException('VNT 网络配置 itemKey 重复: $key');
        }
      }

      await configDirectory.create(recursive: true);
      await dataDirectory.create(recursive: true);
      await logsDirectory.create(recursive: true);
      final timestamp = (updatedAt ?? DateTime.now().toUtc()).toIso8601String();
      final settings = VntServiceSettings(
        autoConnect: autoConnect,
        defaultConfigKey: normalizedDefaultKey,
        updatedAt: timestamp,
      );
      final networks = <String, dynamic>{
        'schemaVersion': networksSchemaVersion,
        'updatedAt': timestamp,
        'configs': configs.map((config) => config.toJson()).toList(),
      };
      await _writeJsonAtomically(networksFile, networks);
      await _writeJsonAtomically(settingsFile, settings.toJson());
    });
  }

  Future<bool> migrateLegacyIfNeeded({
    required List<NetworkConfig> configs,
    required bool autoConnect,
    required String defaultConfigKey,
    DateTime? updatedAt,
  }) async {
    if (await settingsFile.exists() || await networksFile.exists()) {
      return false;
    }
    await write(
      configs: configs,
      autoConnect: autoConnect,
      defaultConfigKey: defaultConfigKey,
      updatedAt: updatedAt,
    );
    return true;
  }

  Map<String, dynamic> _decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('VNT 服务配置根节点必须是 JSON 对象');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _writeJsonAtomically(
    File destination,
    Map<String, dynamic> value,
  ) async {
    final temporary = File('${destination.path}.tmp');
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      await temporary.rename(destination.path);
    } on FileSystemException {
      await temporary.copy(destination.path);
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

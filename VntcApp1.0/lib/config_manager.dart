import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

/// Windows 平台使用程序目录下的 config.json
/// 其他平台使用 shared_preferences
class ConfigManager {
  static final ConfigManager _instance = ConfigManager._internal();
  factory ConfigManager() => _instance;
  ConfigManager._internal();
  factory ConfigManager.forTesting(File configFile) =>
      ConfigManager._forTesting(configFile);
  ConfigManager._forTesting(this._configFile) : _initialized = true;

  File? _configFile;
  Map<String, dynamic> _cache = {};
  bool _initialized = false;
  final Lock _lock = Lock();

  /// 获取配置文件路径
  String get configFilePath => _configFile?.path ?? 'config.json (未初始化)';

  /// 初始化配置文件路径
  Future<void> init() async {
    if (_initialized) return; // 防止重复初始化

    await _lock.synchronized(() async {
      if (_initialized) return;

      if (Platform.isWindows) {
        final configDir = Directory(
          RuntimeStoragePaths.resolveConfigDirectoryPathSync(),
        );

        if (!await configDir.exists()) {
          await configDir.create(recursive: true);
        }

        _configFile = File(path.join(configDir.path, 'config.json'));

        if (await _configFile!.exists()) {
          try {
            final content = await _configFile!.readAsString();
            _cache = json.decode(content) as Map<String, dynamic>;
          } catch (e) {
            stderr.writeln('加载配置文件失败: $e');
          }
        }
      }

      _initialized = true;
    });
  }

  /// 保存配置
  Future<void> _saveUnlocked() async {
    final configFile = _configFile;
    if (configFile == null) {
      return;
    }

    final parent = configFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final tempFile = File('${configFile.path}.tmp');
    try {
      await tempFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_cache),
        flush: true,
      );
      await tempFile.copy(configFile.path);
    } catch (e) {
      stderr.writeln('保存配置文件失败: $e');
      rethrow;
    } finally {
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _mutateCache(void Function(Map<String, dynamic>) mutate) async {
    await init();
    await _lock.synchronized(() async {
      final previous = _cloneCache(_cache);
      mutate(_cache);
      try {
        await _saveUnlocked();
      } catch (_) {
        _cache = previous;
        rethrow;
      }
    });
  }

  Map<String, dynamic> _cloneCache(Map<String, dynamic> source) {
    return source.map(
      (key, value) => MapEntry(key, _cloneJsonValue(value)),
    );
  }

  dynamic _cloneJsonValue(dynamic value) {
    if (value is List) {
      return value.map(_cloneJsonValue).toList();
    }
    if (value is Map) {
      return value.map(
        (key, mapValue) => MapEntry(key.toString(), _cloneJsonValue(mapValue)),
      );
    }
    return value;
  }

  /// 设置字符串值
  Future<void> setString(String key, String value) async {
    await _mutateCache((cache) {
      cache[key] = value;
    });
  }

  /// 获取字符串值
  String? getString(String key) {
    return _cache[key] as String?;
  }

  /// 设置布尔值
  Future<void> setBool(String key, bool value) async {
    await _mutateCache((cache) {
      cache[key] = value;
    });
  }

  /// 获取布尔值
  bool? getBool(String key) {
    return _cache[key] as bool?;
  }

  /// 设置整数值
  Future<void> setInt(String key, int value) async {
    await _mutateCache((cache) {
      cache[key] = value;
    });
  }

  /// 获取整数值
  int? getInt(String key) {
    return _cache[key] as int?;
  }

  /// 获取双精度浮点数值
  double? getDouble(String key) {
    final value = _cache[key];
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return null;
  }

  /// 设置双精度浮点数值
  Future<void> setDouble(String key, double value) async {
    await _mutateCache((cache) {
      cache[key] = value;
    });
  }

  /// 设置字符串列表
  Future<void> setStringList(String key, List<String> value) async {
    await _mutateCache((cache) {
      cache[key] = List<String>.from(value);
    });
  }

  Future<void> setValues(
    Map<String, dynamic> values, {
    Iterable<String> removeKeys = const <String>[],
  }) async {
    final copiedValues = values.map(
      (key, value) => MapEntry(key, _cloneJsonValue(value)),
    );
    await _mutateCache((cache) {
      for (final key in removeKeys) {
        cache.remove(key);
      }
      cache.addAll(copiedValues);
    });
  }

  /// 获取字符串列表
  List<String>? getStringList(String key) {
    final value = _cache[key];
    if (value is List) {
      return List<String>.from(value);
    }
    return null;
  }

  /// 删除键
  Future<void> remove(String key) async {
    await _mutateCache((cache) {
      cache.remove(key);
    });
  }

  /// 获取所有键
  Set<String> getKeys() {
    return _cache.keys.toSet();
  }

  /// 清空所有配置
  Future<void> clear() async {
    await _mutateCache((cache) {
      cache.clear();
    });
  }
}

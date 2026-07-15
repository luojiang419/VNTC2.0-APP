import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'network_config.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'config_manager.dart';
import 'package:synchronized/synchronized.dart';
import 'window_close_behavior.dart';
import 'vnt/virtual_network_adapter_manager.dart';

class DataPersistence {
  static const String dataKey = 'data-key';
  static const String dataKeyForNative = 'data-key-native';
  static const String vntUniqueIdKey = 'vnt-unique-id-key';
  static const Set<String> windowsDistributionUnsafeKeys = {
    'window-x',
    'window-y',
    'window-width',
    'window-height',
    'vnt-unique-id-key',
    'is-auto-start',
    'is-silent-start',
    'is-always-on-top',
    'is-close-app',
  };
  static final Lock _dataLock = Lock();

  ConfigManager? _configManager;

  @visibleForTesting
  static Map<String, dynamic> buildWindowsImportValuesForTesting(
    Map<String, dynamic> winSettings,
  ) {
    final result = DataPersistence()._buildWindowsImportValues(winSettings);
    return {
      'values': result.values,
      'removeKeys': result.removeKeys,
    };
  }

  Future<ConfigManager> _getConfigManager() async {
    if (Platform.isWindows) {
      _configManager ??= ConfigManager();
      await _configManager!.init();
      return _configManager!;
    }
    throw Exception('ConfigManager only for Windows');
  }

  Future<void> saveData(List<NetworkConfig> configs) async {
    await _dataLock.synchronized(() => _saveDataUnlocked(configs));
  }

  Future<void> _saveDataUnlocked(List<NetworkConfig> configs) async {
    VirtualNetworkAdapterIdentity.normalizeConfigs(configs);
    final values = _buildConfigDataValues(configs);

    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setValues(values);
    } else {
      final jsonDataList = values[dataKey] as List<String>;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(dataKey, jsonDataList);
      await prefs.setString(
        dataKeyForNative,
        values[dataKeyForNative] as String,
      );
    }
  }

  Map<String, dynamic> _buildConfigDataValues(List<NetworkConfig> configs) {
    final jsonDataList =
        configs.map((config) => jsonEncode(config.toJson())).toList();
    return {
      dataKey: jsonDataList,
      dataKeyForNative: jsonEncode(jsonDataList),
    };
  }

  Future<List<NetworkConfig>> loadData() async {
    return _dataLock.synchronized(_loadDataUnlocked);
  }

  Future<List<NetworkConfig>> _loadDataUnlocked() async {
    List<String>? jsonDataList;

    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      jsonDataList = configManager.getStringList(dataKey);
    } else {
      final prefs = await SharedPreferences.getInstance();
      jsonDataList = prefs.getStringList(dataKey);
    }

    if (jsonDataList != null) {
      final configs = jsonDataList
          .map((jsonData) => NetworkConfig.fromJson(jsonDecode(jsonData)))
          .toList();
      if (VirtualNetworkAdapterIdentity.normalizeConfigs(configs)) {
        await _saveDataUnlocked(configs);
      }
      return configs;
    } else {
      return [];
    }
  }

  Future<String> loadUniqueId() async {
    String? uniqueId;

    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      uniqueId = configManager.getString(vntUniqueIdKey);
      if (uniqueId == null || uniqueId.isEmpty) {
        uniqueId = const Uuid().v4().toString();
        await configManager.setString(vntUniqueIdKey, uniqueId);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      uniqueId = prefs.getString(vntUniqueIdKey);
      if (uniqueId == null || uniqueId.isEmpty) {
        uniqueId = const Uuid().v4().toString();
        await prefs.setString(vntUniqueIdKey, uniqueId);
      }
    }

    return uniqueId;
  }

  Future<Size?> loadWindowSize() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final width = configManager.getDouble('window-width');
      final height = configManager.getDouble('window-height');
      if (width != null && height != null) {
        return Size(width, height);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      final width = prefs.getDouble('window-width');
      final height = prefs.getDouble('window-height');
      if (width != null && height != null) {
        return Size(width, height);
      }
    }
    return const Size(600, 700);
  }

  Future<Size?> loadSavedWindowSize() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final width = configManager.getDouble('window-width');
      final height = configManager.getDouble('window-height');
      if (width != null && height != null) {
        return Size(width, height);
      }
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window-width');
    final height = prefs.getDouble('window-height');
    if (width != null && height != null) {
      return Size(width, height);
    }
    return null;
  }

  Future<void> saveWindowSize(Size size) async {
    if (size.width == 600 && size.height == 700) {
      return;
    }
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setValues({
        'window-width': size.width,
        'window-height': size.height,
      });
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('window-width', size.width);
      await prefs.setDouble('window-height', size.height);
    }
  }

  Future<Offset?> loadWindowPosition() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final x = configManager.getDouble('window-x');
      final y = configManager.getDouble('window-y');
      if (x != null && y != null) {
        return Offset(x, y);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      final x = prefs.getDouble('window-x');
      final y = prefs.getDouble('window-y');
      if (x != null && y != null) {
        return Offset(x, y);
      }
    }
    return null;
  }

  Future<Offset?> loadSavedWindowPosition() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final x = configManager.getDouble('window-x');
      final y = configManager.getDouble('window-y');
      if (x != null && y != null) {
        return Offset(x, y);
      }
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble('window-x');
    final y = prefs.getDouble('window-y');
    if (x != null && y != null) {
      return Offset(x, y);
    }
    return null;
  }

  Future<void> saveWindowPosition(Offset position) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setValues({
        'window-x': position.dx,
        'window-y': position.dy,
      });
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('window-x', position.dx);
      await prefs.setDouble('window-y', position.dy);
    }
  }

  Future<bool?> loadCloseApp() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final result = configManager.getBool('is-close-app');
      debugPrint('Windows loadCloseApp: $result');
      return result;
    } else {
      final prefs = await SharedPreferences.getInstance();
      final result = prefs.getBool('is-close-app');
      debugPrint('Other platform loadCloseApp: $result');
      return result;
    }
  }

  Future<void> saveCloseApp(bool? isClose) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      if (isClose == null) {
        await configManager.remove('is-close-app');
      } else {
        await configManager.setBool('is-close-app', isClose);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      if (isClose == null) {
        await prefs.remove('is-close-app');
      } else {
        await prefs.setBool('is-close-app', isClose);
      }
    }
  }

  Future<WindowCloseBehavior> loadWindowCloseBehavior() async {
    return windowCloseBehaviorFromPersistedValue(await loadCloseApp());
  }

  Future<void> saveWindowCloseBehavior(WindowCloseBehavior behavior) async {
    await saveCloseApp(behavior.persistedValue);
  }

  Future<bool> loadAlwaysOnTop() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      return configManager.getBool('is-always-on-top') ?? false;
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('is-always-on-top') ?? false;
    }
  }

  Future<void> saveAlwaysOnTop(bool alwaysOnTop) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setBool('is-always-on-top', alwaysOnTop);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is-always-on-top', alwaysOnTop);
    }
  }

  Future<bool?> loadAutoStart() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      return configManager.getBool('is-auto-start');
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('is-auto-start');
    }
  }

  Future<void> saveAutoStart(bool autoStart) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setBool('is-auto-start', autoStart);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is-auto-start', autoStart);
    }
  }

  Future<bool?> loadSilentStart() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      return configManager.getBool('is-silent-start');
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('is-silent-start');
    }
  }

  Future<void> saveSilentStart(bool silentStart) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setBool('is-silent-start', silentStart);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is-silent-start', silentStart);
    }
  }

  Future<bool?> loadAutoConnect() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      return configManager.getBool('is-auto-connect');
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('is-auto-connect');
    }
  }

  Future<void> saveAutoConnect(bool autoConnect) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setBool('is-auto-connect', autoConnect);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is-auto-connect', autoConnect);
    }
  }

  Future<String?> loadDefaultKey() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      return configManager.getString('default-key');
    } else {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('default-key');
    }
  }

  Future<void> saveDefaultKey(String defaultKey) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setString('default-key', defaultKey);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default-key', defaultKey);
    }
  }

  Future<void> clear() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.clear();
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    }
  }

  Future<ThemeMode?> loadThemeMode() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final index = configManager.getInt('theme-mode');
      if (index != null && index >= 0 && index < ThemeMode.values.length) {
        return ThemeMode.values[index];
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getInt('theme-mode');
      if (index != null && index >= 0 && index < ThemeMode.values.length) {
        return ThemeMode.values[index];
      }
    }
    return null;
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setInt('theme-mode', mode.index);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('theme-mode', mode.index);
    }
  }

  Future<void> saveCustomThemeColor(Color color) async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      await configManager.setInt('custom-theme-color', color.toARGB32());
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('custom-theme-color', color.toARGB32());
    }
  }

  Future<Color?> loadCustomThemeColor() async {
    if (Platform.isWindows) {
      final configManager = await _getConfigManager();
      final colorValue = configManager.getInt('custom-theme-color');
      if (colorValue != null) {
        return Color(colorValue);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      final colorValue = prefs.getInt('custom-theme-color');
      if (colorValue != null) {
        return Color(colorValue);
      }
    }
    return null;
  }

  // 导出所有配置到文件
  Future<void> exportAllConfigs(String filePath) async {
    try {
      final configs = await loadData();
      final jsonData = {
        'version': '1.0',
        'export_time': DateTime.now().toIso8601String(),
        'configs': configs.map((c) => c.toJson()).toList(),
      };

      // Windows平台额外导出窗口和系统配置
      if (Platform.isWindows) {
        final windowSize = await loadWindowSize();
        final windowPosition = await loadWindowPosition();
        final themeMode = await loadThemeMode();
        final customColor = await loadCustomThemeColor();
        final autoStart = await loadAutoStart();
        final silentStart = await loadSilentStart();
        final autoConnect = await loadAutoConnect();
        final defaultKey = await loadDefaultKey();
        final closeApp = await loadCloseApp();
        final alwaysOnTop = await loadAlwaysOnTop();

        jsonData['windows_settings'] = {
          if (windowSize != null)
            'window_size': {
              'width': windowSize.width,
              'height': windowSize.height
            },
          if (windowPosition != null)
            'window_position': {'x': windowPosition.dx, 'y': windowPosition.dy},
          if (themeMode != null) 'theme_mode': themeMode.index,
          if (customColor != null) 'custom_theme_color': customColor.toARGB32(),
          if (autoStart != null) 'auto_start': autoStart,
          if (silentStart != null) 'silent_start': silentStart,
          if (autoConnect != null) 'auto_connect': autoConnect,
          if (defaultKey != null) 'default_key': defaultKey,
          if (closeApp != null) 'close_app': closeApp,
          'always_on_top': alwaysOnTop,
        };
      }

      final file = File(filePath);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file
          .writeAsString(const JsonEncoder.withIndent('  ').convert(jsonData));
      debugPrint('配置导出成功: $filePath');
    } catch (e) {
      debugPrint('配置导出失败: $e');
      rethrow;
    }
  }

  // 从文件导入所有配置
  Future<void> importAllConfigs(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('文件不存在: $filePath');
      }
      final content = await file.readAsString();
      final jsonData = jsonDecode(content);
      if (jsonData is! Map<String, dynamic>) {
        throw const FormatException('配置文件格式错误：根节点必须是对象');
      }
      final configItems = jsonData['configs'];
      if (configItems is! List) {
        throw const FormatException('配置文件格式错误：configs 必须是数组');
      }
      final configs = configItems
          .map((c) => NetworkConfig.fromJson(Map<String, dynamic>.from(c)))
          .toList();

      await _dataLock.synchronized(() async {
        if (Platform.isWindows) {
          final values = _buildConfigDataValues(configs);
          final removeKeys = <String>[];
          final winSettings = jsonData['windows_settings'];
          if (winSettings != null) {
            if (winSettings is! Map<String, dynamic>) {
              throw const FormatException(
                '配置文件格式错误：windows_settings 必须是对象',
              );
            }
            final winValues = _buildWindowsImportValues(winSettings);
            values.addAll(winValues.values);
            removeKeys.addAll(winValues.removeKeys);
          }
          final configManager = await _getConfigManager();
          await configManager.setValues(values, removeKeys: removeKeys);
          if (winSettings != null) {
            debugPrint('Windows配置恢复成功');
          }
        } else {
          await _saveDataUnlocked(configs);
        }
      });

      debugPrint('配置导入成功: ${configs.length}个配置');
    } catch (e) {
      debugPrint('配置导入失败: $e');
      rethrow;
    }
  }

  // 导出单个配置到文件
  Future<void> exportSingleConfig(String filePath, NetworkConfig config) async {
    try {
      final jsonData = {
        'version': '1.0',
        'export_time': DateTime.now().toIso8601String(),
        'config': config.toJson(),
      };
      final file = File(filePath);
      // 确保父目录存在
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file
          .writeAsString(const JsonEncoder.withIndent('  ').convert(jsonData));
      debugPrint('单个配置导出成功: $filePath');
    } catch (e) {
      debugPrint('单个配置导出失败: $e');
      rethrow;
    }
  }

  // 从文件导入单个配置
  Future<void> importSingleConfig(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('文件不存在: $filePath');
      }
      final content = await file.readAsString();
      final jsonData = jsonDecode(content);
      if (jsonData is! Map<String, dynamic>) {
        throw const FormatException('配置文件格式错误：根节点必须是对象');
      }
      final configJson = jsonData['config'];
      if (configJson is! Map<String, dynamic>) {
        throw const FormatException('配置文件格式错误：config 必须是对象');
      }
      final config = NetworkConfig.fromJson(configJson);
      await _dataLock.synchronized(() async {
        final configs = await _loadDataUnlocked();
        configs.add(config);
        await _saveDataUnlocked(configs);
      });
      debugPrint('单个配置导入成功: ${config.configName}');
    } catch (e) {
      debugPrint('单个配置导入失败: $e');
      rethrow;
    }
  }

  _WindowsImportValues _buildWindowsImportValues(
    Map<String, dynamic> winSettings,
  ) {
    final values = <String, dynamic>{};
    final removeKeys = <String>[];

    if (winSettings.containsKey('window_size')) {
      final size = _requiredMap(winSettings['window_size'], 'window_size');
      values['window-width'] =
          _requiredDouble(size['width'], 'window_size.width');
      values['window-height'] =
          _requiredDouble(size['height'], 'window_size.height');
    }

    if (winSettings.containsKey('window_position')) {
      final position =
          _requiredMap(winSettings['window_position'], 'window_position');
      values['window-x'] = _requiredDouble(position['x'], 'window_position.x');
      values['window-y'] = _requiredDouble(position['y'], 'window_position.y');
    }

    if (winSettings.containsKey('theme_mode')) {
      final themeModeIndex =
          _requiredInt(winSettings['theme_mode'], 'theme_mode');
      if (themeModeIndex < 0 || themeModeIndex >= ThemeMode.values.length) {
        throw RangeError.range(
          themeModeIndex,
          0,
          ThemeMode.values.length - 1,
          'theme_mode',
        );
      }
      values['theme-mode'] = themeModeIndex;
    }

    if (winSettings.containsKey('custom_theme_color')) {
      values['custom-theme-color'] = _requiredInt(
        winSettings['custom_theme_color'],
        'custom_theme_color',
      );
    }

    if (winSettings.containsKey('auto_start')) {
      values['is-auto-start'] =
          _requiredBool(winSettings['auto_start'], 'auto_start');
    }

    if (winSettings.containsKey('silent_start')) {
      values['is-silent-start'] =
          _requiredBool(winSettings['silent_start'], 'silent_start');
    }

    if (winSettings.containsKey('auto_connect')) {
      values['is-auto-connect'] =
          _requiredBool(winSettings['auto_connect'], 'auto_connect');
    }

    if (winSettings.containsKey('default_key')) {
      values['default-key'] =
          _requiredString(winSettings['default_key'], 'default_key');
    }

    if (winSettings.containsKey('close_app')) {
      final closeApp = winSettings['close_app'];
      if (closeApp == null) {
        removeKeys.add('is-close-app');
      } else {
        values['is-close-app'] = _requiredBool(closeApp, 'close_app');
      }
    }

    if (winSettings.containsKey('always_on_top')) {
      values['is-always-on-top'] =
          _requiredBool(winSettings['always_on_top'], 'always_on_top');
    }

    return _WindowsImportValues(values, removeKeys);
  }

  Map<String, dynamic> _requiredMap(dynamic value, String label) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw FormatException('$label 必须是对象');
  }

  double _requiredDouble(dynamic value, String label) {
    if (value is num) {
      return value.toDouble();
    }
    throw FormatException('$label 必须是数字');
  }

  int _requiredInt(dynamic value, String label) {
    if (value is int) {
      return value;
    }
    throw FormatException('$label 必须是整数');
  }

  bool _requiredBool(dynamic value, String label) {
    if (value is bool) {
      return value;
    }
    throw FormatException('$label 必须是布尔值');
  }

  String _requiredString(dynamic value, String label) {
    if (value is String) {
      return value;
    }
    throw FormatException('$label 必须是字符串');
  }

  /// 获取持久化配置文件路径（用于日志打印）
  Future<String> getConfigFilePath() async {
    if (Platform.isWindows) {
      final manager = await _getConfigManager();
      return manager.configFilePath;
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Android/iOS 使用 SharedPreferences，返回说明性路径
      return 'SharedPreferences (${Platform.operatingSystem})';
    } else {
      // Linux/macOS 使用 SharedPreferences，显示实际路径
      final home = Platform.environment['HOME'] ?? '';
      return 'SharedPreferences ($home/.local/share/top.wherewego.vnt_app/)';
    }
  }

  static Map<String, dynamic> sanitizeWindowsDistributionConfigMap(
    Map<String, dynamic> source,
  ) {
    final sanitized = Map<String, dynamic>.from(source);
    for (final key in windowsDistributionUnsafeKeys) {
      sanitized.remove(key);
    }
    return sanitized;
  }

  Future<Map<String, dynamic>> buildDistributionSafeWindowsConfigMap({
    String? sourceFilePath,
  }) async {
    final configPath = sourceFilePath ?? await getConfigFilePath();
    final file = File(configPath);
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      return <String, dynamic>{};
    }
    return sanitizeWindowsDistributionConfigMap(
      Map<String, dynamic>.from(decoded),
    );
  }

  Future<void> writeDistributionSafeWindowsConfig(
    String filePath, {
    String? sourceFilePath,
  }) async {
    final sanitized = await buildDistributionSafeWindowsConfigMap(
      sourceFilePath: sourceFilePath,
    );
    final file = File(filePath);
    final directory = file.parent;
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sanitized),
    );
  }
}

class _WindowsImportValues {
  const _WindowsImportValues(this.values, this.removeKeys);

  final Map<String, dynamic> values;
  final List<String> removeKeys;
}

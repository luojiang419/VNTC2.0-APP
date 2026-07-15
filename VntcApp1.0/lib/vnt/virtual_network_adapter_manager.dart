import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:vnt_app/network_config.dart';

typedef AdapterProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

class VirtualNetworkAdapterIdentity {
  static const String windowsManagedPrefix = 'VNT-App-TUN-';
  static const Uuid _uuid = Uuid();

  static String createItemKey() => _uuid.v4();

  static String automaticNameForItemKey(String itemKey) {
    final digest = sha256.convert(utf8.encode(itemKey.trim())).toString();
    return 'cfg-${digest.substring(0, 16)}';
  }

  static String managedWindowsAdapterName(String configuredName) {
    final suffix = RegExp(r'[A-Za-z0-9_-]')
        .allMatches(configuredName.trim())
        .map((match) => match.group(0)!)
        .take(48)
        .join();
    return '$windowsManagedPrefix${suffix.isEmpty ? 'default' : suffix}';
  }

  /// 补齐并去重持久化配置身份。返回 true 表示列表已被迁移。
  static bool normalizeConfigs(
    List<NetworkConfig> configs, {
    String Function()? itemKeyFactory,
  }) {
    final createKey = itemKeyFactory ?? createItemKey;
    final usedKeys = <String>{};
    final usedAdapterNames = <String>{};
    var changed = false;

    for (final config in configs) {
      var itemKey = config.itemKey.trim();
      while (itemKey.isEmpty || usedKeys.contains(itemKey)) {
        itemKey = createKey().trim();
      }
      if (config.itemKey != itemKey) {
        config.itemKey = itemKey;
        changed = true;
      }
      usedKeys.add(itemKey);

      var configuredName = config.virtualNetworkCardName.trim();
      var managedName = managedWindowsAdapterName(configuredName).toLowerCase();
      if (configuredName.isEmpty || usedAdapterNames.contains(managedName)) {
        final baseName = automaticNameForItemKey(itemKey);
        configuredName = baseName;
        var suffix = 2;
        managedName = managedWindowsAdapterName(configuredName).toLowerCase();
        while (usedAdapterNames.contains(managedName)) {
          configuredName = '$baseName-$suffix';
          suffix++;
          managedName = managedWindowsAdapterName(configuredName).toLowerCase();
        }
      }
      if (config.virtualNetworkCardName != configuredName) {
        config.virtualNetworkCardName = configuredName;
        changed = true;
      }
      usedAdapterNames.add(managedName);
    }

    return changed;
  }
}

class VirtualNetworkAdapterManager {
  VirtualNetworkAdapterManager({
    bool? isWindows,
    AdapterProcessRunner? processRunner,
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _processRunner = processRunner ?? _runProcess;

  final bool _isWindows;
  final AdapterProcessRunner _processRunner;

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return Process.run(
      executable,
      arguments,
      environment: environment,
      runInShell: false,
    );
  }

  Future<void> deleteForConfig(NetworkConfig config) async {
    final configuredName = config.virtualNetworkCardName.trim();
    if (!_isWindows || configuredName.isEmpty) {
      return;
    }

    final adapterName =
        VirtualNetworkAdapterIdentity.managedWindowsAdapterName(configuredName);
    final lookupResult = await _processRunner(
      'powershell.exe',
      const [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $env:VNT_ADAPTER_NAME } | ForEach-Object { if ($_.PnPDeviceID) { [Console]::Out.WriteLine($_.PnPDeviceID) } }",
      ],
      environment: {'VNT_ADAPTER_NAME': adapterName},
    );
    if (lookupResult.exitCode != 0) {
      throw StateError(
        '查询虚拟网卡失败（${lookupResult.exitCode}）：${lookupResult.stderr}',
      );
    }

    final deviceIds = lookupResult.stdout
        .toString()
        .split(RegExp(r'[\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    for (final deviceId in deviceIds) {
      final removeResult = await _processRunner(
        'pnputil.exe',
        ['/remove-device', deviceId],
      );
      if (removeResult.exitCode != 0) {
        throw StateError(
          '删除虚拟网卡失败（${removeResult.exitCode}）：${removeResult.stderr}',
        );
      }
    }
  }
}

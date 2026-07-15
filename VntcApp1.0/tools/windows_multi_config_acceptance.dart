import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/src/rust/frb_generated.dart';
import 'package:vnt_app/vnt/virtual_network_adapter_manager.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

const _configPath = String.fromEnvironment('VNT_ACCEPTANCE_CONFIG');
const _resultPath = String.fromEnvironment('VNT_ACCEPTANCE_RESULT');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final report = <String, dynamic>{
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'phases': <Map<String, dynamic>>[],
  };
  final manager = VntManager();
  final adapterManager = VirtualNetworkAdapterManager();
  final ports = <ReceivePort>[];
  var exitCode = 1;
  List<NetworkConfig> configs = const [];

  try {
    if (!Platform.isWindows) {
      throw StateError('该验收入口仅支持 Windows');
    }
    if (_configPath.isEmpty || _resultPath.isEmpty) {
      throw StateError('缺少 VNT_ACCEPTANCE_CONFIG 或 VNT_ACCEPTANCE_RESULT');
    }

    configs = await _loadConfigs(_configPath);
    if (configs.length != 2) {
      throw StateError('验收配置数量必须为 2，实际为 ${configs.length}');
    }
    final first = configs[0];
    final second = configs[1];
    final firstAdapter = _adapterName(first);
    final secondAdapter = _adapterName(second);

    report['configs'] = configs
        .map(
          (config) => <String, dynamic>{
            'itemKey': config.itemKey,
            'configName': config.configName,
            'adapterName': _adapterName(config),
            'automaticIp': config.virtualIPv4.isEmpty,
            'hasCredential': config.token.isNotEmpty,
            'hasServer': config.v2CompatibleServerList.isNotEmpty ||
                config.v2CompatiblePrimaryServerAddress.isNotEmpty,
          },
        )
        .toList();

    await RustLib.init();
    final firstConnection = _connect(manager, first);
    final secondConnection = _connect(manager, second);
    ports.addAll([firstConnection.port, secondConnection.port]);

    await Future.wait([
      firstConnection.connected,
      secondConnection.connected,
    ]).timeout(const Duration(seconds: 45));
    await Future<void>.delayed(const Duration(seconds: 2));

    final connectedFirst = await _adapterState(firstAdapter);
    final connectedSecond = await _adapterState(secondAdapter);
    _require(connectedFirst != null, '配置 A 的虚拟网卡未创建');
    _require(connectedSecond != null, '配置 B 的虚拟网卡未创建');
    _require(manager.size() == 2, 'VntManager 未同时保留两个连接实例');
    _addPhase(report, 'connected_both', {
      'managerSize': manager.size(),
      'firstAdapter': connectedFirst,
      'secondAdapter': connectedSecond,
      'firstRuntime': _runtimeSummary(manager.get(first.itemKey)),
      'secondRuntime': _runtimeSummary(manager.get(second.itemKey)),
    });

    await adapterManager.deleteForConfig(first);
    final firstRemoved = await _waitForAdapter(firstAdapter, present: false);
    final secondPreserved = await _waitForAdapter(secondAdapter, present: true);
    _require(firstRemoved == null, '精确删除后配置 A 网卡仍然存在');
    _require(secondPreserved != null, '删除配置 A 网卡时误删了配置 B 网卡');
    _addPhase(report, 'deleted_first_adapter_exactly', {
      'firstAdapterExists': false,
      'secondAdapter': secondPreserved,
      'secondConnectionRetained': manager.hasConnectionItem(second.itemKey),
    });

    await manager.remove(first.itemKey);
    await Future<void>.delayed(const Duration(seconds: 1));
    _require(!manager.hasConnectionItem(first.itemKey), '配置 A 未断开');
    _require(manager.hasConnectionItem(second.itemKey), '断开配置 A 影响了配置 B');
    _require(await _adapterState(secondAdapter) != null, '配置 B 网卡意外消失');
    _addPhase(report, 'disconnected_first_only', {
      'managerSize': manager.size(),
      'firstConnected': manager.hasConnectionItem(first.itemKey),
      'secondConnected': manager.hasConnectionItem(second.itemKey),
    });

    await manager.remove(second.itemKey);
    await adapterManager.deleteForConfig(second);
    final secondRemoved = await _waitForAdapter(secondAdapter, present: false);
    _require(secondRemoved == null, '配置 B 断开并清理后网卡仍然存在');
    _require(manager.size() == 0, '全部断开后 VntManager 仍有连接');
    _addPhase(report, 'disconnected_and_cleaned_all', {
      'managerSize': manager.size(),
      'firstAdapterExists': await _adapterState(firstAdapter) != null,
      'secondAdapterExists': false,
    });

    report['success'] = true;
    exitCode = 0;
  } catch (error, stackTrace) {
    report['success'] = false;
    report['error'] = error.toString();
    report['stackTrace'] = stackTrace.toString();
  } finally {
    await manager.removeAll();
    for (final config in configs) {
      try {
        await adapterManager.deleteForConfig(config);
      } catch (_) {}
    }
    for (final port in ports) {
      port.close();
    }
    try {
      RustLib.dispose();
    } catch (_) {}
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    if (_resultPath.isNotEmpty) {
      await File(_resultPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    }
  }

  exit(exitCode);
}

Future<List<NetworkConfig>> _loadConfigs(String configPath) async {
  final decoded = jsonDecode(await File(configPath).readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('配置文件根节点必须为对象');
  }
  final rawItems = decoded['data-key'];
  if (rawItems is! List) {
    throw const FormatException('配置文件缺少 data-key 数组');
  }
  return rawItems.map((rawItem) {
    final item = jsonDecode(rawItem.toString());
    if (item is! Map<String, dynamic>) {
      throw const FormatException('data-key 项必须为 JSON 对象字符串');
    }
    return NetworkConfig.fromJson(item);
  }).toList();
}

({ReceivePort port, Future<void> connected}) _connect(
  VntManager manager,
  NetworkConfig config,
) {
  final port = ReceivePort();
  final completer = Completer<void>();
  port.listen((message) {
    if (message == 'success') {
      if (!completer.isCompleted) {
        completer.complete();
      }
      return;
    }
    if (message == 'stop') {
      if (!completer.isCompleted) {
        completer.completeError(StateError('${config.configName} 在连接前停止'));
      }
      return;
    }
    if (message is RustErrorInfo &&
        message.code != RustErrorType.warn &&
        message.code != RustErrorType.disconnect &&
        !completer.isCompleted) {
      completer.completeError(
        StateError(
            '${config.configName} 连接失败：${message.msg ?? message.code.name}'),
      );
    }
  });

  unawaited(
    manager.create(config, port.sendPort).catchError((Object error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      throw error;
    }),
  );
  return (port: port, connected: completer.future);
}

String _adapterName(NetworkConfig config) {
  return VirtualNetworkAdapterIdentity.managedWindowsAdapterName(
    config.virtualNetworkCardName,
  );
}

Future<Map<String, dynamic>?> _adapterState(String adapterName) async {
  final result = await Process.run(
    'powershell.exe',
    const [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"$adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $env:VNT_ADAPTER_NAME } | Select-Object -First 1 Name,Status,ifIndex,InterfaceGuid; if ($null -ne $adapter) { $adapter | ConvertTo-Json -Compress }",
    ],
    environment: {'VNT_ADAPTER_NAME': adapterName},
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('查询网卡失败（${result.exitCode}）：${result.stderr}');
  }
  final output = result.stdout.toString().trim();
  if (output.isEmpty) {
    return null;
  }
  final decoded = jsonDecode(output);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('网卡查询结果格式错误');
  }
  return decoded;
}

Future<Map<String, dynamic>?> _waitForAdapter(
  String adapterName, {
  required bool present,
}) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final state = await _adapterState(adapterName);
    if ((state != null) == present) {
      return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return _adapterState(adapterName);
}

Map<String, dynamic> _runtimeSummary(VntBox? box) {
  if (box == null) {
    return const {'available': false};
  }
  final current = box.currentDevice();
  return {
    'available': true,
    'status': current['status']?.toString() ?? '',
    'hasVirtualIp': (current['virtualIp']?.toString() ?? '').isNotEmpty,
    'hasConnectedServer':
        (current['connectServer']?.toString() ?? '').isNotEmpty,
  };
}

void _addPhase(
  Map<String, dynamic> report,
  String name,
  Map<String, dynamic> details,
) {
  (report['phases'] as List<Map<String, dynamic>>).add({
    'name': name,
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
    ...details,
  });
}

void _require(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

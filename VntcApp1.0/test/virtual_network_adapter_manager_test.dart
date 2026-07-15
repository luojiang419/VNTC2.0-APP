import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/vnt/virtual_network_adapter_manager.dart';

NetworkConfig _config({
  required String itemKey,
  required String adapterName,
}) {
  return NetworkConfig.fromJson({
    'itemKey': itemKey,
    'config_name': itemKey.isEmpty ? '未命名配置' : itemKey,
    'tun_name': adapterName,
  });
}

void main() {
  test('缺失和重复身份会迁移为稳定且唯一的虚拟网卡名称', () {
    final generatedKeys = ['generated-key-1', 'generated-key-2'].iterator;
    final configs = [
      _config(itemKey: '', adapterName: ''),
      _config(itemKey: 'duplicate-key', adapterName: 'custom!'),
      _config(itemKey: 'duplicate-key', adapterName: 'custom'),
    ];

    final changed = VirtualNetworkAdapterIdentity.normalizeConfigs(
      configs,
      itemKeyFactory: () {
        generatedKeys.moveNext();
        return generatedKeys.current;
      },
    );

    expect(changed, isTrue);
    expect(configs.map((config) => config.itemKey).toSet(), hasLength(3));
    expect(
      configs
          .map(
            (config) => VirtualNetworkAdapterIdentity.managedWindowsAdapterName(
              config.virtualNetworkCardName,
            ),
          )
          .toSet(),
      hasLength(3),
    );
    expect(
      VirtualNetworkAdapterIdentity.normalizeConfigs(configs),
      isFalse,
    );
  });

  test('同一配置键始终生成相同自动网卡名', () {
    final first = VirtualNetworkAdapterIdentity.automaticNameForItemKey(
      '8aa24096-18c2-4d91-a775-c56c53c8aac8',
    );
    final second = VirtualNetworkAdapterIdentity.automaticNameForItemKey(
      '8aa24096-18c2-4d91-a775-c56c53c8aac8',
    );

    expect(first, second);
    expect(first, startsWith('cfg-'));
    expect(
      VirtualNetworkAdapterIdentity.managedWindowsAdapterName(first),
      startsWith('VNT-App-TUN-cfg-'),
    );
  });

  test('删除配置时只按该配置的精确 PnP 设备标识删除 Windows 网卡', () async {
    final calls = <({
      String executable,
      List<String> arguments,
      Map<String, String>? environment,
    })>[];
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    }) async {
      calls.add((
        executable: executable,
        arguments: List<String>.from(arguments),
        environment:
            environment == null ? null : Map<String, String>.from(environment),
      ));
      if (executable == 'powershell.exe') {
        return ProcessResult(
          1,
          0,
          'SWD\\Wintun\\{11111111-1111-1111-1111-111111111111}\r\n',
          '',
        );
      }
      return ProcessResult(2, 0, '', '');
    }

    final manager = VirtualNetworkAdapterManager(
      isWindows: true,
      processRunner: runner,
    );
    await manager.deleteForConfig(
      _config(itemKey: 'config-1', adapterName: 'cfg-config-1'),
    );

    expect(calls, hasLength(2));
    expect(calls.first.executable, 'powershell.exe');
    expect(
      calls.first.environment?['VNT_ADAPTER_NAME'],
      'VNT-App-TUN-cfg-config-1',
    );
    expect(calls.last.executable, 'pnputil.exe');
    expect(calls.last.arguments, [
      '/remove-device',
      r'SWD\Wintun\{11111111-1111-1111-1111-111111111111}',
    ]);
  });

  test('非 Windows 平台删除配置不执行系统命令', () async {
    var called = false;
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    }) async {
      called = true;
      return ProcessResult(1, 0, '', '');
    }

    final manager = VirtualNetworkAdapterManager(
      isWindows: false,
      processRunner: runner,
    );
    await manager.deleteForConfig(
      _config(itemKey: 'config-1', adapterName: 'cfg-config-1'),
    );

    expect(called, isFalse);
  });

  test('核心创建网卡时不再清理其他配置的已断开网卡', () async {
    final source = await File(
      'vendor/vnt-core-2.0.0/src/tun/general.rs',
    ).readAsString();

    expect(source, isNot(contains('cleanup_inactive_managed_windows_tuns')));
    expect(source, contains('managed_windows_tun_name'));
  });
}

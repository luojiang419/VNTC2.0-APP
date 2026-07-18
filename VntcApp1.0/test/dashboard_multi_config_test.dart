import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/widgets/dashboard_config_panel.dart';

NetworkConfig _config(String key, String name) {
  return NetworkConfig.fromJson({
    'itemKey': key,
    'config_name': name,
    'device_name': '设备-$name',
    'server_address': 'server-$key.example.com:29872',
  });
}

void main() {
  test('批量连接结果会保留每个配置的独立失败原因', () {
    final result = DashboardBatchConnectResult(
      requestedCount: 3,
      startedCount: 1,
      alreadyConnectedCount: 1,
      failures: const {'配置 C': 'Token 错误'},
    );

    expect(result.hasFailures, isTrue);
    expect(result.failures, {'配置 C': 'Token 错误'});
    expect(result.summary, contains('已发起 1 个连接'));
    expect(result.summary, contains('1 个失败'));
    expect(
      () => result.failures['配置 D'] = '不可修改',
      throwsUnsupportedError,
    );
  });

  testWidgets('多配置面板展示移动端限制并提供连接、编辑和拖拽排序', (tester) async {
    final configs = <NetworkConfig>[
      _config('config-a', '配置 A'),
      _config('config-b', '配置 B'),
    ];
    final connected = <String>[];
    final savedOrders = <List<String>>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: DashboardConfigPanel(
            configs: configs,
            supportsMultipleConnections: false,
            onConnect: (config) async {
              connected.add(config.itemKey);
              return DashboardConfigActionResult.success(
                '[${config.configName}] 已发起连接',
              );
            },
            onDisconnect: (config) async => DashboardConfigActionResult.success(
              '[${config.configName}] 已断开',
            ),
            onEdit: (config) async =>
                _config(config.itemKey, '${config.configName}-已编辑'),
            onReorder: (orderedConfigs) async {
              savedOrders.add(
                orderedConfigs.map((config) => config.itemKey).toList(),
              );
            },
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('dashboard-single-vpn-notice')),
      findsOneWidget,
    );
    expect(find.text('配置 A'), findsOneWidget);
    expect(find.text('配置 B'), findsOneWidget);
    expect(find.text('新建配置'), findsOneWidget);
    expect(find.text('导入配置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dashboard-config-drag-config-a')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('dashboard-config-connect-config-a')),
    );
    await tester.pump();
    expect(connected, ['config-a']);
    expect(find.text('[配置 A] 已发起连接'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('dashboard-config-edit-config-b')),
    );
    await tester.pump();
    expect(find.text('配置 B-已编辑'), findsOneWidget);

    final dragHandle =
        find.byKey(const ValueKey('dashboard-config-drag-config-a'));
    await tester.drag(
      dragHandle,
      const Offset(0, 360),
      kind: PointerDeviceKind.mouse,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    expect(savedOrders, isNotEmpty);
    expect(savedOrders.last, ['config-b', 'config-a']);
    expect(tester.takeException(), isNull);
  });
}

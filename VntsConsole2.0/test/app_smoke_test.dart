import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/app/app.dart';
import 'package:vnts_console/app/app_controller.dart';

void main() {
  testWidgets('增强控制台应用壳可以渲染并导航', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const VntsConsoleApp());

    expect(find.text('VNTS 2.0 增强控制台'), findsOneWidget);
    expect(find.text('控制台壳层已就绪'), findsOneWidget);
    expect(find.byKey(const Key('navigation-expanded')), findsOneWidget);

    await tester.tap(find.byKey(const Key('route-networks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-management-page')), findsOneWidget);
    expect(find.textContaining('管理接口尚未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('route-serviceControl')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('service-control-page')), findsOneWidget);
    expect(find.text('运维脚本不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('route-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    expect(find.byKey(const Key('desktop-behavior-card')), findsOneWidget);
    expect(find.text('默认关闭行为'), findsOneWidget);
    expect(find.text('开机自启行为'), findsOneWidget);
    expect(find.textContaining('未发现便携 data/config.toml'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口自动折叠侧栏且无布局溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(920, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const VntsConsoleApp());
    expect(find.byKey(const Key('navigation-collapsed')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最小支持窗口尺寸保持完整布局', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const VntsConsoleApp());
    expect(find.byKey(const Key('navigation-expanded')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('主题模式无需重启即可切换', (tester) async {
    final controller = AppController(themeMode: ThemeMode.light);
    addTearDown(controller.dispose);
    await tester.pumpWidget(VntsConsoleApp(controller: controller));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );

    controller.setThemeMode(ThemeMode.dark);
    controller.setDashboardPollSeconds(2);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(controller.dashboardPollSeconds, 2);
  });
}

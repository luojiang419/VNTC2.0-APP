import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('仪表盘提供添加配置、模式切换和设置入口', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(source, contains("label: const Text('添加配置')"));
    expect(
      source,
      contains("ValueKey('dashboard-professional-mode-switch')"),
    );
    expect(source, contains("ValueKey('dashboard-settings-button')"));
    expect(source, contains('if (widget.isProfessionalMode)'));
  });

  test('进入专业模式前展示风险提示', () {
    final source =
        File('lib/pages/main_navigation_shell.dart').readAsStringSync();

    expect(
      source,
      contains('除非你知道自己在做什么，否则最纯粹的虚拟组网体验更适合你'),
    );
  });

  test('专业仪表盘不再提供底部新建配置和系统设置快捷按钮', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(source, isNot(contains('_buildQuickActions')));
    expect(source, isNot(contains("label: '系统设置'")));
  });

  test('极简仪表盘使用窄边距紧凑布局并填充默认窗口剩余高度', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(
      source,
      contains("ValueKey('regular-dashboard-compact-layout')"),
    );
    expect(source, contains("ValueKey('regular-dashboard-bento-grid')"));
    expect(source, contains('SliverFillRemaining('));
    expect(source, contains('final pagePadding = context.spacing(12)'));
    expect(source, contains('viewport.maxHeight >= 500'));
  });

  test('无配置时只展示居中加号提示并直接打开配置编辑器', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(source, contains("ValueKey('regular-dashboard-empty-state')"));
    expect(
      source,
      contains("ValueKey('regular-dashboard-empty-add-button')"),
    );
    expect(source, contains('请点击 + 号添加配置'));
    expect(source, contains('await widget.onCreateConfig?.call()'));
    expect(source, isNot(contains('常规模式新手引导')));
  });

  test('610 宽度下仪表盘标题和三个操作按钮保持同一行', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(source, contains('constraints.maxWidth < 540'));
    expect(source, contains('crossAxisAlignment: CrossAxisAlignment.center'));
  });

  test('未连接卡片明确提示点击后链接全部服务器', () {
    final source = File('lib/pages/dashboard_page.dart').readAsStringSync();

    expect(source, contains('点击卡片即可链接全部添加的服务器'));
    expect(source, isNot(contains('可一键连接全部')));
  });

  test('首次保存配置后按屏幕分辨率调整极简窗口', () {
    final source =
        File('lib/pages/main_navigation_shell.dart').readAsStringSync();

    expect(source, contains('final wasEmpty = configs.isEmpty'));
    expect(source, contains('DashboardWindowSizing.regularSizeForDisplay'));
    expect(
        source, contains('if (wasEmpty && !_experienceMode.isProfessional)'));
  });

  test('极简设置页隐藏高级分区并为开关提供呼吸微光', () {
    final source = File('lib/pages/settings_page.dart').readAsStringSync();

    expect(source, contains('if (widget.isProfessionalMode)'));
    expect(source, contains('Widget _buildGlowSwitch'));
    expect(source, contains('pulse: true'));
    expect(source, contains("ValueKey('settings-back-button')"));
  });

  test('Android、macOS 与 Linux 共用极简和专业模式入口', () {
    final dashboard = File('lib/pages/dashboard_page.dart').readAsStringSync();
    final shell =
        File('lib/pages/main_navigation_shell.dart').readAsStringSync();

    expect(dashboard, contains("'极简模式'"));
    expect(dashboard, contains("'专业模式'"));
    expect(
      dashboard,
      contains("ValueKey('dashboard-professional-mode-switch')"),
    );
    expect(shell, contains('Platform.isMacOS || Platform.isLinux'));
    expect(shell, contains('final showProfessionalNavigation ='));
  });
}

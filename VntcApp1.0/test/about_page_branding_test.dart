import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('关于入口和页面使用同一个运行时品牌开关', () {
    final source = File(
      'lib/pages/main_navigation_shell.dart',
    ).readAsStringSync();

    expect(source, contains('AppVersion.showAboutPage'));
    expect(RegExp(r'if \(_showAboutPage\)').allMatches(source), hasLength(2));
    expect(source, contains('if (_showAboutPage) const AboutPage()'));
  });

  test('侧栏、关于页和更新器标题统一使用运行时品牌名称', () {
    final navigation = File(
      'lib/pages/main_navigation_shell.dart',
    ).readAsStringSync();
    final about = File('lib/pages/about_page.dart').readAsStringSync();
    final updater = File('lib/update/app_updater_page.dart').readAsStringSync();

    expect(navigation, contains('AppVersion.productName'));
    expect(navigation, isNot(contains("'VNT',")));
    expect(about, contains('AppVersion.productName'));
    expect(about, isNot(contains("'VNT APP'")));
    expect(updater, contains("'\${AppVersion.productName} 更新'"));
    expect(updater, isNot(contains("'VNTC APP2.0 更新'")));
  });
}

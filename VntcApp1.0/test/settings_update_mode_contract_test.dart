import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('设置页提供更新三态选择并在关闭时禁用立即检查', () {
    final source = File('lib/pages/settings_page.dart').readAsStringSync();

    expect(source, contains("title: '更新方式'"));
    expect(source, contains("key: const ValueKey('app-update-mode-selector')"));
    expect(source, contains('items: AppUpdateMode.values'));
    expect(source, contains("title: '立即检查更新'"));
    expect(
      source,
      contains('onTap: _updateMode.checksForUpdates'),
    );
    expect(source, contains('await _updatePreferences.saveMode(mode)'));
  });
}

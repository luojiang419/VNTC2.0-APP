import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/data_persistence.dart';

void main() {
  test('DataPersistence Windows 导入设置会转换为一次批量写入计划', () {
    final result = DataPersistence.buildWindowsImportValuesForTesting({
      'window_size': {'width': 1024, 'height': 768.5},
      'window_position': {'x': 12.5, 'y': 24},
      'theme_mode': 1,
      'custom_theme_color': 0xff112233,
      'auto_start': true,
      'silent_start': false,
      'auto_connect': true,
      'default_key': 'config-a',
      'close_app': null,
      'always_on_top': true,
    });

    final values = result['values'] as Map<String, dynamic>;
    final removeKeys = List<String>.from(result['removeKeys'] as List);

    expect(values['window-width'], 1024.0);
    expect(values['window-height'], 768.5);
    expect(values['window-x'], 12.5);
    expect(values['window-y'], 24.0);
    expect(values['theme-mode'], 1);
    expect(values['custom-theme-color'], 0xff112233);
    expect(values['is-auto-start'], isTrue);
    expect(values['is-silent-start'], isFalse);
    expect(values['is-auto-connect'], isTrue);
    expect(values['default-key'], 'config-a');
    expect(values['is-always-on-top'], isTrue);
    expect(removeKeys, ['is-close-app']);
  });

  test('DataPersistence Windows 导入设置会在写入前拒绝无效字段', () {
    expect(
      () => DataPersistence.buildWindowsImportValuesForTesting({
        'auto_start': 'true',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DataPersistence.buildWindowsImportValuesForTesting({
        'theme_mode': 999,
      }),
      throwsA(isA<RangeError>()),
    );
  });
}

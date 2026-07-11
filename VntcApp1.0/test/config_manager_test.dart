import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/config_manager.dart';

void main() {
  test('ConfigManager setValues 会批量写入并移除指定键', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vnt_config_manager_test_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File('${directory.path}${Platform.pathSeparator}config.json');
    final manager = ConfigManager.forTesting(file);

    await manager.setString('old-key', 'old-value');
    await manager.setValues(
      {
        'name': 'vnt',
        'items': ['a', 'b'],
        'enabled': true,
      },
      removeKeys: ['old-key'],
    );

    expect(manager.getString('old-key'), isNull);
    expect(manager.getString('name'), 'vnt');
    expect(manager.getStringList('items'), ['a', 'b']);
    expect(manager.getBool('enabled'), isTrue);

    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(decoded['old-key'], isNull);
    expect(decoded['name'], 'vnt');
    expect(decoded['items'], ['a', 'b']);
    expect(decoded['enabled'], isTrue);
  });

  test('ConfigManager 写入失败会抛错并回滚内存缓存', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vnt_config_manager_fail_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final manager = ConfigManager.forTesting(File(directory.path));

    await expectLater(
      manager.setString('key', 'value'),
      throwsA(isA<FileSystemException>()),
    );

    expect(manager.getString('key'), isNull);
  });
}

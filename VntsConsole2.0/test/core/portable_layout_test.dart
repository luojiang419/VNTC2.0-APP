import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/platform/portable_layout.dart';

void main() {
  test('增强版不会发现相邻轻量项目的脚本和 data 根目录', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'vnts2-layout-isolation-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final enhancedDirectory = Directory(
      '${workspace.path}${Platform.pathSeparator}VntsConsole2.0'
      '${Platform.pathSeparator}build${Platform.pathSeparator}Release',
    );
    await enhancedDirectory.create(recursive: true);
    final lightRoot = Directory(
      '${workspace.path}${Platform.pathSeparator}vnts2.0服务端开发包'
      '${Platform.pathSeparator}windows-deploy',
    );
    await lightRoot.create(recursive: true);
    for (final script in PortableLayout.requiredScripts) {
      await File('${lightRoot.path}${Platform.pathSeparator}$script').create();
    }

    final discovered = PortableLayout.discover(
      executablePath:
          '${enhancedDirectory.path}${Platform.pathSeparator}VNTS2-Console.exe',
    );

    expect(discovered, isNull);
    expect(
      PortableLayout.discover(overrideRoot: lightRoot.path)?.root.path,
      lightRoot.absolute.path,
    );
  });
}

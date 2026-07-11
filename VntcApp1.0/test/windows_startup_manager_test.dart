import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/windows_startup_manager.dart';

void main() {
  test('Windows 开机自启使用当前用户注册表且不要求管理员权限', () async {
    final calls = <({String executable, List<String> arguments})>[];
    final manager = WindowsStartupManager(
      processRunner: (executable, arguments) async {
        calls.add((executable: executable, arguments: arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    await manager.setEnabled(
      enabled: true,
      executablePath: r'C:\Program Files\VNT App\vnt_app.exe',
      silentStart: true,
    );

    expect(calls.first.executable, 'schtasks.exe');
    expect(calls.last.executable, 'reg.exe');
    expect(calls.last.arguments, contains(WindowsStartupManager.registryPath));
    expect(
      calls.last.arguments,
      contains(r'"C:\Program Files\VNT App\vnt_app.exe" --silent'),
    );
    expect(calls.expand((call) => call.arguments), isNot(contains('Highest')));
  });

  test('Windows 开机自启只在注册表指向当前程序时回报已启用', () async {
    final manager = WindowsStartupManager(
      processRunner: (executable, arguments) async => ProcessResult(
        1,
        0,
        '${WindowsStartupManager.registryValueName} REG_SZ '
            r'"C:\Program Files\VNT App\vnt_app.exe" --silent',
        '',
      ),
    );

    expect(
      await manager.isEnabled(r'C:\Program Files\VNT App\vnt_app.exe'),
      isTrue,
    );
    expect(
      await manager.isEnabled(r'D:\old\vnt_app.exe'),
      isFalse,
    );
  });

  test('Windows 开机自启写入失败时向调用方报告失败', () async {
    final manager = WindowsStartupManager(
      processRunner: (executable, arguments) async => executable == 'reg.exe'
          ? ProcessResult(1, 5, '', 'Access is denied')
          : ProcessResult(1, 0, '', ''),
    );

    await expectLater(
      manager.setEnabled(
        enabled: true,
        executablePath: r'C:\VNT\vnt_app.exe',
        silentStart: false,
      ),
      throwsA(isA<StateError>()),
    );
  });
}

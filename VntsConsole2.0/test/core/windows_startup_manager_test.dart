import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/platform/desktop_behavior.dart';
import 'package:vnts_console/core/platform/windows_startup_manager.dart';

void main() {
  test('普通与静默自启使用登录触发的最高权限计划任务', () {
    final normal = WindowsStartupManager.createArguments(
      AppStartupBehavior.normal,
      r'C:\Program Files\VNTS2\VNTS2-Console.exe',
    );
    final silent = WindowsStartupManager.createArguments(
      AppStartupBehavior.silentToTray,
      r'C:\Program Files\VNTS2\VNTS2-Console.exe',
    );

    expect(normal, containsAllInOrder(['/SC', 'ONLOGON', '/RL', 'HIGHEST']));
    expect(normal.last, isNot(endsWith('--silent')));
    expect(silent.last, endsWith('--silent'));
    expect(silent.last, startsWith('"'));
  });

  test('关闭自启只在任务存在时删除', () async {
    final calls = <List<String>>[];
    final manager = WindowsStartupManager(
      executablePath: r'C:\VNTS2\VNTS2-Console.exe',
      runner: (arguments) async {
        calls.add(List.of(arguments));
        return const StartupProcessResult(exitCode: 0);
      },
    );

    await manager.apply(AppStartupBehavior.disabled);

    expect(calls, [
      WindowsStartupManager.queryArguments(),
      WindowsStartupManager.deleteArguments(),
    ]);
  });

  test('创建计划任务失败时返回可操作错误', () async {
    final manager = WindowsStartupManager(
      executablePath: r'C:\VNTS2\VNTS2-Console.exe',
      runner: (_) async =>
          const StartupProcessResult(exitCode: 5, stderr: 'Access is denied'),
    );

    await expectLater(
      manager.apply(AppStartupBehavior.normal),
      throwsA(
        isA<WindowsStartupException>().having(
          (error) => error.message,
          'message',
          allOf(contains('退出码 5'), contains('Access is denied')),
        ),
      ),
    );
  });
}

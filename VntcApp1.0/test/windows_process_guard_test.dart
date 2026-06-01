import 'package:test/test.dart';
import 'package:vnt_app/utils/windows_process_guard.dart';

void main() {
  group('WindowsProcessGuard', () {
    test('parses both single object and list payloads from PowerShell', () {
      final single = parseWindowsProcessList(
        '{"ProcessId":1234,"ExecutablePath":"C:\\\\Apps\\\\vnt_app.exe"}',
      );
      final list = parseWindowsProcessList(
        '[{"ProcessId":1234,"ExecutablePath":"C:\\\\Apps\\\\vnt_app.exe"},'
        '{"ProcessId":5678,"ExecutablePath":"D:\\\\Other\\\\vnt_app.exe"}]',
      );

      expect(single.map((item) => item.pid), [1234]);
      expect(list.map((item) => item.pid), [1234, 5678]);
    });

    test('selectOldWindowsProcesses excludes current process only', () {
      final processes = [
        const WindowsProcessInfo(
          pid: 100,
          executablePath: r'C:\Apps\vnt_app.exe',
        ),
        const WindowsProcessInfo(
          pid: 200,
          executablePath: r'D:\Myproject\vnt2.0\VntcApp1.0\output\vnt_app.exe',
        ),
        const WindowsProcessInfo(
          pid: 300,
          executablePath: r'D:\Myproject\vnt2.0\VntcApp1.0\dist\vnt_app.exe',
        ),
      ];

      final targets = selectOldWindowsProcesses(processes, currentPid: 200);

      expect(targets.map((item) => item.pid), [100, 300]);
    });
  });
}

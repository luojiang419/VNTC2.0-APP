import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/rustdesk_runtime.dart';

void main() {
  final runtime = RustDeskRuntime.instance;
  final tempDirs = <Directory>[];

  Future<Directory> createManagedRoot() async {
    final directory = await Directory.systemTemp.createTemp(
      'rustdesk-runtime-test-',
    );
    tempDirs.add(directory);
    return directory;
  }

  tearDown(() async {
    runtime.debugLocateExecutablePath = null;
    runtime.debugLocateInstalledExecutablePath = null;
    runtime.debugStartProcess = null;
    runtime.debugRunProcess = null;
    runtime.debugIsLocalPortListening = null;
    runtime.debugSleep = null;
    runtime.debugEnsureDirectAccessConfig = null;
    runtime.debugManagedRootPath = null;
    runtime.debugManagedEnvironment = null;
    for (final directory in tempDirs) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    tempDirs.clear();
  });

  group('RustDesk config helpers', () {
    test('upsertRustDeskOption 会在缺少 options 段时自动创建', () {
      final updated = upsertRustDeskOption("id = 'abc'", 'direct-server', 'Y');

      expect(updated, contains('[options]'));
      expect(updated, contains("direct-server = 'Y'"));
    });

    test('removeRustDeskOption 会删除 options 段中的指定项', () {
      const content = '''
[options]
direct-server = 'Y'
default-connect-password = 'secret'
''';

      final updated = removeRustDeskOption(
        content,
        'default-connect-password',
      );

      expect(updated, contains("direct-server = 'Y'"));
      expect(updated, isNot(contains('default-connect-password')));
    });
  });

  group('matchesWindowsListeningPort', () {
    test('识别 netstat 中的 LISTENING 端口且不抛正则异常', () {
      const output = '''
  TCP    0.0.0.0:21118        0.0.0.0:0              LISTENING       1234
  TCP    127.0.0.1:23100      0.0.0.0:0              LISTENING       5678
''';

      expect(
        () => matchesWindowsListeningPort(output, 21118),
        returnsNormally,
      );
      expect(matchesWindowsListeningPort(output, 21118), isTrue);
      expect(matchesWindowsListeningPort(output, 21119), isFalse);
    });
  });

  group('ensureHostReady', () {
    test('使用 bundled runtime 写入直连配置和会话密码，并只拉起内置 host', () async {
      final root = await createManagedRoot();
      final startedExecutables = <String>[];
      final startedArgs = <List<String>>[];
      final runExecutables = <String>[];
      final runArgs = <List<String>>[];
      var probeCount = 0;

      runtime.debugLocateExecutablePath = () async => r'G:\dist\rustdesk.exe';
      runtime.debugLocateInstalledExecutablePath =
          () async => r'C:\Program Files\RustDesk\RustDesk.exe';
      runtime.debugManagedRootPath = () async => root.path;
      runtime.debugRunProcess = (executablePath, args, __) async {
        runExecutables.add(executablePath);
        runArgs.add(List<String>.from(args));
        return ProcessResult(100, 0, '', '');
      };
      runtime.debugStartProcess = (executablePath, args, __) async {
        startedExecutables.add(executablePath);
        startedArgs.add(List<String>.from(args));
      };
      runtime.debugSleep = (_) async {};
      runtime.debugIsLocalPortListening = (_) async {
        probeCount++;
        return probeCount >= 3;
      };

      await runtime.ensureHostReady(
        listenPort: 21118,
        sessionToken: 'SessionPass42',
      );

      expect(runExecutables, [r'G:\dist\rustdesk.exe']);
      expect(runArgs, [
        ['--password', 'SessionPass42'],
      ]);
      expect(startedExecutables, [r'G:\dist\rustdesk.exe']);
      expect(startedArgs, [
        ['--server'],
      ]);

      final config = await File(
        '${root.path}/appdata/RustDesk/config/RustDesk.toml',
      ).readAsString();
      expect(config, contains("direct-server = 'Y'"));
      expect(config, contains("direct-access-port = '21118'"));
      expect(config, contains("approve-mode = 'password'"));
      expect(
          config, contains("verification-method = 'use-permanent-password'"));
      expect(config, isNot(contains('default-connect-password')));
    });

    test('bundled runtime 缺失时不会回退到系统安装版', () async {
      final startedArgs = <List<String>>[];
      runtime.debugLocateExecutablePath = () async => null;
      runtime.debugLocateInstalledExecutablePath =
          () async => r'C:\Program Files\RustDesk\RustDesk.exe';
      runtime.debugRunProcess = (_, __, ___) async {
        startedArgs.add(const ['--password']);
        return ProcessResult(100, 0, '', '');
      };
      runtime.debugStartProcess = (_, args, __) async {
        startedArgs.add(List<String>.from(args));
      };
      runtime.debugSleep = (_) async {};
      runtime.debugIsLocalPortListening = (_) async => startedArgs.isNotEmpty;

      await expectLater(
        () => runtime.ensureHostReady(
          listenPort: 21118,
          sessionToken: 'SessionPass42',
        ),
        throwsA(isA<RustDeskHostNotReadyException>()),
      );

      expect(startedArgs, isEmpty);
      expect(await runtime.isAvailable(), isFalse);
    });

    test('外部进程已占用监听端口时直接失败，不误判为就绪', () async {
      runtime.debugLocateExecutablePath = () async => r'G:\dist\rustdesk.exe';
      runtime.debugManagedRootPath =
          () async => (await createManagedRoot()).path;
      runtime.debugRunProcess =
          (_, __, ___) async => ProcessResult(100, 0, '', '');
      runtime.debugIsLocalPortListening = (_) async => true;

      await expectLater(
        () => runtime.ensureHostReady(
          listenPort: 21118,
          sessionToken: 'SessionPass42',
        ),
        throwsA(
          isA<RustDeskHostNotReadyException>().having(
            (error) => error.attempts,
            'attempts',
            contains('listen-port-occupied-by-external-process'),
          ),
        ),
      );
    });
  });

  group('openRemoteDesktop', () {
    test('控制端只使用 bundled runtime 写入默认密码并建立连接', () async {
      final root = await createManagedRoot();
      final startedExecutables = <String>[];
      final startedArgs = <List<String>>[];

      runtime.debugLocateExecutablePath = () async => r'G:\dist\rustdesk.exe';
      runtime.debugLocateInstalledExecutablePath =
          () async => r'C:\Program Files\RustDesk\RustDesk.exe';
      runtime.debugManagedRootPath = () async => root.path;
      runtime.debugStartProcess = (executablePath, args, __) async {
        startedExecutables.add(executablePath);
        startedArgs.add(List<String>.from(args));
      };

      await runtime.openRemoteDesktop(
        targetAddress: '10.0.0.2:21118',
        sessionToken: 'SessionPass42',
      );

      expect(startedExecutables, [r'G:\dist\rustdesk.exe']);
      expect(startedArgs, [
        ['--connect', '10.0.0.2:21118'],
      ]);

      final config = await File(
        '${root.path}/appdata/RustDesk/config/RustDesk.toml',
      ).readAsString();
      expect(config, contains("default-connect-password = 'SessionPass42'"));
      expect(config, contains("direct-access-port = '21118'"));
    });

    test('bundled runtime 缺失时不会回退到系统安装版建立连接', () async {
      runtime.debugLocateExecutablePath = () async => null;
      runtime.debugLocateInstalledExecutablePath =
          () async => r'C:\Program Files\RustDesk\RustDesk.exe';

      await expectLater(
        () => runtime.openRemoteDesktop(
          targetAddress: '10.0.0.2:21118',
          sessionToken: 'SessionPass42',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('cleanupManagedSessionState 会清理控制端密码并恢复点击确认模式', () async {
    final root = await createManagedRoot();
    runtime.debugManagedRootPath = () async => root.path;

    final configFile =
        File('${root.path}/appdata/RustDesk/config/RustDesk.toml');
    await configFile.parent.create(recursive: true);
    await configFile.writeAsString('''
[options]
direct-server = 'Y'
direct-access-port = '21118'
approve-mode = 'password'
verification-method = 'use-permanent-password'
default-connect-password = 'SessionPass42'
''');

    await runtime.cleanupManagedSessionState(listenPort: 21118);

    final updated = await configFile.readAsString();
    expect(updated, contains("approve-mode = 'click'"));
    expect(updated, contains("verification-method = 'use-temporary-password'"));
    expect(updated, isNot(contains('default-connect-password')));
  });

  test('受管环境变量不再覆盖 USERPROFILE 和 HOME', () async {
    runtime.debugManagedRootPath = () async => r'C:\Managed\RustDesk';

    final environment = await runtime.debugResolveManagedEnvironmentForTest();

    expect(environment['APPDATA'], r'C:\Managed\RustDesk\appdata');
    expect(environment['LOCALAPPDATA'], r'C:\Managed\RustDesk\localappdata');
    expect(environment['TEMP'], r'C:\Managed\RustDesk\temp');
    expect(environment['TMP'], r'C:\Managed\RustDesk\temp');
    expect(environment.containsKey('HOME'), isFalse);
  });
}

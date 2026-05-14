import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

class RustDeskRuntime {
  RustDeskRuntime._();

  static final RustDeskRuntime instance = RustDeskRuntime._();

  static const String runtimeDirectoryName = 'rustdesk_runtime';
  static const String executableName = 'rustdesk.exe';

  Future<String?> locateExecutablePath() async {
    final candidates = <String>[];
    final executableDir = path.dirname(Platform.resolvedExecutable);
    candidates.add(
      path.join(executableDir, runtimeDirectoryName, executableName),
    );
    candidates.add(
      path.join(
        Directory.current.path,
        'third_party',
        'rustdesk',
        'windows',
        'runtime',
        executableName,
      ),
    );
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  Future<bool> isAvailable() async {
    return await locateExecutablePath() != null;
  }

  Future<void> ensureTrayProcess() async {
    final executablePath = await locateExecutablePath();
    if (executablePath == null) {
      throw StateError('RustDesk 运行时未找到');
    }
    await Process.start(
      executablePath,
      const ['--tray'],
      workingDirectory: path.dirname(executablePath),
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> openRemoteDesktop({
    required String targetAddress,
  }) async {
    final executablePath = await locateExecutablePath();
    if (executablePath == null) {
      throw StateError('RustDesk 运行时未找到');
    }
    await Process.start(
      executablePath,
      ['--connect', targetAddress],
      workingDirectory: path.dirname(executablePath),
      mode: ProcessStartMode.detached,
    );
  }
}

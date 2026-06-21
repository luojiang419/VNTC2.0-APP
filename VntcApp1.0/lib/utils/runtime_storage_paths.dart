import 'dart:io';

import 'package:path/path.dart' as path;

class RuntimeStoragePaths {
  RuntimeStoragePaths._();

  static const String windowsAppFolderName = 'VNT App 2.0';
  static const String _writeProbeFileName = '.vnt_write_probe.tmp';

  static String resolveWindowsWritableRootPath({
    required String executablePath,
    required String? localAppDataPath,
    required String fallbackBasePath,
    required bool Function(String directoryPath) canWriteToDirectory,
  }) {
    final executableDir = path.windows.dirname(executablePath);
    if (canWriteToDirectory(executableDir)) {
      return executableDir;
    }

    final fallbackBase =
        (localAppDataPath != null && localAppDataPath.isNotEmpty)
            ? localAppDataPath
            : fallbackBasePath;
    return path.windows.join(fallbackBase, windowsAppFolderName);
  }

  static String resolveRuntimeRootPathSync() {
    if (!Platform.isWindows) {
      return Directory.current.path;
    }

    return resolveWindowsWritableRootPath(
      executablePath: Platform.resolvedExecutable,
      localAppDataPath: Platform.environment['LOCALAPPDATA'],
      fallbackBasePath: Directory.systemTemp.path,
      canWriteToDirectory: canWriteToDirectorySync,
    );
  }

  static String resolveConfigDirectoryPathSync() {
    return path.join(resolveRuntimeRootPathSync(), 'config');
  }

  static String resolveLogsDirectoryPathSync() {
    return path.join(resolveRuntimeRootPathSync(), 'logs');
  }

  static String resolveBundledPathSync(String relativePath) {
    return resolveBundledPathForExecutable(
      executablePath: Platform.resolvedExecutable,
      relativePath: relativePath,
      isMacOS: Platform.isMacOS,
    );
  }

  static String resolveBundledPathForExecutable({
    required String executablePath,
    required String relativePath,
    required bool isMacOS,
  }) {
    if (isMacOS) {
      final resourcesPath = resolveMacosResourcesPathForExecutable(
        executablePath,
      );
      if (resourcesPath != null) {
        return path.join(resourcesPath, relativePath);
      }
    }

    final executableDir = path.dirname(executablePath);
    return path.join(executableDir, relativePath);
  }

  static String? resolveMacosResourcesPathForExecutable(
    String executablePath,
  ) {
    final executableDir = path.dirname(executablePath);
    final contentsDir = path.dirname(executableDir);
    if (path.basename(contentsDir) != 'Contents') {
      return null;
    }
    return path.join(contentsDir, 'Resources');
  }

  static bool canWriteToDirectorySync(String directoryPath) {
    try {
      final directory = Directory(directoryPath);
      if (!directory.existsSync()) {
        return false;
      }
      final probeFile = File(path.join(directory.path, _writeProbeFileName));
      probeFile.writeAsStringSync('probe', flush: true);
      if (probeFile.existsSync()) {
        probeFile.deleteSync();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

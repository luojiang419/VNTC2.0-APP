import 'dart:io';

import 'package:path/path.dart' as path;

class RuntimeStoragePaths {
  RuntimeStoragePaths._();

  static const String windowsAppFolderName = 'VNT App 2.0';
  static const String windowsMachineFolderName = 'VNTC APP2.0';
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

  static String resolveWindowsMachineRootPath({
    required String? programDataPath,
    required String systemDrivePath,
  }) {
    final basePath =
        programDataPath != null && programDataPath.trim().isNotEmpty
            ? programDataPath.trim()
            : path.windows.join(systemDrivePath, 'ProgramData');
    return path.windows.join(basePath, windowsMachineFolderName);
  }

  static String resolveWindowsMachineRootPathSync() {
    if (!Platform.isWindows) {
      throw UnsupportedError('机器级 VNT 服务目录仅支持 Windows');
    }
    final systemDrive = Platform.environment['SystemDrive']?.trim();
    return resolveWindowsMachineRootPath(
      programDataPath: Platform.environment['PROGRAMDATA'],
      systemDrivePath:
          systemDrive == null || systemDrive.isEmpty ? r'C:\' : systemDrive,
    );
  }

  static String resolveConfigDirectoryPathSync() {
    return path.join(resolveRuntimeRootPathSync(), 'config');
  }

  static String resolveLogsDirectoryPathSync() {
    return path.join(resolveRuntimeRootPathSync(), 'logs');
  }

  static String resolveDataDirectoryPathSync() {
    return path.join(resolveRuntimeRootPathSync(), 'data');
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
      final normalizedExecutablePath = executablePath.replaceAll('\\', '/');
      final resourcesPath = resolveMacosResourcesPathForExecutable(
        normalizedExecutablePath,
      );
      if (resourcesPath != null) {
        return path.posix.join(resourcesPath, relativePath);
      }
      final executableDir = path.posix.dirname(normalizedExecutablePath);
      return path.posix.join(executableDir, relativePath);
    }

    final executableDir = path.dirname(executablePath);
    return path.join(executableDir, relativePath);
  }

  static String? resolveMacosResourcesPathForExecutable(
    String executablePath,
  ) {
    final executableDir = path.posix.dirname(executablePath);
    final contentsDir = path.posix.dirname(executableDir);
    if (path.posix.basename(contentsDir) != 'Contents') {
      return null;
    }
    return path.posix.join(contentsDir, 'Resources');
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

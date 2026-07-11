import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:vnt_app/utils/runtime_storage_paths.dart';

void main() {
  group('RuntimeStoragePaths.resolveWindowsWritableRootPath', () {
    test('uses executable directory when it is writable', () {
      final resolved = RuntimeStoragePaths.resolveWindowsWritableRootPath(
        executablePath: r'C:\Program Files\VNT App 2.0\vnt_app.exe',
        localAppDataPath: r'C:\Users\Test\AppData\Local',
        fallbackBasePath: r'C:\Temp',
        canWriteToDirectory: (directoryPath) =>
            directoryPath == r'C:\Program Files\VNT App 2.0',
      );

      expect(resolved, r'C:\Program Files\VNT App 2.0');
    });

    test('falls back to LocalAppData when executable directory is read-only',
        () {
      final resolved = RuntimeStoragePaths.resolveWindowsWritableRootPath(
        executablePath: r'C:\Program Files\VNT App 2.0\vnt_app.exe',
        localAppDataPath: r'C:\Users\Test\AppData\Local',
        fallbackBasePath: r'C:\Temp',
        canWriteToDirectory: (_) => false,
      );

      expect(
        resolved,
        path.windows.join(r'C:\Users\Test\AppData\Local', 'VNT App 2.0'),
      );
    });

    test(
        'falls back to provided temp directory when LocalAppData is unavailable',
        () {
      final resolved = RuntimeStoragePaths.resolveWindowsWritableRootPath(
        executablePath: r'D:\Apps\VNT\vnt_app.exe',
        localAppDataPath: null,
        fallbackBasePath: r'D:\Temp',
        canWriteToDirectory: (_) => false,
      );

      expect(resolved, path.windows.join(r'D:\Temp', 'VNT App 2.0'));
    });
  });

  group('RuntimeStoragePaths.resolveBundledPathForExecutable', () {
    test('uses Contents/Resources for macOS app bundles', () {
      final resolved = RuntimeStoragePaths.resolveBundledPathForExecutable(
        executablePath: '/Applications/vnt_app.app/Contents/MacOS/vnt_app',
        relativePath: 'remote_assist/VNTC RustDesk.app',
        isMacOS: true,
      );

      expect(
        resolved,
        path.posix.join(
          '/Applications/vnt_app.app/Contents/Resources',
          'remote_assist',
          'VNTC RustDesk.app',
        ),
      );
    });

    test('uses executable directory outside macOS app bundles', () {
      final resolved = RuntimeStoragePaths.resolveBundledPathForExecutable(
        executablePath: '/tmp/vnt_app',
        relativePath: 'remote_assist/VNTC RustDesk.app',
        isMacOS: true,
      );

      expect(
        resolved,
        path.posix.join('/tmp', 'remote_assist', 'VNTC RustDesk.app'),
      );
    });
  });
}

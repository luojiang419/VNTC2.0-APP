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
        path.join(r'C:\Users\Test\AppData\Local', 'VNT App 2.0'),
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

      expect(resolved, path.join(r'D:\Temp', 'VNT App 2.0'));
    });
  });
}

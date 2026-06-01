import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/utils/system_tray_icon_path.dart';

void main() {
  group('resolveSystemTrayIconAssetPath', () {
    test('uses ico asset on Windows', () {
      expect(
        resolveSystemTrayIconAssetPath(isWindows: true),
        'assets/app_icon.ico',
      );
    });

    test('uses png asset on non-Windows platforms', () {
      expect(
        resolveSystemTrayIconAssetPath(isWindows: false),
        'assets/app_icon.png',
      );
    });
  });
}

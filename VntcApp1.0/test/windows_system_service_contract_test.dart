import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows build and installer include the VNT core service contract', () {
    final cargo = File('rust/Cargo.toml').readAsStringSync();
    final cmake =
        File('rust_builder/windows/CMakeLists.txt').readAsStringSync();
    final portable =
        File('scripts/export_portable_package.ps1').readAsStringSync();
    final windowsBuild = File('scripts/build_windows.bat').readAsStringSync();
    final installer =
        File('scripts/export_installer_package.ps1').readAsStringSync();
    final installScript =
        File('scripts/install_vnt_service.ps1').readAsStringSync();
    final uninstallScript =
        File('scripts/uninstall_vnt_service.ps1').readAsStringSync();

    expect(cargo, contains('windows-service-host'));
    expect(cmake, contains('--bin vnt_service'));
    expect(windowsBuild, contains('VNT_SERVICE_EXE'));
    expect(windowsBuild, contains('vnt_service.exe'));
    expect(portable, contains("rust\\target\\release\\vnt_service.exe"));
    expect(portable, contains("scripts\\install_vnt_service.ps1"));
    expect(installer, contains('install_vnt_service.ps1'));
    expect(installer, contains('uninstall_vnt_service.ps1'));
    expect(installScript, contains("\$serviceName = 'VntCoreService'"));
    expect(installScript, contains('-StartupType Automatic'));
    expect(installScript, contains('sc.exe failure'));
    expect(uninstallScript, contains('sc.exe delete'));
    expect(uninstallScript, contains('machine configuration preserved'));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner enforces an enhanced-edition-only lock', () {
    final implementation = File(
      'windows/runner/single_instance.cpp',
    ).readAsStringSync();
    final header = File('windows/runner/single_instance.h').readAsStringSync();
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final window = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

    expect(header, contains('class SingleInstanceGuard'));
    expect(implementation, contains(r'Local\\VNTS2.Console.SingleInstance.v1'));
    expect(implementation, contains(r'Local\\VNTS2.Console.Activate.v1'));
    expect(implementation, contains('CreateMutexW'));
    expect(implementation, contains('CreateEventW'));
    expect(implementation, contains('OpenEventW'));
    expect(implementation, contains('SetEvent'));
    expect(implementation, contains('RegisterWaitForSingleObject'));
    expect(main, contains('if (!instance_guard.IsPrimary())'));
    expect(main, contains('NotifyExistingInstance'));
    expect(main, contains('StartActivationListener(window.GetHandle())'));
    expect(window, contains('SingleInstanceGuard::ActivationWindowMessage()'));
    expect(window, contains('SetForegroundWindow'));
    expect(window, contains('kActivationReassertTimer'));
    expect(window, contains('SetTimer'));
    expect(cmake, contains('"single_instance.cpp"'));
  });
}

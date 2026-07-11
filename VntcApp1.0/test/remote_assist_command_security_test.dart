import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_command_security.dart';

void main() {
  test('connect arguments use password file instead of plaintext password', () {
    final arguments = RemoteAssistCommandSecurity.connectArguments(
      targetAddress: '10.0.0.8:49999',
      passwordFilePath: r'C:\Temp\secret.txt',
    );

    expect(arguments, <String>[
      '--connect',
      '10.0.0.8:49999',
      '--password-file',
      r'C:\Temp\secret.txt',
    ]);
    expect(arguments, isNot(contains('--password')));
  });

  test('configure password arguments use password file when available', () {
    final arguments = RemoteAssistCommandSecurity.configurePasswordArguments(
      password: 'plain-secret',
      passwordFilePath: r'C:\Temp\secret.txt',
    );

    expect(arguments, <String>[
      '--configure-access-password-file',
      r'C:\Temp\secret.txt',
    ]);
    expect(arguments, isNot(contains('plain-secret')));
  });

  test('redactArguments hides password and password-file values', () {
    final redacted = RemoteAssistCommandSecurity.redactArguments(<String>[
      '--connect',
      '10.0.0.8:49999',
      '--password',
      'plain-secret',
      '--password-file',
      r'C:\Temp\secret.txt',
    ]);

    expect(redacted, <String>[
      '--connect',
      '10.0.0.8:49999',
      '--password',
      '<redacted>',
      '--password-file',
      '<redacted>',
    ]);
  });

  test('createSecretFile writes and deletes a temporary secret file', () async {
    final secretFile =
        await RemoteAssistCommandSecurity.createSecretFile('plain-secret');
    addTearDown(() async => secretFile?.delete());

    expect(secretFile, isNotNull);
    expect(await File(secretFile!.path).readAsString(), 'plain-secret');

    await secretFile.delete();
    expect(await File(secretFile.path).exists(), isFalse);
  });
}

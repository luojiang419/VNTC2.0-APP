import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

class RemoteAssistCommandSecurity {
  RemoteAssistCommandSecurity._();

  static const String passwordOption = '--password';
  static const String passwordFileOption = '--password-file';
  static const String configurePasswordOption = '--configure-access-password';
  static const String configurePasswordFileOption =
      '--configure-access-password-file';
  static const String redactedValue = '<redacted>';

  static List<String> connectArguments({
    required String targetAddress,
    String? passwordFilePath,
  }) {
    return <String>[
      '--connect',
      targetAddress,
      if (passwordFilePath != null && passwordFilePath.isNotEmpty) ...[
        passwordFileOption,
        passwordFilePath,
      ],
    ];
  }

  static List<String> configurePasswordArguments({
    required String password,
    String? passwordFilePath,
  }) {
    if (passwordFilePath != null && passwordFilePath.isNotEmpty) {
      return <String>[configurePasswordFileOption, passwordFilePath];
    }
    return <String>[configurePasswordOption, password];
  }

  static List<String> redactArguments(List<String> arguments) {
    final redacted = List<String>.from(arguments);
    for (var index = 0; index < redacted.length - 1; index += 1) {
      if (_sensitiveOptions.contains(redacted[index])) {
        redacted[index + 1] = redactedValue;
        index += 1;
      }
    }
    return redacted;
  }

  static String redactText(String value, {String? secret}) {
    var redacted = value;
    if (secret != null && secret.isNotEmpty) {
      redacted = redacted.replaceAll(secret, redactedValue);
    }
    return redacted;
  }

  static Future<RemoteAssistSecretFile?> createSecretFile(
    String? secret,
  ) async {
    if (secret == null || secret.isEmpty) {
      return null;
    }
    final directory = await Directory.systemTemp.createTemp(
      'vnt_remote_assist_secret_',
    );
    final file = File(path.join(directory.path, 'secret.txt'));
    await file.writeAsString(secret, flush: true);
    return RemoteAssistSecretFile._(directory: directory, file: file);
  }

  static const Set<String> _sensitiveOptions = <String>{
    passwordOption,
    passwordFileOption,
    configurePasswordOption,
    configurePasswordFileOption,
  };
}

class RemoteAssistSecretFile {
  const RemoteAssistSecretFile._({
    required this.directory,
    required this.file,
  });

  final Directory directory;
  final File file;

  String get path => file.path;

  Future<void> delete() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Secret cleanup is best effort; the parent operation result is primary.
    }
  }

  void scheduleDelete([Duration delay = const Duration(minutes: 2)]) {
    Timer(delay, () => unawaited(delete()));
  }
}

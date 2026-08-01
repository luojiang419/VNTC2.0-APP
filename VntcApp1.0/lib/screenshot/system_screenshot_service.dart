import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:vnt_app/screenshot/screenshot_shortcut_preferences.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

class ScreenshotCaptureResult {
  const ScreenshotCaptureResult.success(this.filePath)
      : error = null,
        isCanceled = false;

  const ScreenshotCaptureResult.failure(this.error)
      : filePath = null,
        isCanceled = false;

  const ScreenshotCaptureResult.canceled()
      : filePath = null,
        error = null,
        isCanceled = true;

  final String? filePath;
  final Object? error;
  final bool isCanceled;

  bool get isSuccess => filePath != null;
}

class SystemScreenshotService {
  SystemScreenshotService._();

  static final SystemScreenshotService instance = SystemScreenshotService._();

  static const MethodChannel _channel =
      MethodChannel('top.wherewego.vnt/system_screenshot');

  final ScreenshotShortcutPreferences _preferences =
      ScreenshotShortcutPreferences();
  final StreamController<ScreenshotCaptureResult> _shortcutCaptureController =
      StreamController<ScreenshotCaptureResult>.broadcast();

  String _shortcut = ScreenshotShortcutPreferences.defaultShortcut;
  bool _initialized = false;
  bool _captureInProgress = false;

  String get shortcut => _shortcut;

  Stream<ScreenshotCaptureResult> get shortcutCaptures =>
      _shortcutCaptureController.stream;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _shortcut = await _preferences.load();
    HardwareKeyboard.instance.addHandler(_handleKeyboardEvent);
    if (Platform.isWindows) {
      _channel.setMethodCallHandler(_handleNativeCall);
      await _registerWindowsShortcut(_shortcut);
    }
  }

  Future<void> updateShortcut(String shortcut) async {
    if (!ScreenshotShortcutPreferences.supportedShortcuts.contains(shortcut)) {
      throw ArgumentError.value(shortcut, 'shortcut', '不支持的截图快捷键');
    }
    final previousShortcut = _shortcut;
    if (Platform.isWindows) {
      try {
        await _registerWindowsShortcut(shortcut);
      } catch (_) {
        await _registerWindowsShortcut(previousShortcut);
        rethrow;
      }
    }
    await _preferences.save(shortcut);
    _shortcut = shortcut;
  }

  Future<ScreenshotCaptureResult> captureFullScreen() async {
    if (_captureInProgress) {
      return const ScreenshotCaptureResult.failure('截图正在进行中');
    }
    _captureInProgress = true;
    try {
      final targetPath = await _createTargetPath();

      if (Platform.isWindows) {
        final savedPath = await _channel.invokeMethod<String>(
          'captureFullScreen',
          <String, Object>{'outputPath': targetPath},
        );
        return ScreenshotCaptureResult.success(savedPath ?? targetPath);
      }
      if (Platform.isMacOS) {
        await _runCaptureCommand(
          '/usr/sbin/screencapture',
          <String>['-x', '-t', 'png', targetPath],
        );
        return ScreenshotCaptureResult.success(targetPath);
      }
      if (Platform.isLinux) {
        await _captureLinux(targetPath);
        return ScreenshotCaptureResult.success(targetPath);
      }
      return const ScreenshotCaptureResult.failure('当前平台暂不支持系统截图');
    } catch (error) {
      return ScreenshotCaptureResult.failure(error);
    } finally {
      _captureInProgress = false;
    }
  }

  Future<ScreenshotCaptureResult> captureInteractive() async {
    if (_captureInProgress) {
      return const ScreenshotCaptureResult.failure('截图正在进行中');
    }
    _captureInProgress = true;
    try {
      final targetPath = await _createTargetPath();
      if (Platform.isWindows) {
        final savedPath = await _channel.invokeMethod<String?>(
          'captureRegion',
          <String, Object>{'outputPath': targetPath},
        );
        if (savedPath == null || savedPath.trim().isEmpty) {
          return const ScreenshotCaptureResult.canceled();
        }
        return ScreenshotCaptureResult.success(savedPath);
      }
      if (Platform.isMacOS) {
        final result = await Process.run(
          '/usr/sbin/screencapture',
          <String>['-i', '-x', '-t', 'png', targetPath],
        );
        if (result.exitCode != 0) {
          return const ScreenshotCaptureResult.canceled();
        }
        return await File(targetPath).exists()
            ? ScreenshotCaptureResult.success(targetPath)
            : const ScreenshotCaptureResult.canceled();
      }
      if (Platform.isLinux) {
        return _captureLinuxInteractive(targetPath);
      }
      return const ScreenshotCaptureResult.failure('当前平台暂不支持系统截图');
    } catch (error) {
      return ScreenshotCaptureResult.failure(error);
    } finally {
      _captureInProgress = false;
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'shortcutPressed') {
      await _captureFromShortcut();
    }
  }

  bool _handleKeyboardEvent(KeyEvent event) {
    if (Platform.isWindows || event is! KeyDownEvent) {
      return false;
    }
    if (_keyLabel(event.logicalKey) != _shortcut) {
      return false;
    }
    unawaited(_captureFromShortcut());
    return true;
  }

  Future<void> _captureFromShortcut() async {
    final result = await captureInteractive();
    _shortcutCaptureController.add(result);
  }

  Future<String> _createTargetPath() async {
    final directory = Directory(
      path.join(
        RuntimeStoragePaths.resolveDataDirectoryPathSync(),
        'screenshots',
      ),
    );
    await directory.create(recursive: true);
    return path.join(
      directory.path,
      'screenshot_${_formatTimestamp(DateTime.now())}.png',
    );
  }

  Future<void> _registerWindowsShortcut(String shortcut) async {
    final functionNumber = int.parse(shortcut.substring(1));
    final virtualKey = 0x70 + functionNumber - 1;
    await _channel.invokeMethod<void>(
      'registerShortcut',
      <String, Object>{'virtualKey': virtualKey},
    );
  }

  Future<void> _captureLinux(String targetPath) async {
    final commands = <(String, List<String>)>[
      ('gnome-screenshot', <String>['-f', targetPath]),
      ('spectacle', <String>['-b', '-n', '-o', targetPath]),
      ('scrot', <String>[targetPath]),
    ];
    Object? lastError;
    for (final command in commands) {
      try {
        await _runCaptureCommand(command.$1, command.$2);
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('未找到可用的 Linux 截图工具: $lastError');
  }

  Future<ScreenshotCaptureResult> _captureLinuxInteractive(
    String targetPath,
  ) async {
    final commands = <(String, List<String>)>[
      ('gnome-screenshot', <String>['-a', '-f', targetPath]),
      ('spectacle', <String>['-b', '-n', '-r', '-o', targetPath]),
    ];
    Object? lastError;
    for (final command in commands) {
      try {
        final result = await Process.run(command.$1, command.$2);
        if (result.exitCode == 0) {
          return await File(targetPath).exists()
              ? ScreenshotCaptureResult.success(targetPath)
              : const ScreenshotCaptureResult.canceled();
        }
        lastError = ProcessException(
          command.$1,
          command.$2,
          result.stderr.toString().trim(),
          result.exitCode,
        );
      } catch (error) {
        lastError = error;
      }
    }
    return ScreenshotCaptureResult.failure(
      StateError('未找到可用的 Linux 截屏选择器: $lastError'),
    );
  }

  Future<void> _runCaptureCommand(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        result.stderr.toString().trim(),
        result.exitCode,
      );
    }
  }

  String? _keyLabel(LogicalKeyboardKey key) {
    for (var index = 0; index < _functionKeys.length; index += 1) {
      if (_functionKeys[index] == key) {
        return 'F${index + 1}';
      }
    }
    return null;
  }

  String _formatTimestamp(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${twoDigits(value.month)}${twoDigits(value.day)}_'
        '${twoDigits(value.hour)}${twoDigits(value.minute)}${twoDigits(value.second)}_'
        '${value.millisecond.toString().padLeft(3, '0')}';
  }

  static const List<LogicalKeyboardKey> _functionKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];
}

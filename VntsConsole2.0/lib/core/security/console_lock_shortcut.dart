import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ConsoleLockShortcut {
  disabled,
  controlShiftL,
  controlAltL,
  controlShiftK;

  String get label => switch (this) {
    ConsoleLockShortcut.disabled => '关闭快捷键',
    ConsoleLockShortcut.controlShiftL => 'Ctrl + Shift + L',
    ConsoleLockShortcut.controlAltL => 'Ctrl + Alt + L',
    ConsoleLockShortcut.controlShiftK => 'Ctrl + Shift + K',
  };

  ShortcutActivator? get activator => switch (this) {
    ConsoleLockShortcut.disabled => null,
    ConsoleLockShortcut.controlShiftL => const SingleActivator(
      LogicalKeyboardKey.keyL,
      control: true,
      shift: true,
    ),
    ConsoleLockShortcut.controlAltL => const SingleActivator(
      LogicalKeyboardKey.keyL,
      control: true,
      alt: true,
    ),
    ConsoleLockShortcut.controlShiftK => const SingleActivator(
      LogicalKeyboardKey.keyK,
      control: true,
      shift: true,
    ),
  };

  static ConsoleLockShortcut fromStorage(String? value) {
    return ConsoleLockShortcut.values.firstWhere(
      (shortcut) => shortcut.name == value,
      orElse: () => ConsoleLockShortcut.controlShiftL,
    );
  }
}

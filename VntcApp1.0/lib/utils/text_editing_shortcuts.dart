import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum VntTextEditOperation {
  copy,
  cut,
  paste,
  selectAll,
}

class VntTextEditIntent extends Intent {
  const VntTextEditIntent(this.operation);

  final VntTextEditOperation operation;
}

class VntTextEditingShortcuts extends StatelessWidget {
  const VntTextEditingShortcuts({
    super.key,
    required this.child,
    this.clipboard = const SystemVntClipboardBridge(),
  });

  final Widget child;
  final VntClipboardBridge clipboard;

  static const Map<ShortcutActivator, Intent> _shortcuts = {
    SingleActivator(LogicalKeyboardKey.keyC, meta: true):
        VntTextEditIntent(VntTextEditOperation.copy),
    SingleActivator(LogicalKeyboardKey.keyX, meta: true):
        VntTextEditIntent(VntTextEditOperation.cut),
    SingleActivator(LogicalKeyboardKey.keyV, meta: true):
        VntTextEditIntent(VntTextEditOperation.paste),
    SingleActivator(LogicalKeyboardKey.keyA, meta: true):
        VntTextEditIntent(VntTextEditOperation.selectAll),
    SingleActivator(LogicalKeyboardKey.keyC, control: true):
        VntTextEditIntent(VntTextEditOperation.copy),
    SingleActivator(LogicalKeyboardKey.keyX, control: true):
        VntTextEditIntent(VntTextEditOperation.cut),
    SingleActivator(LogicalKeyboardKey.keyV, control: true):
        VntTextEditIntent(VntTextEditOperation.paste),
    SingleActivator(LogicalKeyboardKey.keyA, control: true):
        VntTextEditIntent(VntTextEditOperation.selectAll),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          VntTextEditIntent: VntTextEditAction(clipboard: clipboard),
        },
        child: child,
      ),
    );
  }
}

abstract class VntClipboardBridge {
  const VntClipboardBridge();

  Future<String?> getText();

  Future<void> setText(String text);
}

class VntTextEditAction extends Action<VntTextEditIntent> {
  VntTextEditAction({
    VntClipboardBridge clipboard = const SystemVntClipboardBridge(),
  }) : _clipboard = clipboard;

  final VntClipboardBridge _clipboard;

  @override
  bool isEnabled(VntTextEditIntent intent) {
    final editableTextState = _focusedEditableTextState();
    if (editableTextState == null) {
      return false;
    }
    if (intent.operation == VntTextEditOperation.copy ||
        intent.operation == VntTextEditOperation.selectAll) {
      return true;
    }
    return !editableTextState.widget.readOnly;
  }

  @override
  bool consumesKey(VntTextEditIntent intent) {
    return isEnabled(intent);
  }

  @override
  Future<void> invoke(VntTextEditIntent intent) async {
    final editableTextState = _focusedEditableTextState();
    if (editableTextState == null) {
      return;
    }

    switch (intent.operation) {
      case VntTextEditOperation.copy:
        await _copy(editableTextState);
      case VntTextEditOperation.cut:
        await _cut(editableTextState);
      case VntTextEditOperation.paste:
        await _paste(editableTextState);
      case VntTextEditOperation.selectAll:
        _selectAll(editableTextState);
    }
  }

  EditableTextState? _focusedEditableTextState() {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    return focusedContext?.findAncestorStateOfType<EditableTextState>();
  }

  Future<void> _copy(EditableTextState state) async {
    if (state.widget.obscureText) {
      return;
    }
    final selectedText = _selectedText(state.currentTextEditingValue);
    if (selectedText == null) {
      return;
    }
    await _clipboard.setText(selectedText);
  }

  Future<void> _cut(EditableTextState state) async {
    if (state.widget.readOnly || state.widget.obscureText) {
      return;
    }
    final value = state.currentTextEditingValue;
    final selectedText = _selectedText(value);
    if (selectedText == null) {
      return;
    }
    await _clipboard.setText(selectedText);
    final nextValue = value.replaced(value.selection, '');
    state.userUpdateTextEditingValue(nextValue, SelectionChangedCause.keyboard);
  }

  Future<void> _paste(EditableTextState state) async {
    if (state.widget.readOnly || !state.widget.selectionEnabled) {
      return;
    }
    final text = await _clipboard.getText();
    if (text == null || text.isEmpty) {
      return;
    }
    final nextValue = replaceSelectionWithText(
      state.currentTextEditingValue,
      text,
    );
    state.userUpdateTextEditingValue(nextValue, SelectionChangedCause.keyboard);
  }

  void _selectAll(EditableTextState state) {
    final value = state.currentTextEditingValue;
    state.userUpdateTextEditingValue(
      value.copyWith(
        selection:
            TextSelection(baseOffset: 0, extentOffset: value.text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  String? _selectedText(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return null;
    }
    return selection.textInside(value.text);
  }
}

TextEditingValue replaceSelectionWithText(
  TextEditingValue value,
  String replacement,
) {
  final selection = value.selection;
  final replacementRange = selection.isValid
      ? selection
      : TextSelection.collapsed(offset: value.text.length);
  final nextValue = value.replaced(replacementRange, replacement);
  return nextValue.copyWith(
    selection: TextSelection.collapsed(
      offset: replacementRange.start + replacement.length,
    ),
  );
}

class SystemVntClipboardBridge extends VntClipboardBridge {
  const SystemVntClipboardBridge();

  @override
  Future<String?> getText() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final flutterText = clipboardData?.text;
    if (flutterText != null && flutterText.isNotEmpty) {
      return flutterText;
    }

    if (!Platform.isMacOS || !await _isRunningAsRoot()) {
      return flutterText;
    }

    return _readConsoleUserPasteboard();
  }

  @override
  Future<void> setText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (Platform.isMacOS && await _isRunningAsRoot()) {
      await _writeConsoleUserPasteboard(text);
    }
  }

  static Future<bool> _isRunningAsRoot() async {
    try {
      final result = await Process.run('/usr/bin/id', ['-u']);
      return result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } catch (_) {
      return false;
    }
  }

  static Future<_ConsoleUser?> _consoleUser() async {
    try {
      final userResult = await Process.run(
        '/usr/bin/stat',
        ['-f', '%Su', '/dev/console'],
      );
      if (userResult.exitCode != 0) {
        return null;
      }
      final userName = userResult.stdout.toString().trim();
      if (userName.isEmpty || userName == 'root') {
        return null;
      }

      final uidResult = await Process.run('/usr/bin/id', ['-u', userName]);
      if (uidResult.exitCode != 0) {
        return null;
      }
      final uid = uidResult.stdout.toString().trim();
      if (uid.isEmpty) {
        return null;
      }

      return _ConsoleUser(name: userName, uid: uid);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readConsoleUserPasteboard() async {
    final user = await _consoleUser();
    if (user == null) {
      return null;
    }

    try {
      final result = await Process.run('/bin/launchctl', [
        'asuser',
        user.uid,
        '/usr/bin/sudo',
        '-u',
        user.name,
        '/usr/bin/pbpaste',
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      return result.stdout.toString();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeConsoleUserPasteboard(String text) async {
    final user = await _consoleUser();
    if (user == null) {
      return;
    }

    try {
      final process = await Process.start('/bin/launchctl', [
        'asuser',
        user.uid,
        '/usr/bin/sudo',
        '-u',
        user.name,
        '/usr/bin/pbcopy',
      ]);
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Flutter's clipboard already received the value; this is a best effort
      // bridge for the console user's pasteboard when the GUI is running as root.
    }
  }
}

class _ConsoleUser {
  const _ConsoleUser({
    required this.name,
    required this.uid,
  });

  final String name;
  final String uid;
}

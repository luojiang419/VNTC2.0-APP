import 'package:shared_preferences/shared_preferences.dart';

class ScreenshotShortcutPreferences {
  static const String storageKey = 'screenshot_shortcut_key_v1';
  static const String defaultShortcut = 'F6';
  static const List<String> supportedShortcuts = <String>[
    'F1',
    'F2',
    'F3',
    'F4',
    'F5',
    'F6',
    'F7',
    'F8',
    'F9',
    'F10',
    'F11',
    'F12',
  ];

  Future<String> load() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(storageKey);
    return supportedShortcuts.contains(saved) ? saved! : defaultShortcut;
  }

  Future<void> save(String shortcut) async {
    if (!supportedShortcuts.contains(shortcut)) {
      throw ArgumentError.value(shortcut, 'shortcut', '不支持的截图快捷键');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, shortcut);
  }
}

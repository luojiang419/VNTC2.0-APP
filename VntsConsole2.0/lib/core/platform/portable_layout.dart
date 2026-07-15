import 'dart:io';

class PortableLayout {
  const PortableLayout._(this.root);

  static const requiredScripts = <String>{
    'vnts2-service-common.ps1',
    'initialize-vnts2-console.ps1',
    'status-vnts2-service.ps1',
    'install-vnts2-service.ps1',
    'start-vnts2-service.ps1',
    'stop-vnts2-service.ps1',
    'update-vnts2-service.ps1',
    'diagnose-vnts2-service.ps1',
    'uninstall-vnts2-service.ps1',
  };

  final Directory root;

  Directory get dataDirectory => Directory(_join(root.path, 'data'));
  Directory get logsDirectory => Directory(_join(dataDirectory.path, 'logs'));
  File get executable => File(_join(root.path, 'vnts2.exe'));
  File get config => File(_join(dataDirectory.path, 'config.toml'));
  File get initialSetupMarker =>
      File(_join(dataDirectory.path, '.console-initial-setup-required'));
  File script(String name) {
    if (!requiredScripts.contains(name)) {
      throw ArgumentError.value(name, 'name', '脚本不在白名单中');
    }
    return File(_join(root.path, name));
  }

  bool get isComplete {
    return requiredScripts.every((name) => script(name).existsSync());
  }

  static PortableLayout? discover({
    String? overrideRoot,
    String? executablePath,
  }) {
    if (overrideRoot != null && overrideRoot.trim().isNotEmpty) {
      final root = Directory(overrideRoot).absolute;
      if (!root.existsSync()) return null;
      final layout = PortableLayout._(root);
      return layout.isComplete ? layout : null;
    }

    final candidates = <String>{};
    void addWithParents(String path) {
      var current = Directory(path).absolute;
      for (var depth = 0; depth < 7; depth++) {
        candidates.add(current.path);
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }

    addWithParents(
      File(executablePath ?? Platform.resolvedExecutable).parent.path,
    );

    for (final candidate in candidates) {
      final root = Directory(candidate);
      if (!root.existsSync()) continue;
      final layout = PortableLayout._(root);
      if (layout.isComplete) return layout;
    }
    return null;
  }

  static String _join(String first, String second, [String? third]) {
    final separator = Platform.pathSeparator;
    return third == null
        ? '$first$separator$second'
        : '$first$separator$second$separator$third';
  }
}

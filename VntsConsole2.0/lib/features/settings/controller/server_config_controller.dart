import 'dart:io';

import '../../../core/platform/service_operations.dart';
import '../../../shared/foundation/safe_change_notifier.dart';
import '../data/server_config_repository.dart';
import '../domain/server_config_settings.dart';

class ServerConfigController extends SafeChangeNotifier {
  ServerConfigController(this._repository, this._operations);

  final ServerConfigRepository? _repository;
  final ServiceOperations? _operations;
  LoadedServerConfig? loaded;
  bool loading = true;
  bool saving = false;
  String? error;
  String? lastBackupPath;

  ServerConfigSettings? get settings => loaded?.settings;

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) {
      loading = false;
      error = '未发现便携 data/config.toml，请从完整增强版分发目录启动。';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      loaded = await repository.load();
    } on FileSystemException catch (exception) {
      error = '加载配置失败：${exception.message}';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> save(
    ServerConfigSettings settings, {
    required String newPassword,
    required String newServerToken,
    required bool restart,
  }) async {
    if (_repository == null || loaded == null) return;
    saving = true;
    error = null;
    notifyListeners();
    try {
      final result = await _repository.save(
        loaded!,
        settings,
        newPassword: newPassword,
        newServerToken: newServerToken,
      );
      lastBackupPath = result.backupPath;
      loaded = await _repository.load();
      if (restart) {
        if (_operations == null) {
          throw const ServiceOperationException('配置已保存，但当前目录缺少重启脚本');
        }
        await _operations.run(ServiceAction.restart);
      }
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}

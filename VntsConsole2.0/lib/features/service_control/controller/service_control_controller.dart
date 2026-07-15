import 'dart:io';

import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../../core/platform/service_operations.dart';
import '../../../shared/foundation/safe_change_notifier.dart';
import '../../settings/data/server_config_repository.dart';
import '../../settings/domain/server_config_settings.dart';

enum AuthSessionState { loggedOut, authenticating, authenticated, error }

class ServiceControlController extends SafeChangeNotifier {
  ServiceControlController({
    this.operations,
    this.apiClient,
    this.configRepository,
  }) : _authState = apiClient?.hasSession == true
           ? AuthSessionState.authenticated
           : AuthSessionState.loggedOut;

  final ServiceOperations? operations;
  final ApiClient? apiClient;
  final ServerConfigRepository? configRepository;

  WindowsServiceStatus? _serviceStatus;
  AuthSessionState _authState;
  List<DiagnosticCheck> _diagnostics = const [];
  bool _busy = false;
  String? _message;
  String? _errorDetails;

  WindowsServiceStatus? get serviceStatus => _serviceStatus;
  AuthSessionState get authState => _authState;
  List<DiagnosticCheck> get diagnostics => _diagnostics;
  bool get busy => _busy;
  String? get message => _message;
  String? get errorDetails => _errorDetails;
  bool get scriptsAvailable => operations != null;
  bool get apiAvailable => apiClient != null;
  bool get canChangeApiPassword =>
      configRepository != null && operations != null && apiClient != null;

  Future<void> refreshStatus() async {
    final service = operations;
    if (service == null || _busy) return;
    try {
      _serviceStatus = await service.status();
      _message = null;
    } on ServiceOperationException catch (error) {
      _message = error.message;
      _errorDetails = error.details;
    }
    notifyListeners();
  }

  Future<void> runAction(ServiceAction action, {String? updateSource}) async {
    final service = operations;
    if (service == null || _busy) return;
    _busy = true;
    _message = null;
    _errorDetails = null;
    notifyListeners();
    try {
      final checks = await service.run(action, updateSource: updateSource);
      if (action == ServiceAction.diagnose) {
        _diagnostics = checks;
      }
      _message = '${_label(action)}完成';
      _serviceStatus = await service.status();
    } on ServiceOperationException catch (error) {
      _message = error.message;
      _errorDetails = error.details;
    } catch (_) {
      _message = '${_label(action)}失败，请运行诊断';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> login(String username, String password) async {
    final client = apiClient;
    if (client == null || _busy) return false;
    if (username.trim().isEmpty || password.isEmpty) {
      _message = '请输入管理用户名和密码';
      notifyListeners();
      return false;
    }
    _busy = true;
    _authState = AuthSessionState.authenticating;
    _message = null;
    notifyListeners();
    try {
      await client.login(username: username.trim(), password: password);
      _authState = AuthSessionState.authenticated;
      _message = 'API 登录成功，会话仅保存在当前进程内存中';
      return true;
    } on ApiException catch (error) {
      _authState = AuthSessionState.error;
      _message = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    final client = apiClient;
    if (client == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await client.logout();
    } on ApiException {
      client.clearSession();
    } finally {
      _authState = AuthSessionState.loggedOut;
      _busy = false;
      _message = '已清除当前内存会话';
      notifyListeners();
    }
  }

  Future<bool> changeApiPassword(String newPassword) async {
    final repository = configRepository;
    final service = operations;
    final client = apiClient;
    if (repository == null || service == null || client == null || _busy) {
      return false;
    }
    _busy = true;
    _message = null;
    _errorDetails = null;
    notifyListeners();
    try {
      final loaded = await repository.load();
      await repository.save(loaded, loaded.settings, newPassword: newPassword);
      client.clearSession();
      _authState = AuthSessionState.loggedOut;
      await service.run(ServiceAction.restart);
      _serviceStatus = await service.status();
      _message = 'API 密码已修改并重启服务，请使用新密码登录';
      return true;
    } on ConfigValidationException catch (error) {
      _message = error.message;
      return false;
    } on FileSystemException catch (error) {
      _message = '修改 API 密码失败：${error.message}';
      return false;
    } on ServiceOperationException catch (error) {
      _message = error.message;
      _errorDetails = error.details;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static String _label(ServiceAction action) => switch (action) {
    ServiceAction.install => '安装服务',
    ServiceAction.start => '启动服务',
    ServiceAction.stop => '停止服务',
    ServiceAction.restart => '重启服务',
    ServiceAction.update => '更新服务',
    ServiceAction.diagnose => '运行诊断',
    ServiceAction.uninstall => '卸载服务',
  };
}

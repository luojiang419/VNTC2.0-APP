import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/networking/api_client.dart';
import '../core/networking/api_exception.dart';
import '../core/platform/service_operations.dart';
import '../core/platform/desktop_behavior.dart';
import '../core/platform/windows_startup_manager.dart';
import '../core/security/console_lock_shortcut.dart';
import '../core/storage/app_preferences.dart';
import '../features/settings/data/server_config_repository.dart';
import '../features/settings/domain/server_config_settings.dart';
import 'app_routes.dart';

enum ServiceConnectionStatus {
  unknown,
  running,
  authenticationRequired,
  unreachable,
}

enum IntegratedServiceState { unavailable, waiting, preparing, ready, failed }

enum ConsoleAccessState { setupRequired, loginRequired, authenticated, locked }

class AppController extends ChangeNotifier with WindowListener, TrayListener {
  AppController({
    required ThemeMode themeMode,
    AppPreferences? preferences,
    this.apiClient,
    this.serviceOperations,
    this.configRepository,
    int dashboardPollSeconds = 1,
    int autoLockHours = 2,
    ConsoleLockShortcut lockShortcut = ConsoleLockShortcut.controlShiftL,
    AppCloseBehavior closeBehavior = AppCloseBehavior.minimizeToTray,
    AppStartupBehavior startupBehavior = AppStartupBehavior.disabled,
    this.startupManager,
    Duration? autoLockDelayOverride,
  }) : _themeMode = themeMode,
       _dashboardPollSeconds = dashboardPollSeconds,
       _autoLockHours = autoLockHours,
       _lockShortcut = lockShortcut,
       _closeBehavior = closeBehavior,
       _startupBehavior = startupBehavior,
       _autoLockDelayOverride = autoLockDelayOverride,
       _preferences = preferences,
       _accessState = apiClient == null
           ? ConsoleAccessState.authenticated
           : ConsoleAccessState.loginRequired,
       _integratedServiceState = serviceOperations == null
           ? IntegratedServiceState.unavailable
           : IntegratedServiceState.waiting {
    apiClient?.onSessionInvalidated = _handleSessionInvalidated;
  }

  factory AppController.inMemory() =>
      AppController(themeMode: ThemeMode.system);

  ThemeMode _themeMode;
  AppRoute _route = AppRoute.dashboard;
  final AppPreferences? _preferences;
  final ApiClient? apiClient;
  final ServiceOperations? serviceOperations;
  final ServerConfigRepository? configRepository;
  final WindowsStartupManager? startupManager;
  final Duration? _autoLockDelayOverride;
  ServiceConnectionStatus _serviceConnectionStatus =
      ServiceConnectionStatus.unknown;
  IntegratedServiceState _integratedServiceState;
  ConsoleAccessState _accessState;
  String? _integratedServiceMessage;
  String? _accessMessage;
  bool _bootstrapErrorDismissed = false;
  bool _accessBusy = false;
  int _dashboardPollSeconds;
  int _autoLockHours;
  ConsoleLockShortcut _lockShortcut;
  AppCloseBehavior _closeBehavior;
  AppStartupBehavior _startupBehavior;
  bool _desktopBehaviorBusy = false;
  String? _desktopBehaviorMessage;
  bool _windowsShellInitialized = false;
  bool _trayReady = false;
  bool _exiting = false;
  String _knownUsername = 'admin';
  Timer? _autoLockTimer;

  ThemeMode get themeMode => _themeMode;
  AppRoute get route => _route;
  ServiceConnectionStatus get serviceConnectionStatus =>
      _serviceConnectionStatus;
  int get dashboardPollSeconds => _dashboardPollSeconds;
  int get autoLockHours => _autoLockHours;
  ConsoleLockShortcut get lockShortcut => _lockShortcut;
  AppCloseBehavior get closeBehavior => _closeBehavior;
  AppStartupBehavior get startupBehavior => _startupBehavior;
  bool get desktopBehaviorBusy => _desktopBehaviorBusy;
  String? get desktopBehaviorMessage => _desktopBehaviorMessage;
  String get knownUsername => _knownUsername;
  ConsoleAccessState get accessState => _accessState;
  String? get accessMessage => _accessMessage;
  bool get accessBusy => _accessBusy;
  bool get isAuthenticated => _accessState == ConsoleAccessState.authenticated;
  IntegratedServiceState get integratedServiceState => _integratedServiceState;
  String? get integratedServiceMessage => _integratedServiceMessage;
  bool get showIntegratedServiceOverlay =>
      _integratedServiceState == IntegratedServiceState.preparing ||
      (_integratedServiceState == IntegratedServiceState.failed &&
          !_bootstrapErrorDismissed);

  Future<void> initializeIntegratedService() async {
    final operations = serviceOperations;
    if (operations == null ||
        _integratedServiceState == IntegratedServiceState.preparing) {
      return;
    }
    _integratedServiceState = IntegratedServiceState.preparing;
    _integratedServiceMessage = '正在初始化便携数据并启动 VNTS2 服务…';
    _bootstrapErrorDismissed = false;
    notifyListeners();
    try {
      final result = await operations.ensureIntegratedService();
      await _refreshKnownUsername();
      final setupRequired =
          result.initialSetupRequired ||
          operations.layout.initialSetupMarker.existsSync();
      _integratedServiceState = IntegratedServiceState.ready;
      _accessState = setupRequired
          ? ConsoleAccessState.setupRequired
          : ConsoleAccessState.loginRequired;
      _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
      _integratedServiceMessage = setupRequired
          ? '集成服务已启动，请先设置管理员账号和密码。'
          : '集成服务已就绪，请登录后进入控制台。';
      _accessMessage = setupRequired ? '首次使用必须先完成管理员身份设置。' : null;
    } on ServiceOperationException catch (error) {
      _integratedServiceState = IntegratedServiceState.failed;
      _integratedServiceMessage = _describeServiceFailure(error);
      _serviceConnectionStatus = ServiceConnectionStatus.unreachable;
    } finally {
      notifyListeners();
    }
  }

  static String _describeServiceFailure(ServiceOperationException error) {
    final details = error.details?.trim();
    if (details == null || details.isEmpty) return error.message;
    final firstLine = details
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return firstLine.isEmpty ? error.message : '${error.message}：$firstLine';
  }

  Future<void> initializeWindowsShell({required bool silentStart}) async {
    if (!Platform.isWindows || _windowsShellInitialized) return;
    _windowsShellInitialized = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);

    try {
      final executableDirectory = File(Platform.resolvedExecutable).parent.path;
      final trayIconPath = [
        executableDirectory,
        'data',
        'flutter_assets',
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ].join(Platform.pathSeparator);
      if (!File(trayIconPath).existsSync()) {
        throw FileSystemException('托盘图标资源不存在', trayIconPath);
      }
      await trayManager.setIcon(trayIconPath);
      await trayManager.setToolTip('VNTS 2.0 增强控制台');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_window', label: '打开增强控制台'),
            MenuItem(key: 'minimize_to_tray', label: '最小化到托盘'),
            MenuItem.separator(),
            MenuItem(key: 'stop_service_and_exit', label: '关闭服务并退出'),
          ],
        ),
      );
      _trayReady = true;
    } on Object catch (error) {
      _trayReady = false;
      _desktopBehaviorMessage = '系统托盘初始化失败，将保留任务栏入口：$error';
    }

    final manager = startupManager;
    if (manager != null) {
      try {
        await manager.apply(_startupBehavior);
      } on Object catch (error) {
        _desktopBehaviorMessage = '开机自启任务校验失败：$error';
      }
    }

    if (silentStart) {
      await minimizeToTray(showMessage: false);
    }
    notifyListeners();
  }

  Future<void> minimizeToTray({bool showMessage = true}) async {
    if (!Platform.isWindows || _exiting) return;
    if (_trayReady) {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      if (showMessage) _desktopBehaviorMessage = '控制台已最小化到托盘，VNTS2 服务继续运行';
    } else {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.minimize();
      if (showMessage) _desktopBehaviorMessage = '托盘不可用，控制台已最小化到任务栏';
    }
    notifyListeners();
  }

  Future<void> showMainWindow() async {
    if (!Platform.isWindows || _exiting) return;
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.focus();
  }

  Future<void> executeCloseBehavior(AppCloseBehavior behavior) async {
    if (behavior == AppCloseBehavior.minimizeToTray) {
      await minimizeToTray();
    } else {
      await stopServiceAndExit();
    }
  }

  Future<void> stopServiceAndExit() async {
    if (_desktopBehaviorBusy || _exiting) return;
    _desktopBehaviorBusy = true;
    _desktopBehaviorMessage = '正在停止 VNTS2 服务并退出控制台…';
    notifyListeners();
    try {
      final operations = serviceOperations;
      if (operations != null) {
        final status = await operations.status();
        if (status.installed && status.state.toLowerCase() != 'stopped') {
          await operations.run(ServiceAction.stop);
        }
      }
      _exiting = true;
      if (_trayReady) await trayManager.destroy();
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      await windowManager.destroy();
    } on Object catch (error) {
      _exiting = false;
      _desktopBehaviorMessage = '关闭服务失败，控制台未退出：$error';
      await showMainWindow();
    } finally {
      if (!_exiting) {
        _desktopBehaviorBusy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> login(String username, String password) async {
    final client = apiClient;
    if (client == null || _accessBusy) return false;
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty || password.trim().isEmpty) {
      _accessMessage = '请输入管理员账号和密码';
      notifyListeners();
      return false;
    }
    final failureState = _accessState == ConsoleAccessState.locked
        ? ConsoleAccessState.locked
        : ConsoleAccessState.loginRequired;
    _accessBusy = true;
    _accessMessage = null;
    notifyListeners();
    try {
      await client.login(username: normalizedUsername, password: password);
      _knownUsername = normalizedUsername;
      _accessState = ConsoleAccessState.authenticated;
      _serviceConnectionStatus = ServiceConnectionStatus.running;
      _accessMessage = null;
      _scheduleAutoLock();
      return true;
    } on ApiException catch (error) {
      _accessState = failureState;
      _serviceConnectionStatus = error.kind == ApiErrorKind.unavailable
          ? ServiceConnectionStatus.unreachable
          : ServiceConnectionStatus.authenticationRequired;
      _accessMessage = error.message;
      return false;
    } finally {
      _accessBusy = false;
      notifyListeners();
    }
  }

  Future<bool> completeInitialSetup(String username, String password) async {
    if (_accessState != ConsoleAccessState.setupRequired || _accessBusy) {
      return false;
    }
    final validation = _credentialValidation(username, password);
    if (validation != null) {
      _accessMessage = validation;
      notifyListeners();
      return false;
    }
    final repository = configRepository;
    final operations = serviceOperations;
    final client = apiClient;
    if (repository == null || operations == null || client == null) {
      _accessMessage = '当前目录缺少首次设置所需的配置或服务组件';
      notifyListeners();
      return false;
    }
    final normalizedUsername = username.trim();
    _accessBusy = true;
    _accessMessage = null;
    notifyListeners();
    try {
      final loaded = await repository.load();
      await repository.save(
        loaded,
        loaded.settings.copyWith(username: normalizedUsername),
        newPassword: password,
      );
      client.clearSession();
      await operations.run(ServiceAction.restart);
      await _loginWithRetry(normalizedUsername, password);
      final marker = operations.layout.initialSetupMarker;
      if (await marker.exists()) await marker.delete();
      _knownUsername = normalizedUsername;
      _accessState = ConsoleAccessState.authenticated;
      _serviceConnectionStatus = ServiceConnectionStatus.running;
      _accessMessage = null;
      _scheduleAutoLock();
      return true;
    } on ConfigValidationException catch (error) {
      _accessMessage = error.message;
      return false;
    } on FileSystemException catch (error) {
      client.clearSession();
      _accessMessage = '保存管理员设置失败：${error.message}';
      return false;
    } on ServiceOperationException catch (error) {
      client.clearSession();
      _accessMessage = error.message;
      return false;
    } on ApiException catch (error) {
      client.clearSession();
      _accessMessage = '管理员设置已保存，但新凭据验证失败：${error.message}';
      return false;
    } finally {
      _accessBusy = false;
      notifyListeners();
    }
  }

  Future<bool> changeAdminCredentials(String username, String password) async {
    if (!isAuthenticated || _accessBusy) return false;
    final validation = _credentialValidation(username, password);
    if (validation != null) {
      _accessMessage = validation;
      notifyListeners();
      return false;
    }
    final repository = configRepository;
    final operations = serviceOperations;
    final client = apiClient;
    if (repository == null || operations == null || client == null) {
      _accessMessage = '当前目录缺少修改管理员凭据所需的组件';
      notifyListeners();
      return false;
    }
    final normalizedUsername = username.trim();
    _accessBusy = true;
    _accessMessage = null;
    notifyListeners();
    try {
      final loaded = await repository.load();
      await repository.save(
        loaded,
        loaded.settings.copyWith(username: normalizedUsername),
        newPassword: password,
      );
      _knownUsername = normalizedUsername;
      client.clearSession();
      _cancelAutoLock();
      _accessState = ConsoleAccessState.loginRequired;
      _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
      await operations.run(ServiceAction.restart);
      _accessMessage = '管理员账号和密码已生效，请使用新凭据重新登录';
      return true;
    } on ConfigValidationException catch (error) {
      _accessMessage = error.message;
      return false;
    } on FileSystemException catch (error) {
      _accessMessage = '修改管理员凭据失败：${error.message}';
      return false;
    } on ServiceOperationException catch (error) {
      client.clearSession();
      _accessState = ConsoleAccessState.loginRequired;
      _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
      _accessMessage = '凭据已写入但服务重启失败：${error.message}';
      return false;
    } finally {
      _accessBusy = false;
      notifyListeners();
    }
  }

  Future<void> _loginWithRetry(String username, String password) async {
    final client = apiClient!;
    ApiException? lastError;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await client.login(username: username, password: password);
        return;
      } on ApiException catch (error) {
        lastError = error;
        if (error.kind != ApiErrorKind.unavailable) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw lastError ?? const ApiException(ApiErrorKind.unavailable, '管理接口尚未恢复');
  }

  Future<void> _refreshKnownUsername() async {
    final repository = configRepository;
    if (repository == null) return;
    try {
      final loaded = await repository.load();
      final username = loaded.settings.username.trim();
      if (username.isNotEmpty && username != 'bootstrap-admin') {
        _knownUsername = username;
      }
    } on FileSystemException {
      // 登录门禁仍可由管理员手动输入账号。
    }
  }

  String? _credentialValidation(String username, String password) {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty) return '管理员账号不能为空';
    if (password.trim().isEmpty) return '管理员密码不能为空';
    if (password.toLowerCase() == 'admin') return '管理员密码不能使用 admin';
    if (password == normalizedUsername) return '管理员密码不能与账号相同';
    return null;
  }

  void lockNow({String message = '控制台已锁定，请重新输入管理员凭据'}) {
    if (!isAuthenticated) return;
    apiClient?.clearSession();
    _cancelAutoLock();
    _accessState = ConsoleAccessState.locked;
    _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
    _accessMessage = message;
    notifyListeners();
  }

  void logout() {
    if (!isAuthenticated) return;
    apiClient?.clearSession();
    _cancelAutoLock();
    _accessState = ConsoleAccessState.loginRequired;
    _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
    _accessMessage = '已退出并清除当前内存会话';
    notifyListeners();
  }

  void recordActivity() {
    if (isAuthenticated && _autoLockHours > 0) _scheduleAutoLock();
  }

  void setAutoLockHours(int hours) {
    if (!const {0, 1, 2, 4, 8, 12, 24}.contains(hours) ||
        _autoLockHours == hours) {
      return;
    }
    _autoLockHours = hours;
    _scheduleAutoLock();
    notifyListeners();
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.saveAutoLockHours(hours));
    }
  }

  void setLockShortcut(ConsoleLockShortcut shortcut) {
    if (_lockShortcut == shortcut) return;
    _lockShortcut = shortcut;
    notifyListeners();
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.saveLockShortcut(shortcut));
    }
  }

  void setCloseBehavior(AppCloseBehavior behavior) {
    if (_closeBehavior == behavior) return;
    _closeBehavior = behavior;
    _desktopBehaviorMessage = '默认关闭行为已设为“${behavior.label}”';
    notifyListeners();
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.saveCloseBehavior(behavior));
    }
  }

  Future<bool> setStartupBehavior(AppStartupBehavior behavior) async {
    if (_desktopBehaviorBusy || _startupBehavior == behavior) return true;
    final previous = _startupBehavior;
    _desktopBehaviorBusy = true;
    _desktopBehaviorMessage = '正在更新 Windows 开机自启行为…';
    notifyListeners();
    try {
      final manager = startupManager;
      if (manager != null) await manager.apply(behavior);
      final preferences = _preferences;
      if (preferences != null) await preferences.saveStartupBehavior(behavior);
      _startupBehavior = behavior;
      _desktopBehaviorMessage = '开机行为已设为“${behavior.label}”';
      return true;
    } on Object catch (error) {
      try {
        await startupManager?.apply(previous);
      } on Object {
        // 保留首个可操作错误；下次启动会再次校验计划任务。
      }
      _desktopBehaviorMessage = '更新开机自启失败：$error';
      return false;
    } finally {
      _desktopBehaviorBusy = false;
      notifyListeners();
    }
  }

  void _scheduleAutoLock() {
    _cancelAutoLock();
    if (!isAuthenticated || _autoLockHours == 0) return;
    final delay = _autoLockDelayOverride ?? Duration(hours: _autoLockHours);
    _autoLockTimer = Timer(delay, () => lockNow(message: '已达到无操作锁定时长，请重新登录'));
  }

  void _cancelAutoLock() {
    _autoLockTimer?.cancel();
    _autoLockTimer = null;
  }

  void _handleSessionInvalidated() {
    if (_accessBusy ||
        _accessState == ConsoleAccessState.setupRequired ||
        _accessState == ConsoleAccessState.loginRequired ||
        _accessState == ConsoleAccessState.locked) {
      return;
    }
    _cancelAutoLock();
    _accessState = ConsoleAccessState.loginRequired;
    _serviceConnectionStatus = ServiceConnectionStatus.authenticationRequired;
    _accessMessage = '登录会话已失效，请重新验证管理员身份';
    notifyListeners();
  }

  void dismissIntegratedServiceError() {
    if (_integratedServiceState != IntegratedServiceState.failed) return;
    _bootstrapErrorDismissed = true;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.saveThemeMode(mode));
    }
  }

  void selectRoute(AppRoute route) {
    if (!isAuthenticated || _route == route) return;
    _route = route;
    notifyListeners();
  }

  void setDashboardPollSeconds(int seconds) {
    if (!const {1, 2, 5}.contains(seconds) ||
        _dashboardPollSeconds == seconds) {
      return;
    }
    _dashboardPollSeconds = seconds;
    notifyListeners();
    final preferences = _preferences;
    if (preferences != null) {
      unawaited(preferences.saveDashboardPollSeconds(seconds));
    }
  }

  void updateServiceConnection(ServiceConnectionStatus status) {
    if (status == ServiceConnectionStatus.authenticationRequired &&
        isAuthenticated) {
      _handleSessionInvalidated();
      return;
    }
    if (_serviceConnectionStatus == status) return;
    _serviceConnectionStatus = status;
    notifyListeners();
  }

  Future<void> restartService() async {
    final operations = serviceOperations;
    if (operations == null) {
      throw const ServiceOperationException('当前目录缺少 VNTS2 服务运维脚本');
    }
    await operations.run(ServiceAction.restart);
  }

  @override
  void onWindowClose() {
    if (!_exiting) unawaited(executeCloseBehavior(_closeBehavior));
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showMainWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        unawaited(showMainWindow());
        return;
      case 'minimize_to_tray':
        unawaited(minimizeToTray());
        return;
      case 'stop_service_and_exit':
        unawaited(stopServiceAndExit());
        return;
    }
  }

  @override
  void dispose() {
    _cancelAutoLock();
    apiClient?.onSessionInvalidated = null;
    if (_windowsShellInitialized) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      if (_trayReady && !_exiting) unawaited(trayManager.destroy());
    }
    super.dispose();
  }
}

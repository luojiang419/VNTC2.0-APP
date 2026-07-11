import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';
import 'package:vnt_app/app_navigation.dart';
import 'package:vnt_app/app_version.dart';
import 'package:vnt_app/src/rust/frb_generated.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/theme_provider.dart';
import 'package:vnt_app/pages/main_navigation_shell.dart';
import 'package:vnt_app/data_persistence.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/window_restore_guard.dart';
import 'package:vnt_app/utils/log_utils.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';
import 'package:vnt_app/utils/silent_start_policy.dart';
import 'package:vnt_app/utils/system_tray_icon_path.dart';
import 'package:vnt_app/utils/text_editing_shortcuts.dart';
import 'package:vnt_app/system_tray_manager.dart';
import 'package:vnt_app/config_manager.dart';
import 'package:vnt_app/window_close_behavior.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_manager.dart';
import 'package:vnt_app/update/app_updater_page.dart';
import 'package:vnt_app/update/startup_update_coordinator.dart';
import 'package:vnt_app/update/update_dialog.dart';
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/update/update_session.dart';

final SystemTray systemTray = SystemTray();
final AppWindow appWindow = AppWindow();

/// 是否静默启动（通过 --silent 命令行参数触发）
bool isSilentStart = false;

void _writeBootTrace(String message) {
  try {
    final logsDir = Directory(
      Platform.isWindows
          ? RuntimeStoragePaths.resolveLogsDirectoryPathSync()
          : 'logs',
    );
    if (!logsDir.existsSync()) {
      logsDir.createSync(recursive: true);
    }
    final traceFile = File('${logsDir.path}/boot_trace.log');
    traceFile.writeAsStringSync(
      '${DateTime.now().toIso8601String()} | $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 启动早期诊断不能反过来影响启动
  }
}

/// 检测是否是 Windows 10 或更高版本
bool isWindows10OrGreater() {
  if (!Platform.isWindows) return false;

  try {
    final version = Platform.operatingSystemVersion;
    // Windows 版本格式: "Microsoft Windows [Version 10.0.19045.5247]"
    // Windows 7: 6.1, Windows 8: 6.2, Windows 8.1: 6.3, Windows 10: 10.0
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
    if (match != null) {
      final major = int.parse(match.group(1)!);
      return major >= 10;
    }
  } catch (e) {
    debugPrint('检测 Windows 版本失败: $e');
  }

  // 默认返回 true，使用自定义标题栏
  return true;
}

Future<List<Display>> _safeGetDisplays() async {
  try {
    final primaryDisplay = await screenRetriever.getPrimaryDisplay();
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isNotEmpty) {
      return [
        primaryDisplay,
        ...displays.where((display) => display.id != primaryDisplay.id),
      ];
    }
    return [primaryDisplay];
  } catch (e) {
    _writeBootTrace('screen_retriever error: $e');
    return const [];
  }
}

String _formatDisplaysForLog(List<Display> displays) {
  if (displays.isEmpty) {
    return '[]';
  }
  return displays.map((display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return '{id:${display.id},x:${position.dx},y:${position.dy},w:${size.width},h:${size.height}}';
  }).join(',');
}

Future<void> _runUpdateSessionApp(AppUpdateSession session) async {
  _writeBootTrace('update session enter ${session.sessionId}');
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(520, 320),
      minimumSize: Size(420, 260),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setTitle('VNTC APP2.0 更新');
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(AppUpdaterApp(session: session));
}

Future<void> main(List<String> args) async {
  final startupArgs = <String>[
    ...args,
    for (final arg in Platform.executableArguments)
      if (arg.startsWith('--')) arg,
  ];
  isSilentStart = Platform.isWindows && startupArgs.contains('--silent');

  _writeBootTrace('main enter args=${startupArgs.length}');
  final updateSession = AppUpdateSession.tryParse(startupArgs);
  if (updateSession != null) {
    await _runUpdateSessionApp(updateSession);
    return;
  }

  // macOS 启动时先检查权限，在Flutter初始化之前
  // 避免显示窗口后再提示输入密码
  if (Platform.isMacOS) {
    final needsRestart =
        await MacOSPrivilegeManager.checkAndRequestPrivilegeOnStartup();
    if (needsRestart) {
      // app 正在以管理员权限重新启动，当前进程将退出
      return;
    }
  }

  // 权限检查通过后，再初始化Flutter
  _writeBootTrace('before ensureInitialized');
  WidgetsFlutterBinding.ensureInitialized();
  _writeBootTrace('after ensureInitialized');

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    _writeBootTrace('before sqfliteFfiInit');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _writeBootTrace('after sqfliteFfiInit');
  }

  try {
    _writeBootTrace('before copyLogConfig');
    await copyLogConfig();
    _writeBootTrace('after copyLogConfig');
  } catch (e) {
    _writeBootTrace('copyLogConfig error: $e');
    debugPrint('copyLogConfig catch $e');
  }

  try {
    _writeBootTrace('before copyAppropriateDll');
    await copyAppropriateDll();
    _writeBootTrace('after copyAppropriateDll');
  } catch (e) {
    _writeBootTrace('copyAppropriateDll error: $e');
    debugPrint('copyAppropriateDll catch $e');
  }

  _writeBootTrace('before RustLib.init');
  await RustLib.init();
  _writeBootTrace('after RustLib.init');

  // Windows: 初始化配置管理器
  if (Platform.isWindows) {
    _writeBootTrace('before ConfigManager.init');
    await ConfigManager().init();
    _writeBootTrace('after ConfigManager.init');
  }

  // 初始化日志系统，所有平台统一使用log4rs
  try {
    _writeBootTrace('before init unified log system');
    // 使用统一的日志路径工具类获取日志目录
    final logDir = await LogUtils.getLogDirectory();
    debugPrint('日志目录: $logDir');

    // 确保日志目录存在
    final logsDirectory = Directory(logDir);
    if (!await logsDirectory.exists()) {
      await logsDirectory.create(recursive: true);
      debugPrint('创建日志目录: $logDir');
    }

    // 调用Rust层初始化日志
    final configPath = await DataPersistence().getConfigFilePath();
    initLogWithPath(logDir: logDir, configPath: configPath);
    _writeBootTrace('after init unified log system');
    debugPrint('日志系统初始化成功，日志目录: $logDir');
  } catch (e) {
    _writeBootTrace('init unified log system error: $e');
    debugPrint('初始化日志系统失败: $e');
  }

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    _writeBootTrace('before windowManager.ensureInitialized');
    await windowManager.ensureInitialized();
    _writeBootTrace('after windowManager.ensureInitialized');

    // macOS 使用系统原生标题栏（保留所有原生窗口功能）
    if (Platform.isMacOS) {
      // macOS 专用配置 - 使用系统标题栏
      WindowOptions windowOptions = WindowOptions(
        size: const Size(1000, 700),
        minimumSize: const Size(800, 600),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: isSilentStart,
        titleBarStyle: TitleBarStyle.normal, // macOS 使用系统标题栏
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // 加载保存的窗口大小和位置
        final windowSize = await DataPersistence().loadWindowSize();
        if (windowSize != null) {
          await windowManager.setSize(windowSize);
        }

        final windowPosition = await DataPersistence().loadWindowPosition();
        if (windowPosition != null) {
          await windowManager.setPosition(windowPosition);
        }

        // 设置窗口标题
        await windowManager.setTitle(AppVersion.windowTitle);

        // macOS: 由于以root权限运行，隐藏最小化和最大化按钮,只保留关闭按钮
        // 这是因为macOS安全限制导致这些按钮无法正常工作
        await windowManager.setMinimizable(false);
        await windowManager.setMaximizable(false);

        if (isSilentStart) {
          await windowManager.setSkipTaskbar(true);
          await windowManager.hide();
        } else {
          await appWindow.show();
        }
      });
    } else {
      // Windows 和 Linux 保持原有逻辑
      const defaultWindowSize = WindowRestoreGuard.defaultWindowSize;
      const minimumWindowSize = WindowRestoreGuard.minimumWindowSize;
      final windowOptions = WindowOptions(
        size: defaultWindowSize,
        minimumSize: minimumWindowSize,
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: isSilentStart,
      );
      final dataPersistence = DataPersistence();
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        windowManager.setTitle(AppVersion.windowTitle);

        // 只在 Windows 10+ 上使用自定义标题栏，Windows 7 使用系统标题栏
        if (!Platform.isWindows || isWindows10OrGreater()) {
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        }

        await windowManager.setMinimumSize(minimumWindowSize);

        final savedWindowSize = await dataPersistence.loadSavedWindowSize();
        final savedWindowPosition =
            await dataPersistence.loadSavedWindowPosition();
        final displays = await _safeGetDisplays();
        final placement = WindowRestoreGuard.resolve(
          displays: displays,
          defaultSize: defaultWindowSize,
          minimumSize: minimumWindowSize,
          savedSize: savedWindowSize,
          savedPosition: savedWindowPosition,
        );

        _writeBootTrace(
          'window restore input size=${savedWindowSize?.width}x${savedWindowSize?.height} '
          'pos=${savedWindowPosition?.dx},${savedWindowPosition?.dy} '
          'displays=${_formatDisplaysForLog(displays)}',
        );

        await windowManager.setSize(placement.size);
        await windowManager.setPosition(placement.position);
        await dataPersistence.saveWindowSize(placement.size);
        await dataPersistence.saveWindowPosition(placement.position);

        if (isSilentStart) {
          await windowManager.setSkipTaskbar(true);
          await windowManager.hide();
        } else {
          await appWindow.show();
          await windowManager.focus();
        }

        _writeBootTrace(
          'window restore decision=${placement.decision.name} '
          'reason=${placement.reason} '
          'size=${placement.size.width}x${placement.size.height} '
          'pos=${placement.position.dx},${placement.position.dy}',
        );
      });
    }
  }

  if (Platform.isAndroid) {
    VntAppCall.init();
  }

  _writeBootTrace('before runApp');
  runApp(const VntApp());
  _writeBootTrace('after runApp');
}

class VntApp extends StatefulWidget {
  const VntApp({super.key});

  @override
  State<VntApp> createState() => _VntAppState();
}

class _VntAppState extends State<VntApp> {
  ThemeMode _themeMode = ThemeMode.system;
  Color _customThemeColor = AppTheme.primaryColor; // 默认主题色

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _loadCustomThemeColor();
  }

  Future<void> _loadThemeMode() async {
    final savedMode = await DataPersistence().loadThemeMode();
    if (savedMode != null && mounted) {
      setState(() {
        _themeMode = savedMode;
      });
    }
  }

  Future<void> _loadCustomThemeColor() async {
    final savedColor = await DataPersistence().loadCustomThemeColor();
    if (savedColor != null && mounted) {
      setState(() {
        _customThemeColor = savedColor;
      });
    }
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
    DataPersistence().saveThemeMode(mode);
  }

  void _setCustomThemeColor(Color color) {
    setState(() {
      _customThemeColor = color;
    });
    DataPersistence().saveCustomThemeColor(color);
  }

  @override
  Widget build(BuildContext context) {
    return ThemeProvider(
      themeMode: _themeMode,
      setThemeMode: _setThemeMode,
      customThemeColor: _customThemeColor,
      setCustomThemeColor: _setCustomThemeColor,
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        debugShowCheckedModeBanner: false,
        title: AppVersion.windowTitle,
        // 添加本地化支持
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'), // 简体中文
          Locale('zh', 'Hans'), // 简体中文
          Locale('en', ''), // 英文
        ],
        locale: const Locale('zh', 'CN'), // 默认使用中文
        theme: AppTheme.createLightTheme(_customThemeColor),
        darkTheme: AppTheme.createDarkTheme(_customThemeColor),
        themeMode: _themeMode,
        builder: (context, child) {
          return VntTextEditingShortcuts(
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (Platform.isAndroid) {
              VntAppCall.moveTaskToBack();
            }
          },
          child: const MainApp(),
        ),
      ),
    );
  }
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WindowListener {
  static const Duration _startupUpdateCheckDelay = Duration(seconds: 2);

  bool rememberChoice = false;
  late final Future<bool> _systemTrayInitialization;
  late final AppUpdateService _startupUpdateService;
  late final StartupUpdateCoordinator _startupUpdateCoordinator;
  bool _startupUpdatePromptInProgress = false;

  @override
  void initState() {
    super.initState();

    _startupUpdateService = AppUpdateService();
    _startupUpdateCoordinator = StartupUpdateCoordinator(
      checkLatest: _startupUpdateService.checkLatest,
    );

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _systemTrayInitialization = _initializeSystemTrayForStartup();
      // 设置窗口关闭拦截
      windowManager.setPreventClose(true);
      windowManager.addListener(this);
    } else {
      _systemTrayInitialization = Future<bool>.value(false);
    }

    if (ChatManager.instance.supported) {
      unawaited(ChatManager.instance.start());
    }
    if (!Platform.isAndroid ||
        RemoteAssistConstants.androidRemoteAssistEnabled) {
      unawaited(RemoteAssistManager.instance.start());
    }

    // 设置Android启动回调
    // 当从磁贴点击启动时，自动连接指定配置或默认配置
    VntAppCall.setStartCall((String? configKey) async {
      try {
        final dataPersistence = DataPersistence();

        // 如果没有指定配置key，尝试从磁贴获取
        String? targetKey = configKey;
        if (targetKey == null || targetKey.isEmpty) {
          // 检查是否从磁贴长按选择了配置
          targetKey = await VntAppCall.getTileConfigKey();
          debugPrint('从磁贴获取配置key: $targetKey');
        }

        // 如果还是没有，使用默认配置
        if (targetKey == null || targetKey.isEmpty) {
          targetKey = await dataPersistence.loadDefaultKey();
          if (targetKey == null || targetKey.isEmpty) {
            debugPrint('磁贴启动：未设置默认配置');
            return;
          }
        }

        final configs = await dataPersistence.loadData();
        final config = configs.where((c) => c.itemKey == targetKey).firstOrNull;

        if (config == null) {
          debugPrint('磁贴启动：配置不存在 (key: $targetKey)');
          return;
        }

        // 如果当前已有连接，先断开所有连接
        if (vntManager.hasConnection()) {
          debugPrint('磁贴启动：检测到已有连接，先断开所有连接');
          await vntManager.removeAll();
          // 等待更长时间确保断开完成和VPN资源释放
          await Future.delayed(const Duration(milliseconds: 1000));
          debugPrint('磁贴启动：断开完成，准备连接新配置');
        }

        // 检查是否正在连接
        if (vntManager.isConnecting()) {
          debugPrint('磁贴启动：正在连接中，跳过');
          return;
        }

        // 开始连接
        debugPrint(
            '磁贴启动：开始连接配置 [${config.configName}] (key: ${config.itemKey})');
        final receivePort = ReceivePort();

        receivePort.listen((msg) {
          if (msg is String) {
            if (msg == 'success') {
              debugPrint('磁贴启动：连接成功');
              // 连接成功，更新磁贴和小组件状态
              VntAppCall.updateWidgetAndTile(true);
              // 更新Windows托盘
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
                SystemTrayManager().updateMenu();
                SystemTrayManager().updateTooltip();
              }
            } else if (msg == 'stop') {
              vntManager.remove(config.itemKey);
              debugPrint('磁贴启动：连接失败或停止');
              // 连接停止，更新磁贴和小组件状态
              VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
              // 更新Windows托盘
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
                SystemTrayManager().updateMenu();
                SystemTrayManager().updateTooltip();
              }
            }
          } else if (msg is RustErrorInfo) {
            // Disconnect 和 Warn 类型不销毁连接，Rust 层会自动重连
            if (msg.code == RustErrorType.disconnect ||
                msg.code == RustErrorType.warn) {
              debugPrint('磁贴启动：连接错误（非致命） - ${msg.msg}');
              // 不销毁连接，只显示提示
              return;
            }

            // 其他致命错误才销毁连接
            vntManager.remove(config.itemKey);
            debugPrint('磁贴启动：连接错误 - ${msg.msg}');
            // 连接错误，更新磁贴和小组件状态
            VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
            // 更新Windows托盘
            if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
              SystemTrayManager().updateMenu();
              SystemTrayManager().updateTooltip();
            }
          }
        });

        await vntManager.create(config, receivePort.sendPort);
        debugPrint('磁贴启动：VntBox��建完成，等待连接结果');
      } catch (e) {
        debugPrint('磁贴启动连接失败: $e');
        // 连接异常，更新磁贴和小组件状态
        VntAppCall.updateWidgetAndTile(vntManager.hasConnection());
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForStartupUpdate());
    });
  }

  Future<void> _checkForStartupUpdate() async {
    if (!Platform.isWindows) {
      return;
    }

    await Future<void>.delayed(_startupUpdateCheckDelay);
    if (!mounted) {
      return;
    }

    try {
      final update = await _startupUpdateCoordinator.checkOnce();
      if (update == null) {
        _writeBootTrace('startup update check: already latest');
        return;
      }
      _writeBootTrace(
        'startup update check: ${update.currentVersion} -> ${update.latestVersion}',
      );
      await _showPendingStartupUpdateIfReady();
    } catch (error) {
      _writeBootTrace('startup update check failed: $error');
      debugPrint('启动自动检查更新失败: $error');
    }
  }

  Future<void> _showPendingStartupUpdateIfReady() async {
    if (!mounted ||
        !_startupUpdateCoordinator.hasPendingUpdate ||
        _startupUpdatePromptInProgress) {
      return;
    }

    if (isSilentStart && !await windowManager.isVisible()) {
      _writeBootTrace('startup update prompt deferred while window hidden');
      return;
    }
    if (!mounted) {
      return;
    }

    final update = _startupUpdateCoordinator.pendingUpdate;
    if (update == null) {
      return;
    }

    _startupUpdatePromptInProgress = true;
    try {
      final shown = await showUpdateAvailableDialog(
        context: context,
        info: update,
        service: _startupUpdateService,
      );
      if (shown) {
        _startupUpdateCoordinator.takePendingUpdate();
      }
    } finally {
      _startupUpdatePromptInProgress = false;
    }
  }

  Future<bool> _initializeSystemTrayForStartup() async {
    final initialized = await initSystemTray();
    final action = resolveSilentStartWindowAction(
      silentStart: isSilentStart,
      trayInitialized: initialized,
    );
    switch (action) {
      case SilentStartWindowAction.showNormally:
        break;
      case SilentStartWindowAction.keepHidden:
        await windowManager.setSkipTaskbar(true);
        await windowManager.hide();
        _writeBootTrace(
            'silent start confirmed hidden after tray initialization');
        break;
      case SilentStartWindowAction.showTrayFailureFallback:
        await windowManager.setSkipTaskbar(false);
        await windowManager.show();
        await windowManager.focus();
        _writeBootTrace(
            'silent start fallback shown because tray initialization failed');
        break;
    }
    return initialized;
  }

  Future<void> _prepareForAppExit() async {
    await ChatManager.instance.stop();
    await RemoteAssistManager.instance.stop();
    await vntManager.removeAll();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() {
    if (Platform.isWindows) {
      unawaited(_showPendingStartupUpdateIfReady());
    }
  }

  @override
  void onWindowResize() async {
    final size = await windowManager.getSize();
    DataPersistence().saveWindowSize(size);
  }

  @override
  void onWindowMove() async {
    final position = await windowManager.getPosition();
    DataPersistence().saveWindowPosition(position);
  }

  @override
  void onWindowClose() async {
    // macOS 显示特殊的确认对话框（说明由于安全限制无法最小化）
    if (Platform.isMacOS) {
      final shouldClose = await _showMacOSCloseConfirmationDialog();
      if (shouldClose == true) {
        // 退出应用：先断开连接再关闭
        await _prepareForAppExit();
        windowManager.setPreventClose(false);
        await windowManager.destroy();
        exit(0);
      }
      // 如果用户点击取消，什么都不做（窗口保持打开）
      return;
    }

    // Windows 和 Linux 保持原有的确认逻辑
    var closeBehavior = await DataPersistence().loadWindowCloseBehavior();
    if (closeBehavior == WindowCloseBehavior.ask) {
      final selectedBehavior = await _showCloseConfirmationDialog(
        closeBehavior,
      );
      if (selectedBehavior == null) {
        return;
      }
      closeBehavior = selectedBehavior;
    }
    await _performCloseBehavior(closeBehavior);
  }

  Future<void> _performCloseBehavior(
    WindowCloseBehavior closeBehavior,
  ) async {
    switch (closeBehavior) {
      case WindowCloseBehavior.ask:
        return;
      case WindowCloseBehavior.minimizeToTray:
        final systemTrayReady = await _systemTrayInitialization;
        if (!systemTrayReady) {
          const message = '系统托盘初始化失败，已取消隐藏窗口以避免托盘入口丢失';
          _writeBootTrace(message);
          debugPrint(message);
          return;
        }
        debugPrint('隐藏到托盘');
        appWindow.hide();
        return;
      case WindowCloseBehavior.exitApp:
        debugPrint('退出应用');
        await _prepareForAppExit();
        windowManager.setPreventClose(false);
        if (Platform.isLinux) {
          await windowManager.destroy();
          exit(0);
        } else {
          appWindow.close();
        }
        return;
    }
  }

  String _closeActionDescription(WindowCloseBehavior closeBehavior) {
    switch (closeBehavior) {
      case WindowCloseBehavior.ask:
        return '关闭时弹出确认，可选择最小化到托盘或退出程序。';
      case WindowCloseBehavior.minimizeToTray:
        return '当前默认动作：最小化到托盘。可勾选“记住此操作”直接保存。';
      case WindowCloseBehavior.exitApp:
        return '当前默认动作：关闭程序。可勾选“记住此操作”直接保存。';
    }
  }

  /// macOS 专用的关闭确认对话框
  Future<bool?> _showMacOSCloseConfirmationDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: isDark
              ? AppTheme.darkCardBackground
              : AppTheme.lightCardBackground,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            '确认退出',
            style: TextStyle(
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          content: Text(
            '由于 macOS 安全限制，应用无法最小化。\n\n你确认要退出程序吗？',
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                '取消',
                style: TextStyle(
                  fontSize: context.fontXSmall,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child:
                  Text('退出应用', style: TextStyle(fontSize: context.fontXSmall)),
            ),
          ],
        );
      },
    );

    return result;
  }

  Future<WindowCloseBehavior?> _showCloseConfirmationDialog(
    WindowCloseBehavior closeBehavior,
  ) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    rememberChoice = false;
    final description = _closeActionDescription(closeBehavior);

    final result = await showDialog<WindowCloseBehavior>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              backgroundColor: isDark
                  ? AppTheme.darkCardBackground
                  : AppTheme.lightCardBackground,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Text(
                '确认关闭',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    description,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: rememberChoice,
                        onChanged: (bool? value) {
                          setState(() {
                            rememberChoice = value ?? false;
                          });
                        },
                        activeColor: primaryColor,
                      ),
                      Text(
                        '记住此操作',
                        style: TextStyle(
                          fontSize: context.fontXSmall,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    WindowCloseBehavior.minimizeToTray,
                  ),
                  child: Text(
                    '隐藏到托盘',
                    style: TextStyle(
                      fontSize: context.fontXSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(
                    WindowCloseBehavior.exitApp,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.errorColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text('退出应用',
                      style: TextStyle(fontSize: context.fontXSmall)),
                ),
              ],
            );
          },
        );
      },
    );

    if (rememberChoice && result != null) {
      await DataPersistence().saveWindowCloseBehavior(result);
    }
    return result;
  }

  void _onThemeChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MainNavigationShell(onThemeChanged: _onThemeChanged);
  }
}

Future<bool> initSystemTray() async {
  String path;

  if (Platform.isLinux) {
    // Linux 复制到 /tmp 并设置普通用户可读权限
    try {
      final iconFile = File('/tmp/vnt_app_icon.png');
      final byteData = await rootBundle.load('assets/app_icon.png');
      await iconFile.writeAsBytes(byteData.buffer.asUint8List());
      // 设置权限为 644 (所有用户可读)
      await Process.run('chmod', ['644', iconFile.path]);
      path = iconFile.path;
    } catch (e) {
      path = resolveSystemTrayIconAssetPath(isWindows: false); // 降级
    }
  } else {
    path = resolveSystemTrayIconAssetPath(
      isWindows: Platform.isWindows,
    );
  }

  try {
    final initialized = await systemTray.initSystemTray(
      title: AppVersion.windowTitle,
      toolTip: AppVersion.trayTooltip,
      iconPath: path,
    );
    _writeBootTrace(
      'system tray init platform=${Platform.operatingSystem} icon=$path result=$initialized',
    );
    if (!initialized) {
      debugPrint('系统托盘初始化失败: icon=$path');
      return false;
    }

    // 初始化 SystemTrayManager，传入全局的 systemTray 实例
    final trayManager = SystemTrayManager();
    trayManager.initialize(systemTray);

    // 更新菜单
    await trayManager.updateMenu();

    // 注册事件处理器
    systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        Platform.isWindows
            ? () async {
                await windowManager.show();
                await windowManager.setSkipTaskbar(false);
                await windowManager.focus();
              }()
            : systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        Platform.isWindows
            ? systemTray.popUpContextMenu()
            : windowManager.show();
      }
    });
    return true;
  } catch (error) {
    _writeBootTrace(
      'system tray init failed platform=${Platform.operatingSystem} icon=$path error=$error',
    );
    debugPrint('系统托盘初始化异常: $error');
    return false;
  }
}

String getArchitecture() {
  if (Platform.isWindows) {
    return Platform.environment['PROCESSOR_ARCHITECTURE']!.toLowerCase();
  }
  return 'unknown';
}

Future<void> copyAppropriateDll() async {
  if (!Platform.isWindows) return;

  final targetDllPath =
      RuntimeStoragePaths.resolveBundledPathSync('wintun.dll');
  final dllFile = File(targetDllPath);
  if (await dllFile.exists()) {
    return;
  }

  final arch = getArchitecture();
  String dllPath;

  switch (arch) {
    case 'x86_64':
    case 'amd64':
      dllPath = 'dlls/amd64/wintun.dll';
      break;
    case 'arm':
      dllPath = 'dlls/arm/wintun.dll';
      break;
    case 'aarch64':
    case 'arm64':
      dllPath = 'dlls/arm64/wintun.dll';
      break;
    case 'i386':
    case 'i686':
    case 'x86':
      dllPath = 'dlls/x86/wintun.dll';
      break;
    default:
      throw UnsupportedError('Unsupported architecture: $arch');
  }

  final sourceFile = File(RuntimeStoragePaths.resolveBundledPathSync(dllPath));
  await sourceFile.copy(dllFile.path);
}

Future<void> copyLogConfig() async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return;
  }
  final logConfigDirectory = Directory(await LogUtils.getLogDirectory());
  final logConfigFile = File('${logConfigDirectory.path}/log4rs.yaml');
  if (!logConfigFile.parent.existsSync()) {
    await logConfigFile.parent.create();
  }

  if (await logConfigFile.exists()) {
    debugPrint('日志配置已存在');
    return;
  }

  final byteData = await rootBundle.load('assets/log4rs.yaml');
  await logConfigFile.writeAsBytes(byteData.buffer
      .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
}

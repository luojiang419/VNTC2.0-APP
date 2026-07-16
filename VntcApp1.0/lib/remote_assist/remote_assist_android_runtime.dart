import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/common.dart' as hbb_common;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart' as hbb_main;
import 'package:flutter_hbb/mobile/pages/server_page.dart'
    show androidChannelInit;
import 'package:flutter_hbb/models/platform_model.dart' as hbb_platform;

import 'remote_assist_android_bridge.dart';
import 'remote_assist_constants.dart';

class RemoteAssistAndroidRuntime {
  RemoteAssistAndroidRuntime._();

  static final RemoteAssistAndroidRuntime instance =
      RemoteAssistAndroidRuntime._();

  Completer<void>? _bootstrapCompleter;
  Completer<void>? _controlledStartCompleter;

  Future<void> ensureInitialized() {
    final existing = _bootstrapCompleter;
    if (existing != null) {
      return existing.future;
    }

    final completer = Completer<void>();
    _bootstrapCompleter = completer;

    () async {
      try {
        if (!Platform.isAndroid) {
          throw UnsupportedError('当前运行时仅支持 Android 远程协助宿主链路');
        }
        await hbb_main.initEnv(kAppTypeMain);
        androidChannelInit();
        hbb_platform.platformFFI.syncAndroidServiceAppDirConfigPath();
        await hbb_common.gFFI.invokeMethod('check_service');
        completer.complete();
      } catch (error, stackTrace) {
        _bootstrapCompleter = null;
        completer.completeError(error, stackTrace);
      }
    }();

    return completer.future;
  }

  Future<void> refreshState() async {
    final alreadyInitialized = _bootstrapCompleter?.isCompleted ?? false;
    await ensureInitialized();
    if (alreadyInitialized) {
      await hbb_common.gFFI.invokeMethod('check_service');
    }
  }

  Future<void> configureAccessPassword(String password) async {
    await ensureInitialized();

    final trimmed = password.trim();
    final expectedApproveMode = trimmed.isEmpty ? 'click' : 'password';
    final expectedVerificationMethod =
        trimmed.isEmpty ? null : 'use-permanent-password';

    await hbb_platform.bind.mainSetPermanentPassword(password: trimmed);
    if (expectedVerificationMethod != null) {
      await hbb_platform.bind.mainSetOption(
        key: kOptionVerificationMethod,
        value: expectedVerificationMethod,
      );
    }
    await hbb_platform.bind.mainSetOption(
      key: kOptionApproveMode,
      value: expectedApproveMode,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final savedPassword = await hbb_platform.bind.mainGetPermanentPassword();
    final savedApproveMode =
        await hbb_platform.bind.mainGetOption(key: kOptionApproveMode);
    final savedVerificationMethod =
        await hbb_platform.bind.mainGetOption(key: kOptionVerificationMethod);
    if (savedPassword != trimmed ||
        savedApproveMode != expectedApproveMode ||
        (expectedVerificationMethod != null &&
            savedVerificationMethod != expectedVerificationMethod)) {
      throw StateError(
        'Android 远程协助密码配置未生效: '
        'savedApproveMode=$savedApproveMode '
        'savedVerificationMethod=$savedVerificationMethod',
      );
    }

    await hbb_common.gFFI.serverModel.updatePasswordModel();
  }

  Future<String> loadAccessPassword() async {
    await ensureInitialized();
    return (await hbb_platform.bind.mainGetPermanentPassword()).trim();
  }

  Future<void> startControlledService() {
    final existing = _controlledStartCompleter;
    if (existing != null) {
      return existing.future;
    }

    final completer = Completer<void>();
    _controlledStartCompleter = completer;
    () async {
      try {
        await ensureInitialized();

        final status = await RemoteAssistAndroidBridge.instance.getStatus();
        if (!status.screenCapturePermissionGranted) {
          await RemoteAssistAndroidBridge.instance.requestPermission(
            RemoteAssistConstants.androidPermissionScreenCapture,
          );
          await _waitForScreenCapturePermission();
        }

        // MediaProjection 就绪事件会让 RustDesk 模型自动继续启动。只在它尚未
        // 启动时补一次调用，避免一次授权触发两套监听与 FFI 初始化。
        if (!hbb_common.gFFI.serverModel.isStart) {
          await hbb_common.gFFI.serverModel.startService();
        }
        await _waitForControlledRuntime();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_controlledStartCompleter, completer)) {
          _controlledStartCompleter = null;
        }
      }
    }();
    return completer.future;
  }

  Future<void> _waitForScreenCapturePermission() async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final status = await RemoteAssistAndroidBridge.instance.getStatus();
      if (status.screenCapturePermissionGranted) {
        return;
      }
      if (status.screenCaptureState == 'cancelled') {
        throw StateError('用户取消了屏幕录制授权');
      }
      if (status.screenCaptureState == 'error') {
        throw StateError(
          status.screenCaptureError.isEmpty
              ? '屏幕录制授权初始化失败'
              : status.screenCaptureError,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TimeoutException('等待屏幕录制授权超时，请保持应用在前台后重试');
  }

  Future<void> _waitForControlledRuntime() async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      final status = await RemoteAssistAndroidBridge.instance.getStatus();
      if (status.controlledRuntimeReady && status.listenerReady) {
        return;
      }
      if (status.screenCaptureState == 'stopped' ||
          status.screenCaptureState == 'error') {
        throw StateError(
          status.screenCaptureError.isEmpty
              ? '屏幕录制会话在远控监听就绪前已停止'
              : status.screenCaptureError,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TimeoutException('远程协助服务已启动，但 49999 端口未在预期时间内就绪');
  }

  Future<void> stopControlledService() async {
    await ensureInitialized();
    await hbb_common.gFFI.serverModel.stopService();
  }
}

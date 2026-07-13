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

  Future<void> startControlledService() async {
    await ensureInitialized();

    final status = await RemoteAssistAndroidBridge.instance.getStatus();
    if (!status.screenCapturePermissionGranted) {
      await RemoteAssistAndroidBridge.instance.requestPermission(
        RemoteAssistConstants.androidPermissionScreenCapture,
      );
      throw StateError('请先完成屏幕录制授权，再启动受控服务');
    }

    await hbb_common.gFFI.serverModel.startService();
  }

  Future<void> stopControlledService() async {
    await ensureInitialized();
    await hbb_common.gFFI.serverModel.stopService();
  }
}

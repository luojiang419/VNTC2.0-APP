import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

String chatAndroidLocalNetworkPermissionIssue() {
  return '请在系统权限中允许“附近设备/本地网络”，聊天室才能使用 VNT 网络';
}

class ChatAndroidPermissionService {
  ChatAndroidPermissionService._();

  static final ChatAndroidPermissionService instance =
      ChatAndroidPermissionService._();

  static const MethodChannel _channel = MethodChannel(
    'top.wherewego.vnt/chat_android',
  );

  Future<bool>? _checkInProgress;
  bool _requestAttempted = false;

  Future<bool> ensureLocalNetworkPermission({
    bool requestIfNeeded = false,
  }) {
    if (!Platform.isAndroid) {
      return Future<bool>.value(true);
    }
    return _checkInProgress ??= _checkPermission(requestIfNeeded).whenComplete(
      () => _checkInProgress = null,
    );
  }

  Future<bool> _checkPermission(bool requestIfNeeded) async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('hasLocalNetworkPermission') ??
              false;
      if (granted || !requestIfNeeded || _requestAttempted) {
        return granted;
      }
      _requestAttempted = true;
      return await _channel
              .invokeMethod<bool>('requestLocalNetworkPermission') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

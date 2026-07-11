import 'package:vnt_app/update/update_service.dart';

typedef StartupLatestUpdateCheck = Future<AppUpdateInfo> Function();

class StartupUpdateCoordinator {
  StartupUpdateCoordinator({required StartupLatestUpdateCheck checkLatest})
      : _checkLatest = checkLatest;

  final StartupLatestUpdateCheck _checkLatest;

  bool _checkStarted = false;
  AppUpdateInfo? _pendingUpdate;

  bool get checkStarted => _checkStarted;
  bool get hasPendingUpdate => _pendingUpdate != null;
  AppUpdateInfo? get pendingUpdate => _pendingUpdate;

  Future<AppUpdateInfo?> checkOnce() async {
    if (_checkStarted) {
      return _pendingUpdate;
    }
    _checkStarted = true;

    final info = await _checkLatest();
    if (info.hasUpdate) {
      _pendingUpdate = info;
    }
    return _pendingUpdate;
  }

  AppUpdateInfo? takePendingUpdate() {
    final update = _pendingUpdate;
    _pendingUpdate = null;
    return update;
  }
}

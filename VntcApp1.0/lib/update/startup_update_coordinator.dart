import 'package:vnt_app/update/app_update_preferences.dart';
import 'package:vnt_app/update/update_service.dart';

typedef StartupLatestUpdateCheck = Future<AppUpdateInfo> Function();
typedef StartupUpdateDownload = Future<AppUpdateDownloadResult> Function(
  AppUpdateInfo info,
);

class PreparedStartupUpdate {
  const PreparedStartupUpdate({
    required this.mode,
    required this.info,
    required this.download,
  });

  final AppUpdateMode mode;
  final AppUpdateInfo info;
  final AppUpdateDownloadResult? download;

  bool get isReadyToInstall => download != null;
  bool get shouldInstallAutomatically =>
      isReadyToInstall && mode.installsAutomatically;
}

class StartupUpdateCoordinator {
  StartupUpdateCoordinator({
    required StartupLatestUpdateCheck checkLatest,
    required StartupUpdateDownload downloadUpdate,
  })  : _checkLatest = checkLatest,
        _downloadUpdate = downloadUpdate;

  final StartupLatestUpdateCheck _checkLatest;
  final StartupUpdateDownload _downloadUpdate;

  bool _preparationStarted = false;
  PreparedStartupUpdate? _pendingUpdate;

  bool get preparationStarted => _preparationStarted;
  bool get hasPendingUpdate => _pendingUpdate != null;
  PreparedStartupUpdate? get pendingUpdate => _pendingUpdate;

  Future<PreparedStartupUpdate?> prepareOnce(AppUpdateMode mode) async {
    if (_preparationStarted) {
      return _pendingUpdate;
    }
    _preparationStarted = true;

    if (!mode.checksForUpdates) {
      return null;
    }

    final info = await _checkLatest();
    if (!info.hasUpdate) {
      return null;
    }

    final download = info.canDownload ? await _downloadUpdate(info) : null;
    _pendingUpdate = PreparedStartupUpdate(
      mode: mode,
      info: info,
      download: download,
    );
    return _pendingUpdate;
  }

  PreparedStartupUpdate? takePendingUpdate() {
    final update = _pendingUpdate;
    _pendingUpdate = null;
    return update;
  }
}

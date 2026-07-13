import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/utils/toast_utils.dart';

bool _updateAvailableDialogVisible = false;
bool _manualUpdateCheckActive = false;

Future<void> showUpdateCheckDialog(
  BuildContext context, {
  AppUpdateService? service,
}) async {
  if (_manualUpdateCheckActive) {
    return;
  }
  _manualUpdateCheckActive = true;
  try {
    final updateService = service ?? AppUpdateService();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在检查 GitHub 最新版本...')),
          ],
        ),
      ),
    );

    AppUpdateInfo info;
    try {
      info = await updateService.checkLatest();
    } catch (error) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        showTopToast(context, '检查更新失败: $error', isSuccess: false);
      }
      return;
    }

    if (!context.mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();

    if (!info.hasUpdate) {
      showTopToast(
        context,
        '当前已是最新版本：v${info.currentVersion}',
        isSuccess: true,
      );
      return;
    }

    await showUpdateAvailableDialog(
      context: context,
      info: info,
      service: updateService,
      allowDuringManualCheck: true,
    );
  } finally {
    _manualUpdateCheckActive = false;
  }
}

Future<bool> showUpdateAvailableDialog({
  required BuildContext context,
  required AppUpdateInfo info,
  required AppUpdateService service,
  bool allowDuringManualCheck = false,
}) async {
  if (!context.mounted ||
      _updateAvailableDialogVisible ||
      (_manualUpdateCheckActive && !allowDuringManualCheck)) {
    return false;
  }

  _updateAvailableDialogVisible = true;
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => _UpdateAvailableDialog(
        info: info,
        service: service,
      ),
    );
    return true;
  } finally {
    _updateAvailableDialogVisible = false;
  }
}

class _UpdateAvailableDialog extends StatefulWidget {
  const _UpdateAvailableDialog({
    required this.info,
    required this.service,
  });

  final AppUpdateInfo info;
  final AppUpdateService service;

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  bool _downloading = false;
  double _progress = 0;
  String _statusText = '准备下载更新包...';

  Future<void> _downloadAndInstall() async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _statusText = '正在下载更新包...';
    });

    try {
      final result = await widget.service.downloadUpdate(
        widget.info,
        onProgress: (received, total) {
          if (!mounted || total <= 0) {
            return;
          }
          setState(() {
            _progress = received / total;
          });
        },
      );
      if (Platform.isWindows) {
        if (mounted) {
          setState(() {
            _statusText = '正在启动静默更新器...';
          });
        }
        await widget.service.launchWindowsSilentInstaller(result);
        if (!mounted) {
          return;
        }
        showTopToast(context, '更新器已启动，应用即将退出', isSuccess: true);
        Navigator.of(context).pop();
        Timer(const Duration(milliseconds: 700), () {
          exit(0);
        });
        return;
      }

      if (mounted) {
        setState(() {
          _statusText = Platform.isAndroid
              ? '正在打开系统安装器...'
              : '正在打开安装包...';
        });
      }
      await widget.service.openDownloadedInstaller(result);
      if (!mounted) {
        return;
      }
      showTopToast(context, '安装包已下载，已交给系统处理', isSuccess: true);
      Navigator.of(context).pop();
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      final message = switch (error.code) {
        'INSTALL_PERMISSION_DENIED' =>
          '未授予安装权限，安装包已保留，可授权后重新安装',
        'REQUEST_IN_PROGRESS' => '已有安装授权请求正在处理',
        _ => '下载或打开失败: ${error.message ?? error.code}',
      };
      showTopToast(context, message, isSuccess: false);
      setState(() {
        _downloading = false;
        _statusText = message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '下载或打开失败: $error', isSuccess: false);
      setState(() {
        _downloading = false;
      });
    }
  }

  Future<void> _openReleasePage() async {
    try {
      await widget.service.openReleasePage(widget.info);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        showTopToast(context, '无法打开发布页面: $error', isSuccess: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final primaryColor = Theme.of(context).primaryColor;
    final proxyText = info.proxyLabel == null ? '未使用代理' : info.proxyLabel!;
    final releaseNotes = info.shortReleaseNotes.isEmpty
        ? '此版本没有填写更新说明。'
        : info.shortReleaseNotes;

    return AlertDialog(
      title: const Text('发现新版本'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前版本：v${info.currentVersion}'),
            const SizedBox(height: 6),
            Text('最新版本：v${info.latestVersion}'),
            const SizedBox(height: 6),
            Text('网络代理：$proxyText'),
            const SizedBox(height: 12),
            Text(
              releaseNotes,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
            ),
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress.clamp(0, 1),
                color: primaryColor,
              ),
              const SizedBox(height: 8),
              Text(_statusText),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: _downloading ? null : _openReleasePage,
          child: const Text('发布页'),
        ),
        FilledButton(
          onPressed: _downloading
              ? null
              : info.canDownload
                  ? _downloadAndInstall
                  : _openReleasePage,
          child: Text(
            info.canDownload
                ? Platform.isWindows
                    ? '静默更新'
                    : '下载并安装'
                : '打开更新页面',
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vnt_app/update/app_update_config.dart';
import 'package:vnt_app/update/update_session.dart';
import 'package:vnt_app/utils/runtime_storage_paths.dart';

enum AppUpdatePlatform {
  android,
  windows,
  macos,
  linux,
  ios,
  unsupported,
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.contentType,
    this.sha256,
    this.checksumUrl,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? contentType;
  final String? sha256;
  final Uri? checksumUrl;

  static AppUpdateAsset? fromGitHubJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString();
    final rawUrl = (json['browser_download_url'] ?? '').toString();
    final url = Uri.tryParse(rawUrl);
    if (name.isEmpty || url == null) {
      return null;
    }
    return AppUpdateAsset(
      name: name,
      downloadUrl: url,
      size: int.tryParse('${json['size'] ?? 0}') ?? 0,
      contentType: json['content_type']?.toString(),
      sha256: normalizeSha256Value(
            json['sha256']?.toString(),
          ) ??
          normalizeSha256Value(json['digest']?.toString()),
    );
  }

  AppUpdateAsset copyWith({
    String? sha256,
    Uri? checksumUrl,
  }) {
    return AppUpdateAsset(
      name: name,
      downloadUrl: downloadUrl,
      size: size,
      contentType: contentType,
      sha256: sha256 ?? this.sha256,
      checksumUrl: checksumUrl ?? this.checksumUrl,
    );
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    required this.releaseName,
    required this.releaseNotes,
    required this.releasePageUrl,
    required this.hasUpdate,
    required this.platform,
    required this.asset,
    this.proxyLabel,
  });

  final String currentVersion;
  final String latestVersion;
  final String tagName;
  final String releaseName;
  final String releaseNotes;
  final Uri releasePageUrl;
  final bool hasUpdate;
  final AppUpdatePlatform platform;
  final AppUpdateAsset? asset;
  final String? proxyLabel;

  bool get canDownload => asset != null && platform != AppUpdatePlatform.ios;

  String get shortReleaseNotes {
    final trimmed = releaseNotes.trim();
    if (trimmed.length <= 500) {
      return trimmed;
    }
    return '${trimmed.substring(0, 500)}...';
  }
}

class AppUpdateDownloadResult {
  const AppUpdateDownloadResult({
    required this.filePath,
    required this.asset,
    this.versionTag = '',
    this.proxyLabel,
  });

  final String filePath;
  final AppUpdateAsset asset;
  final String versionTag;
  final String? proxyLabel;
}

class AppUpdateProxy {
  const AppUpdateProxy({
    required this.config,
    required this.label,
  });

  final String config;
  final String label;

  String get curlProxyUrl {
    final parts = config.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return config;
    }
    final scheme = parts.first.toUpperCase() == 'SOCKS' ? 'socks5h' : 'http';
    return '$scheme://${parts.sublist(1).join(' ')}';
  }
}

typedef AppUpdateProgress = void Function(int received, int total);

class AppUpdateService {
  AppUpdateService({
    Future<AppUpdateProxy?> Function()? proxyResolver,
  }) : _proxyResolver = proxyResolver ?? AppUpdateProxyResolver.resolve;

  static const latestReleaseApiUrl = AppUpdateConfig.latestReleaseApiUrl;
  static const releasePageUrl = AppUpdateConfig.releasePageUrl;

  final Future<AppUpdateProxy?> Function() _proxyResolver;

  Future<AppUpdateInfo> checkLatest({
    String? currentVersion,
    AppUpdatePlatform? platform,
  }) async {
    _ensureUpdateEnabled();
    final proxy = await _proxyResolver();
    final release = await _fetchJson(
      Uri.parse(latestReleaseApiUrl),
      proxy: proxy,
    );
    final resolvedCurrentVersion =
        currentVersion ?? await _resolveCurrentVersion();
    final resolvedPlatform = platform ?? resolveCurrentUpdatePlatform();
    return parseGitHubRelease(
      release,
      currentVersion: resolvedCurrentVersion,
      platform: resolvedPlatform,
      proxyLabel: proxy?.label,
    );
  }

  Future<AppUpdateDownloadResult> downloadUpdate(
    AppUpdateInfo info, {
    AppUpdateProgress? onProgress,
  }) async {
    _ensureUpdateEnabled();
    final asset = info.asset;
    if (asset == null) {
      throw StateError('当前平台没有可下载的安装包');
    }
    if (info.platform == AppUpdatePlatform.ios) {
      throw StateError('iOS 版本需要通过 TestFlight、App Store 或企业分发更新');
    }

    final proxy = await _proxyResolver();
    final verifiedAsset = await _withResolvedSha256(asset, proxy: proxy);

    final directory = await _resolveDownloadDirectory();
    await directory.create(recursive: true);
    final filePath =
        path.join(directory.path, _safeFileName(verifiedAsset.name));
    final target = File(filePath);
    if (await _isCompleteDownload(target, verifiedAsset)) {
      return AppUpdateDownloadResult(
        filePath: target.path,
        asset: verifiedAsset,
        versionTag: info.tagName,
        proxyLabel: info.proxyLabel,
      );
    }

    final partial = File('$filePath.part');
    if (await target.exists()) {
      await target.delete();
    }
    if (await partial.exists()) {
      await partial.delete();
    }

    try {
      await _downloadFile(
        asset.downloadUrl,
        partial,
        proxy: proxy,
        expectedSize: verifiedAsset.size,
        onProgress: onProgress,
      );
      await _verifyDownloadedFile(partial, verifiedAsset);
      await partial.rename(target.path);
    } catch (_) {
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    }

    if (Platform.isLinux &&
        verifiedAsset.name.toLowerCase().endsWith('.appimage')) {
      await Process.run('chmod', ['+x', target.path], runInShell: true);
    }

    return AppUpdateDownloadResult(
      filePath: target.path,
      asset: verifiedAsset,
      versionTag: info.tagName,
      proxyLabel: proxy?.label,
    );
  }

  Future<void> openDownloadedInstaller(AppUpdateDownloadResult result) async {
    _ensureUpdateEnabled();
    if (Platform.isAndroid) {
      await AndroidUpdateInstaller.installApk(result.filePath);
      return;
    }
    final uri = Uri.file(result.filePath);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw StateError('无法打开安装包：${result.filePath}');
    }
  }

  Future<void> openReleasePage([AppUpdateInfo? info]) async {
    _ensureUpdateEnabled();
    final uri = info?.releasePageUrl ?? Uri.parse(releasePageUrl);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw StateError('无法打开发布页面：$uri');
    }
  }

  Future<AppUpdateSession> launchWindowsSilentInstaller(
    AppUpdateDownloadResult result,
  ) async {
    _ensureUpdateEnabled();
    if (!Platform.isWindows) {
      throw StateError('静默升级仅支持 Windows 安装包');
    }

    final installer = File(result.filePath);
    if (!await installer.exists()) {
      throw StateError('安装包不存在：${result.filePath}');
    }
    _ensureSupportedWindowsSilentInstaller(result);
    await _verifyDownloadedFile(installer, result.asset);
    await _verifyWindowsInstallerAuthenticode(
      installer,
      sha256Verified: true,
    );

    final appDir = path.dirname(Platform.resolvedExecutable);
    final storageRoot = (await _resolveDownloadDirectory()).path;
    final launchPath = await _resolveWindowsLaunchPath(appDir);
    final session = AppUpdateSession.create(
      versionTag:
          result.versionTag.isEmpty ? result.asset.name : result.versionTag,
      installerPath: installer.path,
      installRoot: appDir,
      storageRoot: storageRoot,
      launchPath: launchPath,
    );
    await session.writeManifest();

    final stagedExecutable = await _stageWindowsUpdaterRuntime(session);
    await Process.start(
      stagedExecutable,
      session.toProcessArguments(),
      workingDirectory: path.dirname(stagedExecutable),
      mode: ProcessStartMode.detached,
    );
    return session;
  }

  Future<void> runUpdaterSession(
    AppUpdateSession session, {
    void Function(String message)? onStep,
  }) async {
    _ensureUpdateEnabled();
    if (!Platform.isWindows) {
      throw StateError('更新器会话仅支持 Windows');
    }

    final sessionDir = Directory(
      path.join(session.storageRoot, 'sessions', session.sessionId),
    );
    await sessionDir.create(recursive: true);
    final updaterLog = File(path.join(sessionDir.path, 'updater.log'));
    final installerLog = File(path.join(sessionDir.path, 'installer.log'));

    Future<void> log(String message) async {
      await updaterLog.writeAsString(
        '${DateTime.now().toIso8601String()} | $message\n',
        mode: FileMode.append,
        flush: true,
      );
    }

    Future<void> step(String message) async {
      onStep?.call(message);
      await log(message);
    }

    await step('准备安装 ${session.versionTag}');
    final installer = File(session.installerPath);
    if (!await installer.exists()) {
      throw StateError('安装包不存在：${session.installerPath}');
    }

    await step('等待旧版本退出');
    await _waitForProcessExit(session.oldPid, log: log);

    await step('正在静默安装');
    final exitCode = await _runWindowsInstaller(
      session: session,
      installerLogPath: installerLog.path,
      updaterLog: log,
    );
    if (exitCode != 0) {
      throw StateError('安装器退出码异常：$exitCode');
    }

    await step('验证新版程序');
    await _waitForWindowsInstalledVersion(
      session.launchPath,
      session.versionTag,
      log: log,
    );

    await step('启动新版程序');
    await Process.start(
      session.launchPath,
      const [],
      workingDirectory: session.installRoot,
      mode: ProcessStartMode.detached,
    );
    await log('更新完成');
  }

  static void _ensureUpdateEnabled() {
    if (!AppUpdateConfig.updateEnabled) {
      throw StateError('当前品牌已移除升级功能');
    }
  }

  Future<String> _resolveCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.trim().isNotEmpty) {
        return info.version.trim();
      }
    } catch (_) {
      // 测试环境或平台通道不可用时回退到编译期版本。
    }
    return AppUpdateConfig.currentVersion;
  }

  Future<Map<String, dynamic>> _fetchJson(
    Uri uri, {
    required AppUpdateProxy? proxy,
  }) async {
    final bytes = await _readUri(
      uri,
      proxy: proxy,
      accept: 'application/vnd.github+json',
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GitHub 返回数据格式不正确');
    }
    return decoded;
  }

  Future<List<int>> _readUri(
    Uri uri, {
    required AppUpdateProxy? proxy,
    required String accept,
  }) async {
    if (Platform.isWindows) {
      Object? firstError;
      try {
        return await _readUriWithCurl(uri, proxy: proxy, accept: accept);
      } catch (error) {
        firstError = error;
      }

      if (proxy != null) {
        try {
          return await _readUriWithCurl(
            uri,
            proxy: null,
            accept: accept,
            forceDirect: true,
          );
        } catch (_) {
          // 继续使用 Dart HTTP 兜底。
        }
      }

      try {
        return await _readUriOnce(uri, proxy: proxy, accept: accept);
      } catch (dartError) {
        if (proxy != null) {
          try {
            return await _readUriOnce(uri, proxy: null, accept: accept);
          } catch (_) {
            // 下面抛出首个 curl 错误和 Dart 错误，方便定位。
          }
        }
        throw StateError('GitHub 请求失败：$dartError；curl 兜底错误：$firstError');
      }
    }

    try {
      return await _readUriOnce(uri, proxy: proxy, accept: accept);
    } catch (_) {
      if (proxy == null) {
        rethrow;
      }
      return _readUriOnce(uri, proxy: null, accept: accept);
    }
  }

  Future<List<int>> _readUriOnce(
    Uri uri, {
    required AppUpdateProxy? proxy,
    required String accept,
  }) async {
    final client = _createHttpClient(proxy);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, accept);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          '请求失败：HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      return consolidateHttpClientResponseBytes(response);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _readUriWithCurl(
    Uri uri, {
    required AppUpdateProxy? proxy,
    required String accept,
    bool forceDirect = false,
  }) async {
    final args = <String>[
      '-L',
      '--fail',
      '--silent',
      '--show-error',
      '--connect-timeout',
      '20',
      '--max-time',
      '60',
      '--retry',
      '2',
      '--retry-delay',
      '1',
      '--retry-connrefused',
      '-H',
      'Accept: $accept',
      '-H',
      'User-Agent: $_userAgent',
      if (proxy != null) ...[
        '--proxy',
        proxy.curlProxyUrl,
      ],
      if (forceDirect) ...[
        '--noproxy',
        '*',
      ],
      uri.toString(),
    ];
    final result = await Process.run(
      'curl.exe',
      args,
      stdoutEncoding: null,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 75));
    if (result.exitCode != 0) {
      throw StateError(
        'curl 请求失败 exit=${result.exitCode}: ${result.stderr}',
      );
    }
    final stdout = result.stdout;
    if (stdout is List<int>) {
      return stdout;
    }
    if (stdout is String) {
      return utf8.encode(stdout);
    }
    throw StateError('curl 返回数据格式不正确');
  }

  Future<void> _downloadFile(
    Uri uri,
    File target, {
    required AppUpdateProxy? proxy,
    int expectedSize = 0,
    AppUpdateProgress? onProgress,
  }) async {
    if (Platform.isWindows) {
      Object? firstError;
      try {
        await _downloadFileWithCurl(
          uri,
          target,
          proxy: proxy,
          expectedSize: expectedSize,
          onProgress: onProgress,
        );
        return;
      } catch (error) {
        firstError = error;
        if (await target.exists()) {
          await target.delete();
        }
      }

      if (proxy != null) {
        try {
          await _downloadFileWithCurl(
            uri,
            target,
            proxy: null,
            expectedSize: expectedSize,
            forceDirect: true,
            onProgress: onProgress,
          );
          return;
        } catch (_) {
          if (await target.exists()) {
            await target.delete();
          }
        }
      }

      try {
        await _downloadFileOnce(
          uri,
          target,
          proxy: proxy,
          onProgress: onProgress,
        );
        return;
      } catch (dartError) {
        if (await target.exists()) {
          await target.delete();
        }
        if (proxy != null) {
          try {
            await _downloadFileOnce(
              uri,
              target,
              proxy: null,
              onProgress: onProgress,
            );
            return;
          } catch (_) {
            if (await target.exists()) {
              await target.delete();
            }
          }
        }
        throw StateError('下载失败：$dartError；curl 兜底错误：$firstError');
      }
    }

    try {
      await _downloadFileOnce(
        uri,
        target,
        proxy: proxy,
        onProgress: onProgress,
      );
    } catch (_) {
      if (proxy == null) {
        rethrow;
      }
      if (await target.exists()) {
        await target.delete();
      }
      await _downloadFileOnce(
        uri,
        target,
        proxy: null,
        onProgress: onProgress,
      );
    }
  }

  Future<void> _downloadFileWithCurl(
    Uri uri,
    File target, {
    required AppUpdateProxy? proxy,
    int expectedSize = 0,
    bool forceDirect = false,
    AppUpdateProgress? onProgress,
  }) async {
    await target.parent.create(recursive: true);
    final args = <String>[
      '-L',
      '--fail',
      '--silent',
      '--show-error',
      '--connect-timeout',
      '20',
      '--max-time',
      '1800',
      '--retry',
      '2',
      '--retry-delay',
      '1',
      '--retry-connrefused',
      '-H',
      'Accept: application/octet-stream',
      '-H',
      'User-Agent: $_userAgent',
      if (proxy != null) ...[
        '--proxy',
        proxy.curlProxyUrl,
      ],
      if (forceDirect) ...[
        '--noproxy',
        '*',
      ],
      '--output',
      target.path,
      uri.toString(),
    ];
    final result = await Process.run(
      'curl.exe',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 35));
    if (result.exitCode != 0) {
      throw StateError(
        'curl 下载失败 exit=${result.exitCode}: ${result.stderr}',
      );
    }
    if (expectedSize > 0) {
      onProgress?.call(expectedSize, expectedSize);
    }
  }

  Future<void> _downloadFileOnce(
    Uri uri,
    File target, {
    required AppUpdateProxy? proxy,
    AppUpdateProgress? onProgress,
  }) async {
    final client = _createHttpClient(proxy);
    final sink = target.openWrite();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          '下载失败：HTTP ${response.statusCode}',
          uri: uri,
        );
      }

      final total = response.contentLength < 0 ? 0 : response.contentLength;
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
      client.close(force: true);
    }
  }

  HttpClient _createHttpClient(AppUpdateProxy? proxy) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 20)
      ..autoUncompress = true;
    if (proxy != null) {
      client.findProxy = (_) => '${proxy.config}; DIRECT';
    }
    return client;
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isWindows) {
      return Directory(
        path.join(RuntimeStoragePaths.resolveRuntimeRootPathSync(), 'updates',
            'windows'),
      );
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return getTemporaryDirectory();
    }
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return Directory(path.join(downloads.path, 'VNTC APP Updates'));
    }
    final temp = await getTemporaryDirectory();
    return Directory(path.join(temp.path, 'vnt_app_updates'));
  }

  Future<AppUpdateAsset> _withResolvedSha256(
    AppUpdateAsset asset, {
    required AppUpdateProxy? proxy,
  }) async {
    if (asset.sha256 != null) {
      return asset;
    }
    final checksumUrl = asset.checksumUrl;
    if (checksumUrl == null) {
      throw StateError('缺少 SHA-256 校验信息，已拒绝自动下载：${asset.name}');
    }
    final bytes = await _readUri(
      checksumUrl,
      proxy: proxy,
      accept: 'text/plain',
    );
    final checksumText = utf8.decode(bytes, allowMalformed: true);
    final sha256 = parseSha256ChecksumText(
      checksumText,
      expectedFileName: asset.name,
    );
    if (sha256 == null) {
      throw StateError('SHA-256 校验文件格式不匹配：${asset.name}');
    }
    return asset.copyWith(sha256: sha256);
  }

  Future<bool> _isCompleteDownload(File file, AppUpdateAsset asset) async {
    if (!await file.exists()) {
      return false;
    }
    final length = await file.length();
    if (length <= 0) {
      return false;
    }
    if (asset.size > 0 && length != asset.size) {
      return false;
    }
    final expectedSha256 = asset.sha256;
    if (expectedSha256 == null) {
      return false;
    }
    return await _sha256ForFile(file) == expectedSha256;
  }

  Future<void> _verifyDownloadedFile(File file, AppUpdateAsset asset) async {
    if (!await file.exists()) {
      throw StateError('下载文件不存在：${file.path}');
    }
    final length = await file.length();
    if (length <= 0) {
      throw StateError('下载文件为空：${asset.name}');
    }
    if (asset.size > 0 && length != asset.size) {
      throw StateError(
        '下载文件大小不一致：${asset.name}，期望 ${asset.size} 字节，实际 $length 字节',
      );
    }
    final expectedSha256 = asset.sha256;
    if (expectedSha256 == null) {
      throw StateError('缺少 SHA-256 校验信息：${asset.name}');
    }
    final actualSha256 = await _sha256ForFile(file);
    if (actualSha256 != expectedSha256) {
      throw StateError(
        '下载文件 SHA-256 不一致：${asset.name}，期望 $expectedSha256，实际 $actualSha256',
      );
    }
  }

  Future<String> _sha256ForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  void _ensureSupportedWindowsSilentInstaller(
    AppUpdateDownloadResult result,
  ) {
    final assetName = result.asset.name.toLowerCase();
    final fileExtension = path.extension(result.filePath).toLowerCase();
    if (fileExtension != '.exe' ||
        !isWindowsSilentInstallerAssetName(assetName)) {
      throw StateError(
          'Windows 静默更新仅支持 Inno Setup .exe 安装包：${result.asset.name}');
    }
  }

  Future<void> _verifyWindowsInstallerAuthenticode(
    File installer, {
    required bool sha256Verified,
  }) async {
    final command = '''
\$ErrorActionPreference = 'Stop'
\$securityModule = Join-Path \$env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\Modules\\Microsoft.PowerShell.Security\\Microsoft.PowerShell.Security.psd1'
Import-Module -Name \$securityModule -Force -ErrorAction Stop
\$signature = Get-AuthenticodeSignature -LiteralPath ${_psString(installer.path)}
\$subject = if (\$signature.SignerCertificate) { \$signature.SignerCertificate.Subject } else { '' }
[ordered]@{
  Status = [string]\$signature.Status
  Subject = [string]\$subject
} | ConvertTo-Json -Compress
''';
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        command,
      ],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    ).timeout(const Duration(seconds: 10));
    if (result.exitCode != 0) {
      throw StateError('安装包签名校验失败：${result.stderr}');
    }
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map) {
      throw StateError('安装包签名校验返回格式不正确');
    }
    final status = (decoded['Status'] ?? '').toString();
    final subject = (decoded['Subject'] ?? '').toString();
    if (!isAcceptedWindowsInstallerTrust(
      status: status,
      subject: subject,
      trustedPublisher: AppUpdateConfig.windowsTrustedPublisherName,
      sha256Verified: sha256Verified,
    )) {
      const publisherHint = AppUpdateConfig.windowsTrustedPublisherName;
      throw StateError(
        publisherHint.trim().isEmpty
            ? '安装包 Authenticode 签名无效：$status'
            : '安装包发布者不受信任：status=$status subject=$subject',
      );
    }
  }

  Future<String> _resolveWindowsLaunchPath(String appDir) async {
    final configured =
        File(path.join(appDir, AppUpdateConfig.windowsExecutableName));
    if (await configured.exists()) {
      return configured.path;
    }
    final current = File(Platform.resolvedExecutable);
    if (await current.exists()) {
      return current.path;
    }
    throw StateError('无法找到新版启动程序：$appDir');
  }

  Future<String> _stageWindowsUpdaterRuntime(AppUpdateSession session) async {
    final stagingDir = Directory(
      path.join(session.storageRoot, 'staging', '${session.sessionId}_runtime'),
    );
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    final sourceDir = Directory(session.installRoot);
    if (!await sourceDir.exists()) {
      throw StateError('安装目录不存在：${session.installRoot}');
    }

    await _copyWindowsRuntime(sourceDir, stagingDir);
    final stagedExecutable = File(
      path.join(stagingDir.path, path.basename(Platform.resolvedExecutable)),
    );
    if (!await stagedExecutable.exists()) {
      throw StateError('临时更新器缺少可执行文件：${stagedExecutable.path}');
    }
    return stagedExecutable.path;
  }

  Future<void> _copyWindowsRuntime(Directory source, Directory target) async {
    const ignoredDirectoryNames = {
      'config',
      'logs',
      'updates',
    };

    await for (final entity in source.list(followLinks: false)) {
      final name = path.basename(entity.path);
      final destination = path.join(target.path, name);
      if (entity is File) {
        await entity.copy(destination);
        continue;
      }
      if (entity is Directory) {
        if (ignoredDirectoryNames.contains(name.toLowerCase())) {
          continue;
        }
        await _copyDirectory(entity, Directory(destination));
      }
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final destination = path.join(target.path, path.basename(entity.path));
      if (entity is File) {
        await entity.copy(destination);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(destination));
      }
    }
  }

  Future<void> _waitForProcessExit(
    int processId, {
    required Future<void> Function(String message) log,
  }) async {
    if (processId <= 0 || processId == pid) {
      return;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (!await _isProcessRunning(processId)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await log('等待旧进程退出超时，继续交给安装器关闭进程：$processId');
  }

  Future<bool> _isProcessRunning(int processId) async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        'if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { exit 0 } exit 1',
      ],
    );
    return result.exitCode == 0;
  }

  Future<int> _runWindowsInstaller({
    required AppUpdateSession session,
    required String installerLogPath,
    required Future<void> Function(String message) updaterLog,
  }) async {
    final scriptFile = File(
      path.join(
          session.storageRoot, 'sessions', session.sessionId, 'install.ps1'),
    );
    final script = '''
\$ErrorActionPreference = 'Stop'
\$installer = ${_psString(session.installerPath)}
\$arguments = @(
  '/SP-',
  '/VERYSILENT',
  '/SUPPRESSMSGBOXES',
  '/NORESTART',
  '/NOCANCEL',
  '/CLOSEAPPLICATIONS',
  '/FORCECLOSEAPPLICATIONS',
  '/DIR="${_psArgumentValue(session.installRoot)}"',
  '/LOG="${_psArgumentValue(installerLogPath)}"'
)
\$process = Start-Process -FilePath \$installer -ArgumentList \$arguments -Verb RunAs -Wait -PassThru
exit \$process.ExitCode
''';
    await _writeUtf8Bom(scriptFile, script);
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ],
    ).timeout(const Duration(minutes: 30));
    await updaterLog('installer stdout: ${result.stdout}');
    await updaterLog('installer stderr: ${result.stderr}');
    return result.exitCode;
  }

  Future<void> _waitForWindowsInstalledVersion(
    String filePath,
    String expectedVersionTag, {
    required Future<void> Function(String message) log,
  }) async {
    final expectedVersion = normalizeVersionString(expectedVersionTag);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    final file = File(filePath);
    var lastVersion = '';
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        final actualVersion = await _readWindowsFileVersion(filePath);
        lastVersion = actualVersion ?? '';
        if (actualVersion != null &&
            compareVersionStrings(actualVersion, expectedVersion) == 0) {
          await log('installed version verified: $actualVersion');
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError(
      '安装后版本不匹配：期望 v$expectedVersion，实际 ${lastVersion.isEmpty ? '未知' : lastVersion}，路径：$filePath',
    );
  }

  Future<String?> _readWindowsFileVersion(String filePath) async {
    try {
      final command = '''
\$info = (Get-Item -LiteralPath ${_psString(filePath)}).VersionInfo
if (\$info.ProductVersion) {
  \$info.ProductVersion
} elseif (\$info.FileVersion) {
  \$info.FileVersion
}
''';
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          command,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) {
        return null;
      }
      final version = result.stdout.toString().trim();
      return version.isEmpty ? null : version;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeUtf8Bom(File file, String content) async {
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      [0xEF, 0xBB, 0xBF, ...utf8.encode(content)],
      flush: true,
    );
  }

  static String _psString(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  static String _psArgumentValue(String value) {
    return value.replaceAll('"', r'\"');
  }

  static const _userAgent = AppUpdateConfig.userAgent;
}

class AndroidUpdateInstaller {
  static const MethodChannel _channel =
      MethodChannel('top.wherewego.vnt/update');

  static Future<void> installApk(String filePath) async {
    await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
  }
}

class AppUpdateProxyResolver {
  static const proxyHost = String.fromEnvironment(
    'APP_UPDATE_PROXY_HOST',
    defaultValue: '',
  );
  static const proxyPort = int.fromEnvironment(
    'APP_UPDATE_PROXY_PORT',
    defaultValue: 7890,
  );

  static Future<AppUpdateProxy?> resolve() async {
    final envProxy = _fromEnvironment();
    if (envProxy != null) {
      return envProxy;
    }

    if (!kIsWeb) {
      final systemProxy = await _fromSystemProxy();
      if (systemProxy != null) {
        return systemProxy;
      }
    }

    return _fromReachableLocalProxy();
  }

  static AppUpdateProxy? parseProxyValue(String value, String source) {
    final trimmed = value.trim().replaceAll('"', '');
    if (trimmed.isEmpty || trimmed.toUpperCase() == 'DIRECT') {
      return null;
    }

    if (trimmed.contains('=') && trimmed.contains(';')) {
      final selected = _selectProxyServerValue(trimmed);
      if (selected != null) {
        return parseProxyValue(selected, source);
      }
    }

    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty || uri.port == 0) {
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    final command = scheme.startsWith('socks') ? 'SOCKS' : 'PROXY';
    return AppUpdateProxy(
      config: '$command ${uri.host}:${uri.port}',
      label: '$source ${uri.host}:${uri.port}',
    );
  }

  static AppUpdateProxy? _fromEnvironment() {
    for (final key in const [
      'HTTPS_PROXY',
      'https_proxy',
      'ALL_PROXY',
      'all_proxy',
      'HTTP_PROXY',
      'http_proxy',
    ]) {
      final value = Platform.environment[key];
      if (value == null) {
        continue;
      }
      final proxy = parseProxyValue(value, '环境代理');
      if (proxy != null) {
        return proxy;
      }
    }
    return null;
  }

  static Future<AppUpdateProxy?> _fromSystemProxy() async {
    if (Platform.isMacOS) {
      return _fromMacOSProxy();
    }
    if (Platform.isWindows) {
      return _fromWindowsProxy();
    }
    if (Platform.isLinux) {
      return _fromLinuxProxy();
    }
    return null;
  }

  static Future<AppUpdateProxy?> _fromMacOSProxy() async {
    final result = await _runProcess('scutil', ['--proxy']);
    if (result == null || result.exitCode != 0) {
      return null;
    }
    final output = result.stdout.toString();
    final httpsEnabled = _macProxyValue(output, 'HTTPSEnable') == '1';
    final httpEnabled = _macProxyValue(output, 'HTTPEnable') == '1';
    if (httpsEnabled) {
      final host = _macProxyValue(output, 'HTTPSProxy');
      final port = _macProxyValue(output, 'HTTPSPort');
      final proxy = parseProxyValue('$host:$port', 'macOS 系统代理');
      if (proxy != null) {
        return proxy;
      }
    }
    if (httpEnabled) {
      final host = _macProxyValue(output, 'HTTPProxy');
      final port = _macProxyValue(output, 'HTTPPort');
      return parseProxyValue('$host:$port', 'macOS 系统代理');
    }
    return null;
  }

  static Future<AppUpdateProxy?> _fromWindowsProxy() async {
    final result = await _runProcess('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ]);
    if (result == null || result.exitCode != 0) {
      return null;
    }
    final output = result.stdout.toString();
    final enabled = RegExp(
      r'ProxyEnable\s+REG_DWORD\s+0x1',
      caseSensitive: false,
    ).hasMatch(output);
    if (!enabled) {
      return null;
    }
    final match = RegExp(
      r'ProxyServer\s+REG_SZ\s+(.+)',
      caseSensitive: false,
    ).firstMatch(output);
    if (match == null) {
      return null;
    }
    return parseProxyValue(match.group(1) ?? '', 'Windows 系统代理');
  }

  static Future<AppUpdateProxy?> _fromLinuxProxy() async {
    final mode = await _runProcess('gsettings', [
      'get',
      'org.gnome.system.proxy',
      'mode',
    ]);
    if (mode == null ||
        mode.exitCode != 0 ||
        !mode.stdout.toString().contains('manual')) {
      return null;
    }
    final httpsHost = await _linuxGSettingsValue(
      'org.gnome.system.proxy.https',
      'host',
    );
    final httpsPort = await _linuxGSettingsValue(
      'org.gnome.system.proxy.https',
      'port',
    );
    final httpsProxy = parseProxyValue('$httpsHost:$httpsPort', 'Linux 系统代理');
    if (httpsProxy != null) {
      return httpsProxy;
    }
    final httpHost = await _linuxGSettingsValue(
      'org.gnome.system.proxy.http',
      'host',
    );
    final httpPort = await _linuxGSettingsValue(
      'org.gnome.system.proxy.http',
      'port',
    );
    return parseProxyValue('$httpHost:$httpPort', 'Linux 系统代理');
  }

  static Future<AppUpdateProxy?> _fromReachableLocalProxy() async {
    final hosts = <String>[
      if (proxyHost.trim().isNotEmpty) proxyHost.trim(),
      '127.0.0.1',
      'localhost',
      if (Platform.isAndroid) '10.0.2.2',
    ];
    for (final host in hosts) {
      if (await _canConnect(host, proxyPort)) {
        return AppUpdateProxy(
          config: 'PROXY $host:$proxyPort',
          label: '本机代理 $host:$proxyPort',
        );
      }
    }
    return null;
  }

  static Future<ProcessResult?> _runProcess(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(executable, arguments)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  static String? _selectProxyServerValue(String value) {
    final parts = value.split(';').map((item) => item.trim());
    for (final key in const ['https=', 'http=', 'socks=']) {
      for (final part in parts) {
        if (part.toLowerCase().startsWith(key)) {
          final selected = part.substring(key.length);
          if (selected.isNotEmpty) {
            return selected;
          }
        }
      }
    }
    return null;
  }

  static String _macProxyValue(String output, String key) {
    final match = RegExp('$key\\s*:\\s*(.+)').firstMatch(output);
    return match?.group(1)?.trim() ?? '';
  }

  static Future<String> _linuxGSettingsValue(String schema, String key) async {
    final result = await _runProcess('gsettings', ['get', schema, key]);
    if (result == null || result.exitCode != 0) {
      return '';
    }
    return result.stdout.toString().trim().replaceAll("'", '');
  }

  static Future<bool> _canConnect(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 350),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}

AppUpdatePlatform resolveCurrentUpdatePlatform() {
  if (kIsWeb) {
    return AppUpdatePlatform.unsupported;
  }
  if (Platform.isAndroid) {
    return AppUpdatePlatform.android;
  }
  if (Platform.isWindows) {
    return AppUpdatePlatform.windows;
  }
  if (Platform.isMacOS) {
    return AppUpdatePlatform.macos;
  }
  if (Platform.isLinux) {
    return AppUpdatePlatform.linux;
  }
  if (Platform.isIOS) {
    return AppUpdatePlatform.ios;
  }
  return AppUpdatePlatform.unsupported;
}

bool supportsStartupUpdateCheck(AppUpdatePlatform platform) {
  return platform == AppUpdatePlatform.windows ||
      platform == AppUpdatePlatform.android;
}

AppUpdateInfo parseGitHubRelease(
  Map<String, dynamic> release, {
  required String currentVersion,
  required AppUpdatePlatform platform,
  String? proxyLabel,
}) {
  final tagName = (release['tag_name'] ?? '').toString();
  if (tagName.isEmpty) {
    throw const FormatException('GitHub Release 缺少 tag_name');
  }
  final latestVersion = normalizeVersionString(tagName);
  final pageUrl = Uri.tryParse((release['html_url'] ?? '').toString()) ??
      Uri.parse(AppUpdateService.releasePageUrl);
  final rawAssets = release['assets'];
  final parsedAssets = rawAssets is List
      ? rawAssets
          .whereType<Map<String, dynamic>>()
          .map(AppUpdateAsset.fromGitHubJson)
          .whereType<AppUpdateAsset>()
          .toList()
      : <AppUpdateAsset>[];
  final assets = attachChecksumAssets(parsedAssets);

  return AppUpdateInfo(
    currentVersion: normalizeVersionString(currentVersion),
    latestVersion: latestVersion,
    tagName: tagName,
    releaseName: (release['name'] ?? tagName).toString(),
    releaseNotes: (release['body'] ?? '').toString(),
    releasePageUrl: pageUrl,
    hasUpdate: compareVersionStrings(latestVersion, currentVersion) > 0,
    platform: platform,
    asset: selectBestUpdateAsset(
      assets,
      platform,
      version: latestVersion,
    ),
    proxyLabel: proxyLabel,
  );
}

AppUpdateAsset? selectBestUpdateAsset(
  List<AppUpdateAsset> assets,
  AppUpdatePlatform platform, {
  String? version,
}) {
  if (platform == AppUpdatePlatform.ios) {
    return null;
  }

  final installableAssets = assets
      .where((asset) => !isChecksumAssetName(asset.name))
      .toList(growable: false);

  if (platform == AppUpdatePlatform.windows && version != null) {
    final normalizedVersion = normalizeVersionString(version);
    final exactNames = [
      '${AppUpdateConfig.windowsInstallerBaseName}_${normalizedVersion}_Windows_Setup.exe',
      '${AppUpdateConfig.windowsInstallerBaseName}_v${normalizedVersion}_Windows_Setup.exe',
    ].map((name) => name.toLowerCase()).toSet();
    for (final asset in installableAssets) {
      if (exactNames.contains(asset.name.toLowerCase())) {
        return asset;
      }
    }
  }

  final patterns = switch (platform) {
    AppUpdatePlatform.android => ['.apk'],
    AppUpdatePlatform.windows => ['_windows_setup.exe', 'setup.exe'],
    AppUpdatePlatform.macos => ['.dmg'],
    AppUpdatePlatform.linux => ['.appimage', '.deb', '.tar.gz'],
    AppUpdatePlatform.ios => const <String>[],
    AppUpdatePlatform.unsupported => const <String>[],
  };

  for (final pattern in patterns) {
    for (final asset in installableAssets) {
      final assetName = asset.name.toLowerCase();
      if (platform == AppUpdatePlatform.windows &&
          !isWindowsSilentInstallerAssetName(assetName)) {
        continue;
      }
      if (assetName.contains(pattern)) {
        return asset;
      }
    }
  }
  return null;
}

List<AppUpdateAsset> attachChecksumAssets(List<AppUpdateAsset> assets) {
  final checksumAssets = assets
      .where((asset) => isChecksumAssetName(asset.name))
      .toList(growable: false);
  if (checksumAssets.isEmpty) {
    return assets;
  }

  return assets.map((asset) {
    if (isChecksumAssetName(asset.name) || asset.sha256 != null) {
      return asset;
    }
    final checksumAsset = _findChecksumAssetFor(asset, checksumAssets);
    if (checksumAsset == null) {
      return asset;
    }
    return asset.copyWith(checksumUrl: checksumAsset.downloadUrl);
  }).toList(growable: false);
}

AppUpdateAsset? _findChecksumAssetFor(
  AppUpdateAsset asset,
  List<AppUpdateAsset> checksumAssets,
) {
  final assetName = asset.name.toLowerCase();
  final withoutExtension = _fileNameWithoutLastExtension(assetName);
  final expectedNames = <String>{
    '$assetName.sha256',
    '$assetName.sha256.txt',
    '$withoutExtension.sha256',
    '$withoutExtension.sha256.txt',
    '$withoutExtension.sha256sum',
  };
  for (final checksumAsset in checksumAssets) {
    final checksumName = checksumAsset.name.toLowerCase();
    if (expectedNames.contains(checksumName)) {
      return checksumAsset;
    }
  }

  final version = _versionTokenFromFileName(assetName);
  if (version == null) {
    return null;
  }
  final platformToken = _platformTokenFromFileName(assetName);
  final candidates = checksumAssets.where((checksumAsset) {
    final checksumName = checksumAsset.name.toLowerCase();
    return checksumName.contains(version) &&
        checksumName.contains('sha256') &&
        (platformToken == null || checksumName.contains(platformToken));
  }).toList(growable: false);
  return candidates.length == 1 ? candidates.single : null;
}

String _fileNameWithoutLastExtension(String fileName) {
  final extension = path.extension(fileName);
  if (extension.isEmpty) {
    return fileName;
  }
  return fileName.substring(0, fileName.length - extension.length);
}

String? _versionTokenFromFileName(String fileName) {
  final match = RegExp(r'v?\d+(?:\.\d+)+(?:-[a-z0-9.-]+)?')
      .firstMatch(fileName.toLowerCase());
  return match?.group(0)?.replaceFirst(RegExp(r'^v'), '');
}

String? _platformTokenFromFileName(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.contains('windows')) {
    return 'windows';
  }
  if (lower.contains('android')) {
    return 'android';
  }
  if (lower.contains('macos') || lower.contains('darwin')) {
    return 'mac';
  }
  if (lower.contains('linux')) {
    return 'linux';
  }
  return null;
}

bool isChecksumAssetName(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.sha256') ||
      lower.endsWith('.sha256.txt') ||
      lower.endsWith('.sha256sum') ||
      lower.endsWith('_sha256.txt') ||
      lower.endsWith('-sha256.txt') ||
      lower.contains('sha256sum');
}

bool isWindowsSilentInstallerAssetName(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.exe') &&
      (lower.endsWith('_windows_setup.exe') ||
          lower.endsWith('-windows-setup.exe') ||
          lower.endsWith('setup.exe'));
}

String? normalizeSha256Value(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(r'[a-fA-F0-9]{64}').firstMatch(value);
  return match?.group(0)?.toLowerCase();
}

String? parseSha256ChecksumText(
  String text, {
  required String expectedFileName,
}) {
  final expectedBaseName = path.basename(expectedFileName).toLowerCase();
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(r'[a-fA-F0-9]{64}').firstMatch(line);
    if (match == null) {
      continue;
    }
    final hash = match.group(0)!.toLowerCase();
    final remainder = line.substring(match.end).trim();
    if (remainder.isEmpty) {
      return hash;
    }
    final declaredName = remainder.replaceFirst(RegExp(r'^[ *]+'), '').trim();
    if (declaredName.isEmpty ||
        path.basename(declaredName).toLowerCase() == expectedBaseName) {
      return hash;
    }
  }
  return null;
}

bool isTrustedWindowsSignature({
  required String status,
  required String subject,
  required String trustedPublisher,
}) {
  if (status.trim().toLowerCase() != 'valid') {
    return false;
  }
  final publisher = trustedPublisher.trim();
  if (publisher.isEmpty) {
    return true;
  }
  return subject.toLowerCase().contains(publisher.toLowerCase());
}

bool isAcceptedWindowsInstallerTrust({
  required String status,
  required String subject,
  required String trustedPublisher,
  required bool sha256Verified,
}) {
  if (isTrustedWindowsSignature(
    status: status,
    subject: subject,
    trustedPublisher: trustedPublisher,
  )) {
    return true;
  }
  return trustedPublisher.trim().isEmpty &&
      status.trim().toLowerCase() == 'notsigned' &&
      sha256Verified;
}

int compareVersionStrings(String left, String right) {
  final leftVersion = normalizeVersionString(left);
  final rightVersion = normalizeVersionString(right);
  final leftParts = _semanticVersionParts(leftVersion);
  final rightParts = _semanticVersionParts(rightVersion);
  final maxLength = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;

  for (var index = 0; index < maxLength; index++) {
    final leftPart = index < leftParts.length ? leftParts[index] : 0;
    final rightPart = index < rightParts.length ? rightParts[index] : 0;
    if (leftPart != rightPart) {
      return leftPart.compareTo(rightPart);
    }
  }

  final leftPrerelease = _prereleasePart(leftVersion);
  final rightPrerelease = _prereleasePart(rightVersion);
  if (leftPrerelease == null && rightPrerelease == null) {
    return 0;
  }
  if (leftPrerelease == null) {
    return 1;
  }
  if (rightPrerelease == null) {
    return -1;
  }
  return _comparePrerelease(leftPrerelease, rightPrerelease);
}

String normalizeVersionString(String version) {
  var normalized = version.trim();
  if (normalized.startsWith('refs/tags/')) {
    normalized = normalized.substring('refs/tags/'.length);
  }
  if (normalized.startsWith('v') || normalized.startsWith('V')) {
    normalized = normalized.substring(1);
  }
  final plusIndex = normalized.indexOf('+');
  if (plusIndex >= 0) {
    normalized = normalized.substring(0, plusIndex);
  }
  return normalized.isEmpty ? '0.0.0' : normalized;
}

List<int> _semanticVersionParts(String version) {
  final firstSection = version.split('-').first;
  return RegExp(r'\d+')
      .allMatches(firstSection)
      .map((match) => int.tryParse(match.group(0) ?? '') ?? 0)
      .toList();
}

String? _prereleasePart(String version) {
  final index = version.indexOf('-');
  if (index < 0 || index == version.length - 1) {
    return null;
  }
  return version.substring(index + 1);
}

int _comparePrerelease(String left, String right) {
  final leftParts = left.split('.');
  final rightParts = right.split('.');
  final maxLength = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < maxLength; index++) {
    if (index >= leftParts.length) {
      return -1;
    }
    if (index >= rightParts.length) {
      return 1;
    }
    final comparison = _comparePrereleaseIdentifier(
      leftParts[index],
      rightParts[index],
    );
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

int _comparePrereleaseIdentifier(String left, String right) {
  final leftNumeric = RegExp(r'^\d+$').hasMatch(left);
  final rightNumeric = RegExp(r'^\d+$').hasMatch(right);
  if (leftNumeric && rightNumeric) {
    return int.parse(left).compareTo(int.parse(right));
  }
  if (leftNumeric != rightNumeric) {
    return leftNumeric ? -1 : 1;
  }
  return left.compareTo(right);
}

String _safeFileName(String fileName) {
  return fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}

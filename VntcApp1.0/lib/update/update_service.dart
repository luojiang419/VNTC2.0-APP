import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vnt_app/app_version.dart';

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
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? contentType;
  final String? sha256;

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
      sha256: json['sha256']?.toString(),
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
    this.proxyLabel,
  });

  final String filePath;
  final AppUpdateAsset asset;
  final String? proxyLabel;
}

class AppUpdateProxy {
  const AppUpdateProxy({
    required this.config,
    required this.label,
  });

  final String config;
  final String label;
}

typedef AppUpdateProgress = void Function(int received, int total);

class AppUpdateService {
  AppUpdateService({
    Future<AppUpdateProxy?> Function()? proxyResolver,
  }) : _proxyResolver = proxyResolver ?? AppUpdateProxyResolver.resolve;

  static const latestReleaseApiUrl = String.fromEnvironment(
    'APP_UPDATE_API_URL',
    defaultValue:
        'https://api.github.com/repos/luojiang419/VNTC2.0-APP/releases/latest',
  );
  static const releasePageUrl = String.fromEnvironment(
    'APP_UPDATE_RELEASE_PAGE_URL',
    defaultValue: 'https://github.com/luojiang419/VNTC2.0-APP/releases/latest',
  );

  final Future<AppUpdateProxy?> Function() _proxyResolver;

  Future<AppUpdateInfo> checkLatest({
    String? currentVersion,
    AppUpdatePlatform? platform,
  }) async {
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
    final asset = info.asset;
    if (asset == null) {
      throw StateError('当前平台没有可下载的安装包');
    }
    if (info.platform == AppUpdatePlatform.ios) {
      throw StateError('iOS 版本需要通过 TestFlight、App Store 或企业分发更新');
    }

    final directory = await _resolveDownloadDirectory();
    await directory.create(recursive: true);
    final filePath = path.join(directory.path, _safeFileName(asset.name));
    final target = File(filePath);
    if (await target.exists()) {
      await target.delete();
    }

    final proxy = await _proxyResolver();
    await _downloadFile(
      asset.downloadUrl,
      target,
      proxy: proxy,
      onProgress: onProgress,
    );

    if (Platform.isLinux && asset.name.toLowerCase().endsWith('.appimage')) {
      await Process.run('chmod', ['+x', target.path], runInShell: true);
    }

    return AppUpdateDownloadResult(
      filePath: target.path,
      asset: asset,
      proxyLabel: proxy?.label,
    );
  }

  Future<void> openDownloadedInstaller(AppUpdateDownloadResult result) async {
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
    final uri = info?.releasePageUrl ?? Uri.parse(releasePageUrl);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw StateError('无法打开发布页面：$uri');
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
    return AppVersion.currentVersion;
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

  Future<void> _downloadFile(
    Uri uri,
    File target, {
    required AppUpdateProxy? proxy,
    AppUpdateProgress? onProgress,
  }) async {
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

  static const _userAgent = 'VNTC-APP-Updater/2.0';
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
  final assets = rawAssets is List
      ? rawAssets
          .whereType<Map<String, dynamic>>()
          .map(AppUpdateAsset.fromGitHubJson)
          .whereType<AppUpdateAsset>()
          .toList()
      : <AppUpdateAsset>[];

  return AppUpdateInfo(
    currentVersion: normalizeVersionString(currentVersion),
    latestVersion: latestVersion,
    tagName: tagName,
    releaseName: (release['name'] ?? tagName).toString(),
    releaseNotes: (release['body'] ?? '').toString(),
    releasePageUrl: pageUrl,
    hasUpdate: compareVersionStrings(latestVersion, currentVersion) > 0,
    platform: platform,
    asset: selectBestUpdateAsset(assets, platform),
    proxyLabel: proxyLabel,
  );
}

AppUpdateAsset? selectBestUpdateAsset(
  List<AppUpdateAsset> assets,
  AppUpdatePlatform platform,
) {
  if (platform == AppUpdatePlatform.ios) {
    return null;
  }

  final patterns = switch (platform) {
    AppUpdatePlatform.android => ['.apk'],
    AppUpdatePlatform.windows => ['setup.exe', '.msi', '.exe', '.zip'],
    AppUpdatePlatform.macos => ['.dmg'],
    AppUpdatePlatform.linux => ['.appimage', '.deb', '.tar.gz'],
    AppUpdatePlatform.ios => const <String>[],
    AppUpdatePlatform.unsupported => const <String>[],
  };

  for (final pattern in patterns) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().contains(pattern)) {
        return asset;
      }
    }
  }
  return null;
}

int compareVersionStrings(String left, String right) {
  final leftVersion = normalizeVersionString(left);
  final rightVersion = normalizeVersionString(right);
  final leftParts = _numericVersionParts(leftVersion);
  final rightParts = _numericVersionParts(rightVersion);
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

  final leftPrerelease = leftVersion.contains('-');
  final rightPrerelease = rightVersion.contains('-');
  if (leftPrerelease == rightPrerelease) {
    return 0;
  }
  return leftPrerelease ? -1 : 1;
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

List<int> _numericVersionParts(String version) {
  final firstSection = version.split('-').first;
  return RegExp(r'\d+')
      .allMatches(firstSection)
      .map((match) => int.tryParse(match.group(0) ?? '') ?? 0)
      .toList();
}

String _safeFileName(String fileName) {
  return fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}

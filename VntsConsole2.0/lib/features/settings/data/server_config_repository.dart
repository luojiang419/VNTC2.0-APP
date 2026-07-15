import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/server_config_settings.dart';

class WireGuardDefaults {
  const WireGuardDefaults._();

  static const masterKeyFile = 'wireguard-master.key';
  static const bind = '0.0.0.0:41195';
  static const port = 41195;

  static Future<String> publicEndpoint() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final bytes = address.rawAddress;
          final isBenchmarkRange =
              bytes.length == 4 &&
              bytes[0] == 198 &&
              (bytes[1] == 18 || bytes[1] == 19);
          if (!address.isLoopback &&
              !address.isLinkLocal &&
              !isBenchmarkRange) {
            return '${address.address}:$port';
          }
        }
      }
    } on SocketException {
      // 无可用网卡时继续使用主机名或回环地址。
    }
    final hostname = Platform.localHostname.trim();
    if (RegExp(
      r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$',
    ).hasMatch(hostname)) {
      return '$hostname:$port';
    }
    return '127.0.0.1:$port';
  }

  static Future<void> ensureMasterKey(
    File configFile,
    ServerConfigSettings settings,
  ) async {
    if (!settings.wireGuardEnabled ||
        settings.wireGuardMasterKeyFile.trim().toLowerCase() != masterKeyFile) {
      return;
    }
    final keyFile = File(
      '${configFile.parent.path}${Platform.pathSeparator}$masterKeyFile',
    );
    if (await keyFile.exists()) {
      if (await keyFile.length() != 32) {
        throw ConfigValidationException(
          'WireGuard 主密钥文件必须是 32 字节：${keyFile.path}',
        );
      }
      return;
    }
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    try {
      await keyFile.create(exclusive: true);
      await keyFile.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      if (!await keyFile.exists() || await keyFile.length() != 32) rethrow;
    }
  }
}

class LoadedServerConfig {
  const LoadedServerConfig._(this.settings, this._document);

  final ServerConfigSettings settings;
  final _ConfigDocument _document;
}

class ConfigSaveResult {
  const ConfigSaveResult({required this.backupPath});

  final String backupPath;
}

class ServerConfigRepository {
  const ServerConfigRepository(this.configFile);

  static const _orderedKeys = [
    'tcp_bind',
    'quic_bind',
    'ws_bind',
    'network',
    'white_list',
    'lease_duration',
    'persistence',
    'web_bind',
    'username',
    'password',
    'cert',
    'key',
    'wireguard_master_key_file',
    'wireguard_bind',
    'wireguard_public_endpoint',
    'wireguard_max_active_peers',
    'server_quic_bind',
    'peer_servers',
    'server_token',
  ];

  final File configFile;

  Future<LoadedServerConfig> load() async {
    if (!await configFile.exists()) {
      throw const FileSystemException('配置文件不存在');
    }
    final text = await configFile.readAsString();
    final document = _ConfigDocument.parse(text);
    final values = document.rootValues;
    final webBind = _string(values['web_bind']);
    final username = _string(values['username']);
    final wireGuardKey = _string(values['wireguard_master_key_file']);
    final wireGuardBind = _string(values['wireguard_bind']);
    final wireGuardEndpoint = _string(values['wireguard_public_endpoint']);
    final defaultWireGuardEndpoint = wireGuardEndpoint.isEmpty
        ? await WireGuardDefaults.publicEndpoint()
        : wireGuardEndpoint;
    final serverQuicBind = _string(values['server_quic_bind']);
    final peerServers = _stringList(values['peer_servers']);
    final settings = ServerConfigSettings(
      tcpBind: _string(values['tcp_bind']),
      quicBind: _string(values['quic_bind']),
      webSocketBind: _string(values['ws_bind']),
      network: _string(values['network'], fallback: '10.26.0.0/24'),
      whiteList: _stringList(values['white_list']),
      leaseDurationSeconds: _integer(values['lease_duration'], 86400),
      persistence: _boolean(values['persistence'], true),
      webEnabled:
          webBind.isNotEmpty ||
          username.isNotEmpty ||
          values.containsKey('password'),
      webBind: webBind.isEmpty ? '127.0.0.1:39871' : webBind,
      username: username.isEmpty ? 'admin' : username,
      hasPassword: _string(values['password']).isNotEmpty,
      certificateFile: _string(values['cert']),
      privateKeyFile: _string(values['key']),
      wireGuardEnabled:
          wireGuardKey.isNotEmpty ||
          wireGuardBind.isNotEmpty ||
          wireGuardEndpoint.isNotEmpty,
      wireGuardMasterKeyFile: wireGuardKey.isEmpty
          ? WireGuardDefaults.masterKeyFile
          : wireGuardKey,
      wireGuardBind: wireGuardBind.isEmpty
          ? WireGuardDefaults.bind
          : wireGuardBind,
      wireGuardPublicEndpoint: defaultWireGuardEndpoint,
      wireGuardMaxActivePeers: _integer(
        values['wireguard_max_active_peers'],
        4096,
      ),
      serverQuicEnabled:
          serverQuicBind.isNotEmpty ||
          peerServers.isNotEmpty ||
          values.containsKey('server_token'),
      serverQuicBind: serverQuicBind,
      peerServerCount: peerServers.length,
      hasServerToken: _string(values['server_token']).isNotEmpty,
    );
    return LoadedServerConfig._(settings, document);
  }

  Future<ConfigSaveResult> save(
    LoadedServerConfig loaded,
    ServerConfigSettings settings, {
    String newPassword = '',
    String newServerToken = '',
  }) async {
    _validate(
      settings,
      newPassword: newPassword,
      newServerToken: newServerToken,
    );
    await WireGuardDefaults.ensureMasterKey(configFile, settings);
    final rendered = <String, String>{
      'network': _quote(settings.network.trim()),
      'white_list': _quoteList(settings.whiteList),
      'lease_duration': '${settings.leaseDurationSeconds}',
      'persistence': '${settings.persistence}',
      'wireguard_max_active_peers': '${settings.wireGuardMaxActivePeers}',
    };
    _optional(rendered, 'tcp_bind', settings.tcpBind);
    _optional(rendered, 'quic_bind', settings.quicBind);
    _optional(rendered, 'ws_bind', settings.webSocketBind);
    _optional(rendered, 'cert', settings.certificateFile);
    _optional(rendered, 'key', settings.privateKeyFile);
    final preserve = <String>{};

    if (settings.webEnabled) {
      rendered['web_bind'] = _quote(settings.webBind.trim());
      rendered['username'] = _quote(settings.username.trim());
      if (newPassword.isNotEmpty) {
        rendered['password'] = _quote(newPassword);
      } else {
        preserve.add('password');
      }
    }
    if (settings.wireGuardEnabled) {
      rendered['wireguard_master_key_file'] = _quote(
        settings.wireGuardMasterKeyFile.trim(),
      );
      rendered['wireguard_bind'] = _quote(settings.wireGuardBind.trim());
      _optional(
        rendered,
        'wireguard_public_endpoint',
        settings.wireGuardPublicEndpoint,
      );
    }
    if (settings.serverQuicEnabled) {
      rendered['server_quic_bind'] = _quote(settings.serverQuicBind.trim());
      preserve.add('peer_servers');
      if (newServerToken.isNotEmpty) {
        rendered['server_token'] = _quote(newServerToken);
      } else {
        preserve.add('server_token');
      }
    }

    final updated = loaded._document.render(
      orderedKeys: _orderedKeys,
      rendered: rendered,
      preserve: preserve,
    );
    final backupDirectory = Directory(
      '${configFile.parent.path}${Platform.pathSeparator}.backups',
    );
    await backupDirectory.create(recursive: true);
    final stamp = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    final backupName =
        'config.toml.pre-flutter-'
        '${stamp.year}${two(stamp.month)}${two(stamp.day)}-'
        '${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}-'
        '${three(stamp.millisecond)}.bak';
    final backup = File(
      '${backupDirectory.path}${Platform.pathSeparator}$backupName',
    );
    await configFile.copy(backup.path);
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final temporary = File('${configFile.path}.flutter-$random.tmp');
    try {
      await temporary.writeAsString(updated, encoding: utf8, flush: true);
      await temporary.rename(configFile.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return ConfigSaveResult(backupPath: backup.path);
  }

  static void _validate(
    ServerConfigSettings settings, {
    required String newPassword,
    required String newServerToken,
  }) {
    if (!_isCidr(settings.network)) {
      throw const ConfigValidationException('默认网络必须是有效 IPv4 CIDR');
    }
    if (settings.leaseDurationSeconds <= 0) {
      throw const ConfigValidationException('租约时长必须大于 0 秒');
    }
    for (final binding in [
      settings.tcpBind,
      settings.quicBind,
      settings.webSocketBind,
    ]) {
      if (binding.isNotEmpty && !_isEndpoint(binding)) {
        throw ConfigValidationException('监听地址无效：$binding');
      }
    }
    if (settings.webEnabled) {
      if (!_isLoopbackEndpoint(settings.webBind)) {
        throw const ConfigValidationException('Web 管理端必须绑定 127.0.0.1 或 [::1]');
      }
      if (settings.username.trim().isEmpty) {
        throw const ConfigValidationException('Web 管理用户名不能为空');
      }
      if (!settings.hasPassword && newPassword.isEmpty) {
        throw const ConfigValidationException('启用 Web 管理端时必须设置密码');
      }
      if (newPassword.isNotEmpty &&
          (newPassword.trim().isEmpty ||
              newPassword.toLowerCase() == 'admin' ||
              newPassword == settings.username.trim())) {
        throw const ConfigValidationException('新密码不能为空、不能为 admin，也不能与用户名相同');
      }
    }
    if (settings.wireGuardEnabled) {
      if (settings.wireGuardMasterKeyFile.trim().isEmpty) {
        throw const ConfigValidationException('启用 WireGuard 时必须设置主密钥文件');
      }
      if (!_isEndpoint(settings.wireGuardBind)) {
        throw const ConfigValidationException('WireGuard 监听地址无效');
      }
      final endpoint = settings.wireGuardPublicEndpoint.trim();
      if (endpoint.isEmpty ||
          !_isEndpoint(endpoint) ||
          endpoint.contains('://') ||
          endpoint.startsWith('0.0.0.0:') ||
          endpoint.startsWith('[::]:')) {
        throw const ConfigValidationException('WireGuard 公网端点无效');
      }
      if (settings.wireGuardMaxActivePeers <= 0) {
        throw const ConfigValidationException('WireGuard 最大活跃 Peer 必须大于 0');
      }
    }
    if (settings.serverQuicEnabled) {
      if (!_isEndpoint(settings.serverQuicBind)) {
        throw const ConfigValidationException('互联服务监听地址无效');
      }
      if (!settings.hasServerToken && newServerToken.isEmpty) {
        throw const ConfigValidationException('启用互联服务时必须设置服务端 Token');
      }
    }
    final fields = [
      settings.certificateFile,
      settings.privateKeyFile,
      settings.wireGuardMasterKeyFile,
      ...settings.whiteList,
    ];
    if (fields.any((value) => value.contains('\n') || value.contains('\r'))) {
      throw const ConfigValidationException('配置字段不能包含换行符');
    }
  }

  static bool _isEndpoint(String value) {
    final text = value.trim();
    if (text.isEmpty || text.contains(RegExp(r'[\s/#]'))) return false;
    final match = RegExp(
      r'^(?:\[[0-9A-Fa-f:]+\]|[^:]+):(\d+)$',
    ).firstMatch(text);
    final port = int.tryParse(match?.group(1) ?? '');
    return port != null && port > 0 && port <= 65535;
  }

  static bool _isLoopbackEndpoint(String value) {
    final text = value.trim().toLowerCase();
    return (text.startsWith('127.0.0.1:') || text.startsWith('[::1]:')) &&
        _isEndpoint(text);
  }

  static bool _isCidr(String value) {
    final match = RegExp(
      r'^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$',
    ).firstMatch(value.trim());
    if (match == null) return false;
    final prefix = int.tryParse(match.group(2)!);
    return prefix != null &&
        prefix <= 32 &&
        match.group(1)!.split('.').every((part) {
          final octet = int.tryParse(part);
          return octet != null && octet <= 255;
        });
  }

  static void _optional(Map<String, String> values, String key, String value) {
    if (value.trim().isNotEmpty) values[key] = _quote(value.trim());
  }

  static String _quote(String value) {
    return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\r', '\\r').replaceAll('\n', '\\n')}"';
  }

  static String _quoteList(List<String> values) {
    return '[${values.map((value) => _quote(value.trim())).where((value) => value != '""').join(', ')}]';
  }

  static String _string(String? raw, {String fallback = ''}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    final value = raw.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return _unescape(value.substring(1, value.length - 1));
    }
    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  static List<String> _stringList(String? raw) {
    if (raw == null) return const [];
    final matches = RegExp("\"(?:\\\\.|[^\"\\\\])*\"|'[^']*'").allMatches(raw);
    return matches
        .map((match) => _string(match.group(0)))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  static int _integer(String? raw, int fallback) {
    return int.tryParse(raw?.trim() ?? '') ?? fallback;
  }

  static bool _boolean(String? raw, bool fallback) {
    final value = raw?.trim().toLowerCase();
    if (value == 'true') return true;
    if (value == 'false') return false;
    return fallback;
  }

  static String _unescape(String value) {
    final result = StringBuffer();
    var escaped = false;
    for (final codeUnit in value.codeUnits) {
      final char = String.fromCharCode(codeUnit);
      if (!escaped) {
        if (char == '\\') {
          escaped = true;
        } else {
          result.write(char);
        }
      } else {
        result.write(switch (char) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => char,
        });
        escaped = false;
      }
    }
    if (escaped) result.write('\\');
    return result.toString();
  }
}

class _ConfigDocument {
  const _ConfigDocument({
    required this.lines,
    required this.rootValues,
    required this.newline,
  });

  factory _ConfigDocument.parse(String text) {
    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    final lines = const LineSplitter().convert(text);
    final values = <String, String>{};
    for (final line in lines) {
      if (RegExp(r'^\s*\[').hasMatch(line)) break;
      final match = RegExp(
        r'^\s*([A-Za-z0-9_-]+)\s*=\s*(.*)$',
      ).firstMatch(line);
      if (match == null) continue;
      values[match.group(1)!] = _removeInlineComment(match.group(2)!).trim();
    }
    return _ConfigDocument(lines: lines, rootValues: values, newline: newline);
  }

  final List<String> lines;
  final Map<String, String> rootValues;
  final String newline;

  String render({
    required List<String> orderedKeys,
    required Map<String, String> rendered,
    required Set<String> preserve,
  }) {
    var rootEnd = lines.indexWhere((line) => RegExp(r'^\s*\[').hasMatch(line));
    if (rootEnd < 0) rootEnd = lines.length;
    final seen = <String>{};
    final updated = <String>[];
    for (var index = 0; index < rootEnd; index++) {
      final line = lines[index];
      final match = RegExp(r'^\s*([A-Za-z0-9_-]+)\s*=').firstMatch(line);
      final key = match?.group(1);
      if (key == null || !orderedKeys.contains(key)) {
        updated.add(line);
        continue;
      }
      if (!seen.add(key)) continue;
      if (preserve.contains(key) && rootValues.containsKey(key)) {
        updated.add(line);
      } else if (rendered.containsKey(key)) {
        final comment = _inlineComment(line);
        updated.add(
          '$key = ${rendered[key]}${comment.isEmpty ? '' : ' $comment'}',
        );
      }
    }
    final missing = <String>[];
    for (final key in orderedKeys) {
      if (seen.contains(key)) continue;
      if (rendered.containsKey(key)) missing.add('$key = ${rendered[key]}');
    }
    if (missing.isNotEmpty) {
      if (updated.isNotEmpty && updated.last.trim().isNotEmpty) updated.add('');
      updated.addAll(missing);
      if (rootEnd < lines.length) updated.add('');
    }
    updated.addAll(lines.skip(rootEnd));
    return '${updated.join(newline)}$newline';
  }

  static String _removeInlineComment(String value) {
    final index = _commentIndex(value);
    return index < 0 ? value : value.substring(0, index);
  }

  static String _inlineComment(String value) {
    final index = _commentIndex(value);
    return index < 0 ? '' : value.substring(index).trimRight();
  }

  static int _commentIndex(String value) {
    var quoted = false;
    var literal = false;
    var escaped = false;
    for (var index = 0; index < value.length; index++) {
      final char = value[index];
      if (escaped) {
        escaped = false;
      } else if (quoted && char == '\\') {
        escaped = true;
      } else if (!literal && char == '"') {
        quoted = !quoted;
      } else if (!quoted && char == "'") {
        literal = !literal;
      } else if (!quoted && !literal && char == '#') {
        return index;
      }
    }
    return -1;
  }
}

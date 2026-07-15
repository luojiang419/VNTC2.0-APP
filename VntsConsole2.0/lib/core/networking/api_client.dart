import 'dart:convert';
import 'dart:io';

import 'api_exception.dart';

class ApiClient {
  ApiClient({required Uri baseUri, HttpClient? httpClient})
    : baseUri = _validateBaseUri(baseUri),
      _httpClient = httpClient ?? HttpClient();

  factory ApiClient.loopback({int port = 39871}) {
    return ApiClient(baseUri: Uri.parse('http://127.0.0.1:$port/api/'));
  }

  static const _maximumResponseBytes = 4 * 1024 * 1024;

  final Uri baseUri;
  final HttpClient _httpClient;
  final Map<String, Cookie> _cookies = {};
  String? _csrfToken;
  void Function()? onSessionInvalidated;

  bool get hasSession => _cookies.isNotEmpty && _csrfToken != null;

  Future<Map<String, Object?>> getData(String path) async {
    final data = await getObject(path);
    if (data is Map) return Map<String, Object?>.from(data);
    throw const ApiException(ApiErrorKind.invalidResponse, '管理接口返回了无效对象');
  }

  Future<Object?> getObject(String path) => _request('GET', path);

  Future<Object?> postObject(String path, [Object? body]) {
    return _request('POST', path, body: body);
  }

  Future<Object?> putObject(String path, [Object? body]) {
    return _request('PUT', path, body: body);
  }

  Future<Object?> deleteObject(String path, [Object? body]) {
    return _request('DELETE', path, body: body);
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final data = await _request(
      'POST',
      'login',
      body: {'username': username, 'password': password},
      includeCsrf: false,
    );
    if (data is! Map || data['csrf_token'] is! String) {
      clearSession();
      throw const ApiException(
        ApiErrorKind.invalidResponse,
        '登录响应缺少 CSRF 会话信息',
      );
    }
    _csrfToken = data['csrf_token']! as String;
    if (_cookies.isEmpty) {
      clearSession();
      throw const ApiException(
        ApiErrorKind.invalidResponse,
        '登录响应缺少安全会话 Cookie',
      );
    }
  }

  Future<void> logout() async {
    try {
      await _request('POST', 'logout', includeCsrf: false);
    } finally {
      clearSession();
    }
  }

  void clearSession() {
    _cookies.clear();
    _csrfToken = null;
  }

  Future<Object?> _request(
    String method,
    String path, {
    Object? body,
    bool includeCsrf = true,
  }) async {
    final requestUri = baseUri.resolve(path);
    HttpClientResponse response;
    try {
      final request = await _httpClient.openUrl(method, requestUri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      for (final cookie in _cookies.values) {
        request.cookies.add(cookie);
      }
      if (includeCsrf && method != 'GET' && _csrfToken != null) {
        request.headers.set('x-csrf-token', _csrfToken!);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      response = await request.close();
    } on SocketException catch (error) {
      throw ApiException(
        ApiErrorKind.unavailable,
        '无法连接本机 VNTS2 管理接口：${error.message}',
      );
    } on HttpException catch (error) {
      throw ApiException(
        ApiErrorKind.unavailable,
        '本机管理接口请求失败：${error.message}',
      );
    }

    for (final cookie in response.cookies) {
      if (cookie.value.isEmpty || cookie.maxAge == 0) {
        _cookies.remove(cookie.name);
      } else {
        _cookies[cookie.name] = cookie;
      }
    }
    final payload = await _readJson(response);
    final message = payload['msg'] is String
        ? payload['msg']! as String
        : '请求失败';
    if (response.statusCode == HttpStatus.unauthorized) {
      clearSession();
      onSessionInvalidated?.call();
      throw ApiException(
        ApiErrorKind.unauthorized,
        message,
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == HttpStatus.forbidden) {
      throw ApiException(
        ApiErrorKind.forbidden,
        message,
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        ApiErrorKind.server,
        message,
        statusCode: response.statusCode,
      );
    }
    return payload['data'];
  }

  void close() => _httpClient.close(force: true);

  static Uri _validateBaseUri(Uri uri) {
    final address = InternetAddress.tryParse(uri.host);
    final loopback =
        uri.host.toLowerCase() == 'localhost' || address?.isLoopback == true;
    if (!loopback ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(uri, 'baseUri', '管理接口必须是无内嵌凭据的回环 HTTP(S) 地址');
    }
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  static Future<Map<String, Object?>> _readJson(
    HttpClientResponse response,
  ) async {
    if (response.contentLength > _maximumResponseBytes) {
      throw const ApiException(ApiErrorKind.invalidResponse, '管理接口响应过大');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maximumResponseBytes) {
        throw const ApiException(ApiErrorKind.invalidResponse, '管理接口响应过大');
      }
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    } on FormatException {
      // 统一转换为稳定的本地错误，不暴露原始响应。
    }
    throw const ApiException(ApiErrorKind.invalidResponse, '管理接口返回的 JSON 无效');
  }
}

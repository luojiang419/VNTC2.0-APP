import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/core/networking/api_client.dart';

void main() {
  test('增强版默认使用独立管理端口', () {
    final client = ApiClient.loopback();
    expect(client.baseUri.port, 39871);
    client.close();
  });

  test('API 客户端只接受无内嵌凭据的回环地址', () {
    final client = ApiClient(baseUri: Uri.parse('http://127.0.0.1:29871/api'));
    expect(client.baseUri.path, '/api/');
    client.close();

    expect(
      () => ApiClient(baseUri: Uri.parse('http://example.com/api/')),
      throwsArgumentError,
    );
    expect(
      () => ApiClient(baseUri: Uri.parse('http://admin:secret@localhost/api/')),
      throwsArgumentError,
    );
  });

  test('登录 Cookie 与 CSRF 只在内存会话中用于后续写请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var receivedCookie = false;
    var receivedCsrf = false;
    final handling = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/login') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['password'], 'one-time-password');
        request.response.cookies.add(
          Cookie('vnts2_session', 'memory-only')..httpOnly = true,
        );
        request.response.write(
          jsonEncode({
            'code': 200,
            'msg': 'success',
            'data': {
              'token': 'ignored-jwt',
              'csrf_token': 'csrf-memory',
              'expires_in_seconds': 60,
            },
          }),
        );
      } else if (request.uri.path == '/api/networks') {
        receivedCookie = request.cookies.any(
          (cookie) =>
              cookie.name == 'vnts2_session' && cookie.value == 'memory-only',
        );
        receivedCsrf = request.headers.value('x-csrf-token') == 'csrf-memory';
        request.response.write(
          jsonEncode({
            'code': 200,
            'msg': 'success',
            'data': {'ok': true},
          }),
        );
      }
      await request.response.close();
    });
    addTearDown(handling.cancel);

    final client = ApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/api/'),
    );
    addTearDown(client.close);
    await client.login(username: 'admin', password: 'one-time-password');
    expect(client.hasSession, isTrue);
    await client.postObject('networks', {'network_code': 'test'});
    expect(receivedCookie, isTrue);
    expect(receivedCsrf, isTrue);

    client.clearSession();
    expect(client.hasSession, isFalse);
  });
}

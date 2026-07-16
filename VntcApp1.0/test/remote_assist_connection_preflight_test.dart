import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_connection_preflight.dart';

void main() {
  test('连接预检能够访问正在监听的 TCP 端口', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((socket) => socket.destroy());

    try {
      await const RemoteAssistConnectionPreflight().probeTcpListener(
        InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });

  test('Android 连接被拒绝会映射为明确错误码', () {
    final code = remoteAssistErrorCodeForSocketException(
      const SocketException(
        'connection refused',
        osError: OSError('ECONNREFUSED', 111),
      ),
    );

    expect(code, RemoteAssistConnectionErrorCode.tcpRefused);
  });

  test('Android 无路由会映射为 VPN_ROUTE_MISSING', () {
    final code = remoteAssistErrorCodeForSocketException(
      const SocketException(
        'no route to host',
        osError: OSError('EHOSTUNREACH', 113),
      ),
    );

    expect(code, RemoteAssistConnectionErrorCode.routeMissing);
  });

  test('预检错误保持稳定机器码和可读提示', () {
    const error = RemoteAssistConnectionException(
      code: RemoteAssistConnectionErrorCode.peerHostNotReady,
      message: '目标受控服务未就绪',
    );

    expect(error.toString(), contains('PEER_HOST_NOT_READY'));
    expect(error.toString(), contains('目标受控服务未就绪'));
  });
}

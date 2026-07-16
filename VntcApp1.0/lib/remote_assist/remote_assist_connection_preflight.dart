import 'dart:async';
import 'dart:io';

class RemoteAssistConnectionErrorCode {
  RemoteAssistConnectionErrorCode._();

  static const String vntNotConnected = 'VNT_NOT_CONNECTED';
  static const String peerNotInActiveNetwork = 'PEER_NOT_IN_ACTIVE_NETWORK';
  static const String peerVntOffline = 'PEER_VNT_OFFLINE';
  static const String peerRoleUnsupported = 'PEER_ROLE_UNSUPPORTED';
  static const String peerHostNotReady = 'PEER_HOST_NOT_READY';
  static const String controllerUnavailable = 'CONTROLLER_UNAVAILABLE';
  static const String tcpRefused = 'TCP_49999_REFUSED';
  static const String tcpTimeout = 'TCP_49999_TIMEOUT';
  static const String routeMissing = 'VPN_ROUTE_MISSING';
  static const String tcpBlocked = 'TCP_49999_BLOCKED';
  static const String tcpUnreachable = 'TCP_49999_UNREACHABLE';
}

class RemoteAssistConnectionException implements Exception {
  const RemoteAssistConnectionException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}

String remoteAssistErrorCodeForSocketException(SocketException error) {
  switch (error.osError?.errorCode) {
    case 13: // Linux/Android EACCES
    case 10013: // Windows WSAEACCES
      return RemoteAssistConnectionErrorCode.tcpBlocked;
    case 60: // Darwin ETIMEDOUT
    case 110: // Linux/Android ETIMEDOUT
    case 10060: // Windows WSAETIMEDOUT
      return RemoteAssistConnectionErrorCode.tcpTimeout;
    case 61: // Darwin ECONNREFUSED
    case 111: // Linux/Android ECONNREFUSED
    case 10061: // Windows WSAECONNREFUSED
      return RemoteAssistConnectionErrorCode.tcpRefused;
    case 51: // Darwin ENETUNREACH
    case 65: // Darwin EHOSTUNREACH
    case 101: // Linux/Android ENETUNREACH
    case 113: // Linux/Android EHOSTUNREACH
    case 10051: // Windows WSAENETUNREACH
    case 10065: // Windows WSAEHOSTUNREACH
      return RemoteAssistConnectionErrorCode.routeMissing;
    default:
      return RemoteAssistConnectionErrorCode.tcpUnreachable;
  }
}

class RemoteAssistConnectionPreflight {
  const RemoteAssistConnectionPreflight();

  Future<void> probeTcpListener(
    String virtualIp, {
    required int port,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(virtualIp, port, timeout: timeout);
    } on TimeoutException {
      throw const RemoteAssistConnectionException(
        code: RemoteAssistConnectionErrorCode.tcpTimeout,
        message: '连接远程协助端口超时，请检查对方后台运行和网络状态',
      );
    } on SocketException catch (error) {
      final code = remoteAssistErrorCodeForSocketException(error);
      throw RemoteAssistConnectionException(
        code: code,
        message: _messageForCode(code),
      );
    } finally {
      socket?.destroy();
    }
  }

  String _messageForCode(String code) {
    switch (code) {
      case RemoteAssistConnectionErrorCode.tcpRefused:
        return '对方设备在线，但远程协助服务未监听 49999 端口';
      case RemoteAssistConnectionErrorCode.tcpTimeout:
        return '连接对方 49999 端口超时，请检查后台限制或网络质量';
      case RemoteAssistConnectionErrorCode.routeMissing:
        return '当前 VPN 隧道没有到对方虚拟 IP 的可用路由';
      case RemoteAssistConnectionErrorCode.tcpBlocked:
        return '系统或安全策略阻止访问远程协助端口';
      default:
        return '无法访问对方远程协助端口，请检查 VNT 和对方服务状态';
    }
  }
}

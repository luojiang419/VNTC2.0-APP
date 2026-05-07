import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_network_service.dart';

void main() {
  group('ChatNetworkService.isRetryableStartError', () {
    test('识别 Windows 10049 虚拟IP未就绪错误', () {
      const error = SocketException(
        'Failed to create server socket',
        osError: OSError('在其上下文中，该请求的地址无效。', 10049),
      );

      expect(ChatNetworkService.isRetryableStartError(error), isTrue);
    });

    test('识别 Linux cannot assign requested address 错误', () {
      const error = SocketException(
        'Cannot assign requested address',
        osError: OSError('Cannot assign requested address', 99),
      );

      expect(ChatNetworkService.isRetryableStartError(error), isTrue);
    });

    test('忽略其他网络错误', () {
      const error = SocketException(
        'Permission denied',
        osError: OSError('Permission denied', 13),
      );

      expect(ChatNetworkService.isRetryableStartError(error), isFalse);
    });
  });
}

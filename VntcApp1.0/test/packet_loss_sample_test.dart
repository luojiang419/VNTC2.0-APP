import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_quality/packet_loss_sample.dart';

void main() {
  group('gatewayConnectivitySampleFromRt', () {
    test('treats missing or zero RTT as no sample', () {
      expect(gatewayConnectivitySampleFromRt(null), isNull);
      expect(gatewayConnectivitySampleFromRt(0), isNull);
    });

    test('treats positive RTT below timeout sentinel as connected', () {
      expect(gatewayConnectivitySampleFromRt(1), isTrue);
      expect(gatewayConnectivitySampleFromRt(120), isTrue);
      expect(gatewayConnectivitySampleFromRt(9998), isTrue);
    });

    test('treats timeout sentinel RTT as failed', () {
      expect(gatewayConnectivitySampleFromRt(9999), isFalse);
      expect(gatewayConnectivitySampleFromRt(10000), isFalse);
    });
  });

  group('networkConnectivitySampleFromRoutes', () {
    test('valid peer RTT wins over an unusable gateway sentinel', () {
      expect(
        networkConnectivitySampleFromRoutes(
          onlinePeerRts: const [23],
          gatewayRt: 9999,
        ),
        isTrue,
      );
    });

    test('gateway sentinel alone is not treated as packet loss', () {
      expect(
        networkConnectivitySampleFromRoutes(
          onlinePeerRts: const [],
          gatewayRt: 9999,
        ),
        isNull,
      );
    });

    test('all online peers timing out is an explicit failure', () {
      expect(
        networkConnectivitySampleFromRoutes(
          onlinePeerRts: const [9999, 10000],
          gatewayRt: null,
        ),
        isFalse,
      );
    });

    test('incomplete peer RTT data stays unknown', () {
      expect(
        networkConnectivitySampleFromRoutes(
          onlinePeerRts: const [9999, 0],
          gatewayRt: null,
        ),
        isNull,
      );
    });
  });

  group('PacketLossWindow', () {
    test('requires consecutive failures before recording loss', () {
      final window = PacketLossWindow(consecutiveFailureThreshold: 3);

      expect(window.record(false), isNull);
      expect(window.record(false), isNull);
      expect(window.hasSamples, isFalse);
      expect(window.record(false), isFalse);
      expect(window.lossRate, 100);
    });

    test('healthy and unknown samples do not become false loss', () {
      final window = PacketLossWindow();

      expect(window.record(true), isTrue);
      expect(window.record(null), isNull);
      expect(window.lossRate, 0);
      expect(window.samples, [true]);
    });

    test('keeps a bounded recent sample window', () {
      final window = PacketLossWindow(
        maxSamples: 3,
        consecutiveFailureThreshold: 1,
      );
      window.record(false);
      window.record(true);
      window.record(true);
      window.record(true);

      expect(window.samples, [true, true, true]);
      expect(window.lossRate, 0);
    });
  });
}

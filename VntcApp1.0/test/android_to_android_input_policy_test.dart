import 'package:flutter_hbb/mobile/pages/remote_page.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android to Android input policy', () {
    test('Android controller uses mouse input for Android peer', () {
      expect(useDirectTouchModeForAndroidPeer(true), isFalse);
    });

    test('non-Android controller keeps direct touch for Android peer', () {
      expect(useDirectTouchModeForAndroidPeer(false), isTrue);
    });

    test('Android peer cursor is painted only for mouse input mode', () {
      expect(shouldPaintAndroidPeerCursor(touchMode: false), isTrue);
      expect(shouldPaintAndroidPeerCursor(touchMode: true), isFalse);
    });
  });
}

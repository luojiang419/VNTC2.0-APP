import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vnt_app/chat/chat_pcm_codec.dart';

void main() {
  group('ChatPcmCodec', () {
    test('int16 bytes roundtrip', () {
      final samples = Int16List.fromList(<int>[-32768, -1024, 0, 1024, 32767]);
      final bytes = ChatPcmCodec.int16ToBytes(samples);
      final decoded = ChatPcmCodec.bytesToInt16(bytes);

      expect(decoded, orderedEquals(samples));
    });

    test('float64 to int16 clips to valid range', () {
      expect(ChatPcmCodec.float64ToInt16(-2.0), -32767);
      expect(ChatPcmCodec.float64ToInt16(0.0), 0);
      expect(ChatPcmCodec.float64ToInt16(2.0), 32767);
    });
  });

  group('Downsample48kTo16kPcm16', () {
    test('averages every 3 samples into one pcm16 sample', () {
      final codec = Downsample48kTo16kPcm16();
      final bytes = codec.process(<double>[0.0, 0.5, 1.0]);
      final samples = ChatPcmCodec.bytesToInt16(bytes);

      expect(samples.length, 1);
      expect(samples.first, ChatPcmCodec.float64ToInt16(0.5));
    });

    test('preserves chunk boundary carry between calls', () {
      final codec = Downsample48kTo16kPcm16();

      final first = codec.process(<double>[0.0, 0.3]);
      final second = codec.process(<double>[0.6, 0.9, 1.0, 1.0]);

      expect(first, isEmpty);
      final samples = ChatPcmCodec.bytesToInt16(second);
      expect(samples.length, 2);
      expect(samples[0], ChatPcmCodec.float64ToInt16(0.3));
      expect(samples[1], ChatPcmCodec.float64ToInt16((0.9 + 1.0 + 1.0) / 3));
    });
  });

  group('Upsample16kPcm16To48kFloat64', () {
    test('expands each pcm16 sample to 3 float64 samples', () {
      final codec = Upsample16kPcm16To48kFloat64();
      final input = ChatPcmCodec.int16ToBytes(Int16List.fromList(<int>[0, 32767]));
      final output = codec.process(input);

      expect(output.length, 6);
      expect(output[0], closeTo(0.0, 0.0001));
      expect(output[1], closeTo(0.0, 0.0001));
      expect(output[2], closeTo(0.0, 0.0001));
      expect(output[3], closeTo(0.0, 0.0001));
      expect(output[4], greaterThan(0.3));
      expect(output[5], greaterThan(0.6));
    });

    test('preserves previous sample across chunk boundaries', () {
      final codec = Upsample16kPcm16To48kFloat64();
      codec.process(ChatPcmCodec.int16ToBytes(Int16List.fromList(<int>[16384])));

      final output =
          codec.process(ChatPcmCodec.int16ToBytes(Int16List.fromList(<int>[32767])));

      expect(output.length, 3);
      expect(output[0], closeTo(0.5, 0.02));
      expect(output[1], greaterThan(output[0]));
      expect(output[2], greaterThan(output[1]));
    });
  });
}

import 'dart:typed_data';

class ChatPcmCodec {
  ChatPcmCodec._();

  static const double _maxAmplitude = 32767.0;
  static const double _normalizationBase = 32768.0;

  static Int16List bytesToInt16(Uint8List bytes) {
    if (bytes.isEmpty) {
      return Int16List(0);
    }
    return Int16List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 2,
    );
  }

  static Uint8List int16ToBytes(Int16List samples) {
    if (samples.isEmpty) {
      return Uint8List(0);
    }
    return Uint8List.view(
      samples.buffer,
      samples.offsetInBytes,
      samples.lengthInBytes,
    );
  }

  static double int16ToFloat64(int sample) {
    return sample / _normalizationBase;
  }

  static int float64ToInt16(double sample) {
    final clipped = sample.clamp(-1.0, 1.0);
    final scaled = (clipped * _maxAmplitude).round();
    return scaled.clamp(-32768, 32767);
  }
}

class Downsample48kTo16kPcm16 {
  final List<double> _carry = <double>[];

  Uint8List process(List<double> input) {
    if (input.isEmpty) {
      return Uint8List(0);
    }
    final window = List<double>.from(_carry)..addAll(input);
    final frameCount = window.length ~/ 3;
    if (frameCount == 0) {
      _carry
        ..clear()
        ..addAll(window);
      return Uint8List(0);
    }

    final samples = Int16List(frameCount);
    for (var i = 0; i < frameCount; i++) {
      final offset = i * 3;
      final average =
          (window[offset] + window[offset + 1] + window[offset + 2]) / 3.0;
      samples[i] = ChatPcmCodec.float64ToInt16(average);
    }

    _carry
      ..clear()
      ..addAll(window.skip(frameCount * 3));

    return Uint8List.view(samples.buffer);
  }

  void reset() {
    _carry.clear();
  }
}

class Upsample16kPcm16To48kFloat64 {
  int? _previousSample;

  Float64List process(Uint8List bytes) {
    final input = ChatPcmCodec.bytesToInt16(bytes);
    if (input.isEmpty) {
      return Float64List(0);
    }

    final output = Float64List(input.length * 3);
    var outIndex = 0;
    for (final current in input) {
      final previous = _previousSample ?? current;
      output[outIndex++] = _lerp(previous, current, 0.0);
      output[outIndex++] = _lerp(previous, current, 1.0 / 3.0);
      output[outIndex++] = _lerp(previous, current, 2.0 / 3.0);
      _previousSample = current;
    }
    return output;
  }

  double _lerp(int previous, int current, double t) {
    final sample = previous + ((current - previous) * t);
    return ChatPcmCodec.int16ToFloat64(sample.round());
  }

  void reset() {
    _previousSample = null;
  }
}

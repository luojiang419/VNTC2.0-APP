import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/design_system/app_colors.dart';
import '../../domain/traffic_sample.dart';

class TrafficTrendChart extends StatelessWidget {
  const TrafficTrendChart({super.key, required this.samples});

  final List<TrafficSample> samples;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (samples.isEmpty) {
      return Center(
        child: Text(
          '等待第二个流量样本',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return CustomPaint(
      key: const Key('traffic-trend-chart'),
      painter: _TrafficPainter(
        samples: samples,
        gridColor: colors.outlineVariant,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _TrafficPainter extends CustomPainter {
  const _TrafficPainter({required this.samples, required this.gridColor});

  final List<TrafficSample> samples;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || samples.isEmpty) return;
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var row = 0; row <= 4; row++) {
      final y = size.height * row / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var column = 0; column <= 6; column++) {
      final x = size.width * column / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final maximum = samples.fold<double>(1, (value, sample) {
      return math.max(
        value,
        math.max(sample.txBytesPerSecond, sample.rxBytesPerSecond),
      );
    });
    _drawSeries(
      canvas,
      size,
      maximum,
      AppColors.brand,
      (sample) => sample.txBytesPerSecond,
    );
    _drawSeries(
      canvas,
      size,
      maximum,
      AppColors.cyan,
      (sample) => sample.rxBytesPerSecond,
    );
  }

  void _drawSeries(
    Canvas canvas,
    Size size,
    double maximum,
    Color color,
    double Function(TrafficSample) selector,
  ) {
    final path = Path();
    for (var index = 0; index < samples.length; index++) {
      final x = samples.length == 1
          ? size.width
          : size.width * index / (samples.length - 1);
      final y =
          size.height -
          (selector(samples[index]) / maximum * size.height * 0.9);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrafficPainter oldDelegate) {
    return oldDelegate.samples != samples || oldDelegate.gridColor != gridColor;
  }
}

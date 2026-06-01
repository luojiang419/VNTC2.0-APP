import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

enum WindowRestoreDecision {
  restored,
  clamped,
  centered,
}

class WindowPlacementResult {
  const WindowPlacementResult({
    required this.size,
    required this.position,
    required this.decision,
    required this.reason,
  });

  final Size size;
  final Offset position;
  final WindowRestoreDecision decision;
  final String reason;
}

class WindowRestoreGuard {
  static const Size defaultWindowSize = Size(1000, 700);
  static const Size minimumWindowSize = Size(800, 600);
  static const double _minimumVisibleWidth = 80;
  static const double _minimumVisibleHeight = 60;

  static WindowPlacementResult resolve({
    required List<Display> displays,
    required Size defaultSize,
    required Size minimumSize,
    Size? savedSize,
    Offset? savedPosition,
  }) {
    if (displays.isEmpty) {
      return WindowPlacementResult(
        size: _sanitizeSize(
          savedSize ?? defaultSize,
          minimumSize,
          Rect.fromLTWH(0, 0, defaultSize.width, defaultSize.height),
        ),
        position: Offset.zero,
        decision: WindowRestoreDecision.centered,
        reason: 'no_displays',
      );
    }

    final primaryBounds = _displayBounds(displays.first);
    final initialSize = _sanitizeSize(
      savedSize ?? defaultSize,
      minimumSize,
      primaryBounds,
    );

    if (savedPosition == null) {
      return WindowPlacementResult(
        size: initialSize,
        position: _centerOffset(primaryBounds, initialSize),
        decision: WindowRestoreDecision.centered,
        reason: 'no_saved_position',
      );
    }

    final targetRect = Rect.fromLTWH(
      savedPosition.dx,
      savedPosition.dy,
      initialSize.width,
      initialSize.height,
    );

    Rect? bestBounds;
    double bestIntersectionArea = 0;
    for (final display in displays) {
      final bounds = _displayBounds(display);
      final intersection = targetRect.intersect(bounds);
      final area =
          (math.max(0, intersection.width) * math.max(0, intersection.height))
              .toDouble();
      if (area > bestIntersectionArea) {
        bestIntersectionArea = area;
        bestBounds = bounds;
      }
    }

    if (bestBounds == null ||
        bestIntersectionArea < _minimumVisibleWidth * _minimumVisibleHeight) {
      return WindowPlacementResult(
        size: initialSize,
        position: _centerOffset(primaryBounds, initialSize),
        decision: WindowRestoreDecision.centered,
        reason: 'saved_position_out_of_bounds',
      );
    }

    final clamped = _clampOffset(bestBounds, initialSize, savedPosition);
    if (clamped != savedPosition) {
      return WindowPlacementResult(
        size: initialSize,
        position: clamped,
        decision: WindowRestoreDecision.clamped,
        reason: 'saved_position_clamped',
      );
    }

    return WindowPlacementResult(
      size: initialSize,
      position: savedPosition,
      decision: WindowRestoreDecision.restored,
      reason: 'saved_position_restored',
    );
  }

  static Rect _displayBounds(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  static Size _sanitizeSize(
    Size size,
    Size minimumSize,
    Rect primaryBounds,
  ) {
    final maxWidth = math.max(minimumSize.width, primaryBounds.width);
    final maxHeight = math.max(minimumSize.height, primaryBounds.height);
    final width = size.width.isFinite
        ? size.width.clamp(minimumSize.width, maxWidth).toDouble()
        : defaultWindowSize.width;
    final height = size.height.isFinite
        ? size.height.clamp(minimumSize.height, maxHeight).toDouble()
        : defaultWindowSize.height;
    return Size(width, height);
  }

  static Offset _centerOffset(Rect bounds, Size size) {
    return Offset(
      bounds.left + ((bounds.width - size.width) / 2),
      bounds.top + ((bounds.height - size.height) / 2),
    );
  }

  static Offset _clampOffset(
    Rect bounds,
    Size size,
    Offset desiredPosition,
  ) {
    final maxX = math.max(bounds.left, bounds.right - size.width);
    final maxY = math.max(bounds.top, bounds.bottom - size.height);
    return Offset(
      desiredPosition.dx.clamp(bounds.left, maxX).toDouble(),
      desiredPosition.dy.clamp(bounds.top, maxY).toDouble(),
    );
  }
}

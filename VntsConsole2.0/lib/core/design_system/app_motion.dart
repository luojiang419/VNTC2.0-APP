import 'package:flutter/animation.dart';

abstract final class AppMotion {
  static const fast = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 220);
  static const theme = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
}

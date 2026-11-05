import 'dart:ui';

/// Windows 仪表盘窗口尺寸策略。
class DashboardWindowSizing {
  const DashboardWindowSizing._();

  // 为标题栏、仪表盘操作区、连接状态、三张统计卡和底部导航保留空间。
  // 使用逻辑像素，窗口管理器会根据显示器 DPI 应用实际拖拽下限。
  static const Size regularMinimumSize = Size(720, 540);
  static const Size regularFullHdSize = regularMinimumSize;
  static const Size regularUltraHdSize = Size(760, 560);
  static const Size professionalMinimumSize = Size(800, 600);
  static const Size professionalPreferredSize = Size(1000, 700);

  /// screen_retriever 返回逻辑像素，需结合缩放比例判断物理分辨率。
  static Size regularSizeForDisplay(
    Size logicalDisplaySize, {
    num? scaleFactor,
  }) {
    final scale = switch (scaleFactor) {
      final value? when value.isFinite && value > 0 => value.toDouble(),
      _ => 1.0,
    };
    final physicalWidth = logicalDisplaySize.width * scale;
    final physicalHeight = logicalDisplaySize.height * scale;
    final longestSide =
        physicalWidth > physicalHeight ? physicalWidth : physicalHeight;
    final shortestSide =
        physicalWidth < physicalHeight ? physicalWidth : physicalHeight;

    if (longestSide >= 3840 && shortestSide >= 2160) {
      return regularUltraHdSize;
    }
    return regularFullHdSize;
  }
}

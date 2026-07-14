import 'dart:io';
import 'package:flutter/material.dart';
import 'color_utils.dart';
import 'app_theme_tokens.dart';
import '../utils/responsive_utils.dart';

/// VNT App 主题配置
/// 支持日间模式和暗黑模式
class AppTheme {
  // 主色调 - 青绿色 (#00BFA5 / Teal)
  static const Color primaryColor = Color(0xFF00BFA5);
  static const Color primaryColorLight = Color(0xFF5DF2D6);
  static const Color primaryDarkColor = Color(0xFF008E76);
  static const Color accentColor = Color(0xFF1DE9B6);

  // 状态颜色
  static const Color successColor = Color(0xFF4CAF50);
  static const Color warningColor = Color(0xFFFFC107);
  static const Color errorColor = Color(0xFFF44336);
  static const Color infoColor = Color(0xFF2196F3);

  // 日间模式颜色
  static const Color lightBackground = Color(0xFFF3F6F8);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCardBackground = Color(0xFFFFFFFF);
  static const Color lightTextPrimary = Color(0xFF18212B);
  static const Color lightTextSecondary = Color(0xFF65717E);
  static const Color lightDivider = Color(0xFFDCE4E9);
  static const Color lightNavBackground = Color(0xFFFBFCFD);

  // 暗黑模式颜色
  static const Color darkBackground = Color(0xFF22272F);
  static const Color darkSurface = Color(0xFF282F38);
  static const Color darkCardBackground = Color(0xFF2B323C);
  static const Color darkTextPrimary = Color(0xFFF1F5F7);
  static const Color darkTextSecondary = Color(0xFFAAB4BF);
  static const Color darkDivider = Color(0xFF414B58);
  static const Color darkNavBackground = Color(0xFF272D36);

  /// 创建日间主题（支持自定义主题色）
  static ThemeData createLightTheme(Color primaryColor) {
    final tokens = AppThemeTokens.light(primaryColor);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: primaryColor,
      scaffoldBackgroundColor: tokens.canvas,
      canvasColor: tokens.canvas,
      cardColor: tokens.surface,
      dividerColor: tokens.outline,
      extensions: [tokens],
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.navigation,
        foregroundColor: tokens.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          color: lightTextPrimary,
          fontSize: DesignSystem.fontSizeLarge,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: const IconThemeData(color: lightTextPrimary),
      ),
      cardTheme: CardThemeData(
        color: tokens.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: tokens.outline),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tokens.surfaceRaised,
        modalBackgroundColor: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryColor,
          side: BorderSide(color: primaryColor),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.surfaceRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: lightDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: lightDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: errorColor),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return Colors.grey;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor.withValues(alpha: 0.5);
          }
          return Colors.grey.withValues(alpha: 0.3);
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: tokens.navigation,
        selectedItemColor: primaryColor,
        unselectedItemColor: lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: tokens.navigation,
        selectedIconTheme: IconThemeData(color: primaryColor),
        unselectedIconTheme: const IconThemeData(color: lightTextSecondary),
        selectedLabelTextStyle:
            TextStyle(color: primaryColor, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: const TextStyle(color: lightTextSecondary),
      ),
      colorScheme: ColorScheme.light(
        primary: primaryColor,
        secondary: ColorUtils.lighten(primaryColor, 0.1),
        surface: tokens.surface,
        onSurface: tokens.textPrimary,
        outline: tokens.outline,
        error: errorColor,
      ),
      dividerTheme: DividerThemeData(color: tokens.outline, thickness: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tokens.outline),
          boxShadow: [BoxShadow(color: tokens.shadow, blurRadius: 14)],
        ),
        textStyle: TextStyle(color: tokens.textPrimary),
      ),
    );
  }

  /// 创建暗黑主题（支持自定义主题色）
  static ThemeData createDarkTheme(Color primaryColor) {
    final tokens = AppThemeTokens.dark(primaryColor);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: primaryColor,
      scaffoldBackgroundColor: tokens.canvas,
      canvasColor: tokens.canvas,
      cardColor: tokens.surface,
      dividerColor: tokens.outline,
      extensions: [tokens],
      fontFamily: Platform.isWindows ? 'Microsoft YaHei' : null,
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.navigation,
        foregroundColor: tokens.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          color: darkTextPrimary,
          fontSize: DesignSystem.fontSizeLarge,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: tokens.textPrimary),
      ),
      cardTheme: CardThemeData(
        color: tokens.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: tokens.outline),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tokens.surfaceRaised,
        modalBackgroundColor: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryColor,
          side: BorderSide(color: primaryColor),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.surfaceRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: darkDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: errorColor),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return Colors.grey;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor.withValues(alpha: 0.5);
          }
          return Colors.grey.withValues(alpha: 0.3);
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: tokens.navigation,
        selectedItemColor: primaryColor,
        unselectedItemColor: darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: tokens.navigation,
        selectedIconTheme: IconThemeData(color: primaryColor),
        unselectedIconTheme: const IconThemeData(color: darkTextSecondary),
        selectedLabelTextStyle:
            TextStyle(color: primaryColor, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: const TextStyle(color: darkTextSecondary),
      ),
      colorScheme: ColorScheme.dark(
        primary: primaryColor,
        secondary: ColorUtils.lighten(primaryColor, 0.1),
        surface: tokens.surface,
        onSurface: tokens.textPrimary,
        outline: tokens.outline,
        error: errorColor,
      ),
      dividerTheme: DividerThemeData(color: tokens.outline, thickness: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: tokens.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: tokens.shadow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tokens.outline),
          boxShadow: [BoxShadow(color: tokens.shadow, blurRadius: 14)],
        ),
        textStyle: TextStyle(color: tokens.textPrimary),
      ),
    );
  }

  /// 日间主题（使用默认主题色）
  static ThemeData lightTheme = createLightTheme(primaryColor);

  /// 暗黑主题（使用默认主题色）
  static ThemeData darkTheme = createDarkTheme(primaryColor);
}

/// 主题扩展 - 用于获取自定义颜色
extension ThemeExtension on BuildContext {
  /// 是否为暗黑模式
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  /// 获取卡片背景色
  Color get cardBackground => themeTokens.surface;

  /// 获取浮起模块背景色
  Color get raisedSurface => themeTokens.surfaceRaised;

  /// 获取弱化模块背景色
  Color get mutedSurface => themeTokens.surfaceMuted;

  /// 获取页面画布色
  Color get canvasBackground => themeTokens.canvas;

  /// 获取主要文字颜色
  Color get textPrimary => themeTokens.textPrimary;

  /// 获取次要文字颜色
  Color get textSecondary => themeTokens.textSecondary;

  /// 获取分割线颜色
  Color get dividerColor => themeTokens.outline;

  /// 获取导航栏背景色
  Color get navBackground => themeTokens.navigation;
}

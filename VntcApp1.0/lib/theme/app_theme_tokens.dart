import 'package:flutter/material.dart';

/// 应用语义色板。
///
/// 页面和组件只表达“画布、表面、边框”等视觉角色，不再自行拼接灰阶，
/// 从而保证暗黑与浅色模式始终使用同一套层级关系。
@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  final Color canvas;
  final Color navigation;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceMuted;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color shadow;
  final Color glow;

  const AppThemeTokens({
    required this.canvas,
    required this.navigation,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceMuted,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.shadow,
    required this.glow,
  });

  factory AppThemeTokens.light(Color primaryColor) {
    return AppThemeTokens(
      canvas: const Color(0xFFF3F6F8),
      navigation: const Color(0xFFFBFCFD),
      surface: const Color(0xFFFFFFFF),
      surfaceRaised: const Color(0xFFF8FAFC),
      surfaceMuted: const Color(0xFFEDF2F5),
      outline: const Color(0xFFDCE4E9),
      textPrimary: const Color(0xFF18212B),
      textSecondary: const Color(0xFF65717E),
      shadow: const Color(0x24152632),
      glow: primaryColor.withValues(alpha: 0.18),
    );
  }

  factory AppThemeTokens.dark(Color primaryColor) {
    return AppThemeTokens(
      canvas: const Color(0xFF22272F),
      navigation: const Color(0xFF272D36),
      surface: const Color(0xFF2B323C),
      surfaceRaised: const Color(0xFF333B47),
      surfaceMuted: const Color(0xFF282F38),
      outline: const Color(0xFF414B58),
      textPrimary: const Color(0xFFF1F5F7),
      textSecondary: const Color(0xFFAAB4BF),
      shadow: const Color(0x59101820),
      glow: primaryColor.withValues(alpha: 0.22),
    );
  }

  @override
  AppThemeTokens copyWith({
    Color? canvas,
    Color? navigation,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceMuted,
    Color? outline,
    Color? textPrimary,
    Color? textSecondary,
    Color? shadow,
    Color? glow,
  }) {
    return AppThemeTokens(
      canvas: canvas ?? this.canvas,
      navigation: navigation ?? this.navigation,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      outline: outline ?? this.outline,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      shadow: shadow ?? this.shadow,
      glow: glow ?? this.glow,
    );
  }

  @override
  AppThemeTokens lerp(covariant AppThemeTokens? other, double t) {
    if (other == null) return this;
    return AppThemeTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      navigation: Color.lerp(navigation, other.navigation, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
    );
  }
}

extension AppThemeTokenContext on BuildContext {
  AppThemeTokens get themeTokens {
    final tokens = Theme.of(this).extension<AppThemeTokens>();
    assert(tokens != null, 'AppThemeTokens 未注册到 ThemeData');
    return tokens!;
  }
}

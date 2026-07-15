import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.brand,
          brightness: brightness,
          primary: dark ? AppColors.brand : AppColors.brandStrong,
          secondary: AppColors.cyan,
          surface: dark ? AppColors.darkSurface : AppColors.lightSurface,
          error: AppColors.danger,
        ).copyWith(
          outline: dark ? AppColors.darkOutline : AppColors.lightOutline,
          outlineVariant: dark
              ? AppColors.darkOutline.withValues(alpha: 0.7)
              : AppColors.lightOutline.withValues(alpha: 0.75),
          surfaceContainerLowest: dark
              ? AppColors.darkBackground
              : AppColors.lightBackground,
          surfaceContainerLow: dark
              ? AppColors.darkSurface
              : AppColors.lightSurface,
          surfaceContainer: dark
              ? AppColors.darkSurfaceRaised
              : AppColors.lightSurfaceRaised,
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      fontFamily: 'Segoe UI',
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.6,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 18,
        ),
        errorMaxLines: 3,
        helperMaxLines: 3,
        floatingLabelStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface),
      ),
    );
  }
}

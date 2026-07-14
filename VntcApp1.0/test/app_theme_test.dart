import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';
import 'package:vnt_app/widgets/app_glow_surface.dart';

void main() {
  group('AppTheme semantic palette', () {
    test('dark theme uses layered graphite surfaces instead of black', () {
      final theme = AppTheme.createDarkTheme(AppTheme.primaryColor);
      final tokens = theme.extension<AppThemeTokens>()!;

      expect(theme.scaffoldBackgroundColor, tokens.canvas);
      expect(tokens.canvas, isNot(const Color(0xFF000000)));
      expect(tokens.canvas, isNot(const Color(0xFF121212)));
      expect(tokens.canvas.computeLuminance(), greaterThan(0.015));
      expect(tokens.navigation, isNot(tokens.canvas));
      expect(tokens.surface, isNot(tokens.navigation));
      expect(tokens.surfaceRaised, isNot(tokens.surface));
      expect(theme.cardColor, tokens.surface);
      expect(theme.dividerColor, tokens.outline);
    });

    test('light theme keeps cool canvas and distinct elevated surfaces', () {
      final theme = AppTheme.createLightTheme(AppTheme.primaryColor);
      final tokens = theme.extension<AppThemeTokens>()!;

      expect(theme.scaffoldBackgroundColor, tokens.canvas);
      expect(tokens.canvas, isNot(tokens.surface));
      expect(tokens.surface.computeLuminance(), greaterThan(0.95));
      expect(tokens.textPrimary.computeLuminance(), lessThan(0.05));
    });

    test('custom accent color is propagated to the glow token', () {
      const accent = Color(0xFF6C63FF);
      final darkTokens =
          AppTheme.createDarkTheme(accent).extension<AppThemeTokens>()!;
      final lightTokens =
          AppTheme.createLightTheme(accent).extension<AppThemeTokens>()!;

      expect(darkTokens.glow.r, closeTo(accent.r, 0.001));
      expect(darkTokens.glow.g, closeTo(accent.g, 0.001));
      expect(darkTokens.glow.b, closeTo(accent.b, 0.001));
      expect(lightTokens.glow.r, closeTo(accent.r, 0.001));
    });
  });

  testWidgets('glow surface renders and animates in both themes',
      (tester) async {
    Future<void> pumpSurface(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: AppGlowSurface(
              active: true,
              pulse: true,
              child: Text('模块'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('模块'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    await pumpSurface(AppTheme.lightTheme);
    await pumpSurface(AppTheme.darkTheme);
  });
}

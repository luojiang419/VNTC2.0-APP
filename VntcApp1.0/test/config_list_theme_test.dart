import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';
import 'package:vnt_app/widgets/config_management_card_surface.dart';

void main() {
  Future<({ConfigManagementCardPalette palette, BoxDecoration decoration})>
      pumpSurface(
    WidgetTester tester,
    ThemeData theme, {
    required bool isConnected,
  }) async {
    late ConfigManagementCardPalette palette;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              palette = ConfigManagementCardPalette.of(
                context,
                isConnected: isConnected,
              );
              return ConfigManagementCardSurface(
                isConnected: isConnected,
                child: const Text('配置卡片'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = tester.widget<Container>(
      find.byKey(const ValueKey('config-management-card-surface')),
    );
    return (
      palette: palette,
      decoration: container.decoration! as BoxDecoration,
    );
  }

  testWidgets('配置卡片表面在浅色和深色主题中使用语义令牌', (tester) async {
    final lightDisconnected = await pumpSurface(
      tester,
      AppTheme.lightTheme,
      isConnected: false,
    );
    final lightTokens = AppTheme.lightTheme.extension<AppThemeTokens>()!;
    expect(lightDisconnected.palette.surface, lightTokens.surface);
    expect(lightDisconnected.palette.border, lightTokens.outline);
    expect(lightDisconnected.palette.textPrimary, lightTokens.textPrimary);
    expect(
      lightDisconnected.palette.textSecondary,
      lightTokens.textSecondary,
    );
    expect(
      lightDisconnected.decoration.color,
      lightDisconnected.palette.surface,
    );

    final darkConnected = await pumpSurface(
      tester,
      AppTheme.darkTheme,
      isConnected: true,
    );
    final darkTokens = AppTheme.darkTheme.extension<AppThemeTokens>()!;
    expect(darkConnected.palette.textPrimary, darkTokens.textPrimary);
    expect(darkConnected.palette.textSecondary, darkTokens.textSecondary);
    expect(darkConnected.palette.surface, isNot(darkTokens.surface));
    expect(
      darkConnected.decoration.border!.top.color,
      darkConnected.palette.border,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('配置卡片连接状态完整跟随自定义主题主色', (tester) async {
    const purple = Color(0xFF6C63FF);
    const orange = Color(0xFFF57C00);

    final purpleCard = await pumpSurface(
      tester,
      AppTheme.createLightTheme(purple),
      isConnected: true,
    );
    final orangeCard = await pumpSurface(
      tester,
      AppTheme.createLightTheme(orange),
      isConnected: true,
    );

    expect(purpleCard.palette.status, purple);
    expect(
      purpleCard.palette.border,
      purple.withValues(alpha: 0.58),
    );
    expect(orangeCard.palette.status, orange);
    expect(
      orangeCard.palette.border,
      orange.withValues(alpha: 0.58),
    );
    expect(purpleCard.palette.surface, isNot(orangeCard.palette.surface));
    expect(
      purpleCard.palette.actionSurface,
      isNot(orangeCard.palette.actionSurface),
    );
    expect(tester.takeException(), isNull);
  });
}

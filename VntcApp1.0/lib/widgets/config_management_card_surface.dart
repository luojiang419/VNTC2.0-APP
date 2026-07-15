import 'package:flutter/material.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';
import 'package:vnt_app/utils/responsive_utils.dart';

@immutable
class ConfigManagementCardPalette {
  final Color surface;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color status;
  final Color badgeForeground;
  final Color actionSurface;
  final Color connectForeground;
  final Color disconnectSurface;
  final Color disconnectForeground;

  const ConfigManagementCardPalette({
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.status,
    required this.badgeForeground,
    required this.actionSurface,
    required this.connectForeground,
    required this.disconnectSurface,
    required this.disconnectForeground,
  });

  factory ConfigManagementCardPalette.of(
    BuildContext context, {
    required bool isConnected,
  }) {
    final theme = Theme.of(context);
    final tokens = context.themeTokens;
    final primary = theme.colorScheme.primary;
    final error = theme.colorScheme.error;
    final tintAlpha = theme.brightness == Brightness.dark ? 0.16 : 0.08;

    return ConfigManagementCardPalette(
      surface: isConnected
          ? Color.alphaBlend(
              primary.withValues(alpha: tintAlpha),
              tokens.surface,
            )
          : tokens.surface,
      border: isConnected ? primary.withValues(alpha: 0.58) : tokens.outline,
      textPrimary: tokens.textPrimary,
      textSecondary: tokens.textSecondary,
      status:
          isConnected ? primary : tokens.textSecondary.withValues(alpha: 0.72),
      badgeForeground: theme.colorScheme.onPrimary,
      actionSurface: Color.alphaBlend(
        primary.withValues(alpha: isConnected ? 0.10 : 0.04),
        tokens.surfaceRaised,
      ),
      connectForeground: theme.colorScheme.onPrimary,
      disconnectSurface: Color.alphaBlend(
        error.withValues(alpha: 0.10),
        tokens.surfaceRaised,
      ),
      disconnectForeground: error,
    );
  }
}

class ConfigManagementCardSurface extends StatelessWidget {
  final bool isConnected;
  final Widget child;

  const ConfigManagementCardSurface({
    super.key,
    required this.isConnected,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = ConfigManagementCardPalette.of(
      context,
      isConnected: isConnected,
    );
    final tokens = context.themeTokens;

    return Container(
      key: const ValueKey('config-management-card-surface'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.cardRadius),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: tokens.shadow,
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

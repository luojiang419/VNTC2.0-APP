import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app.dart';
import '../../app/app_controller.dart';
import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';

class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.status,
    this.onLock,
    this.lockShortcutLabel,
    this.closeBehaviorLabel,
  });

  final ServiceConnectionStatus status;
  final VoidCallback? onLock;
  final String? lockShortcutLabel;
  final String? closeBehaviorLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = Container(
      height: 50,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.md),
          Container(
            width: 29,
            height: 29,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.brand, AppColors.cyan],
                begin: Alignment.bottomLeft,
                end: Alignment.topRight,
              ),
              borderRadius: BorderRadius.circular(9),
              boxShadow: [
                BoxShadow(
                  color: AppColors.brand.withValues(alpha: 0.25),
                  blurRadius: 14,
                ),
              ],
            ),
            child: const Icon(
              Icons.route_rounded,
              size: 18,
              color: Color(0xFF06221E),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            VntsConsoleApp.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: _statusColor(colors)),
                const SizedBox(width: 6),
                Text(
                  _statusLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (onLock != null)
            _WindowButton(
              tooltip: lockShortcutLabel == null
                  ? '立即锁定'
                  : '立即锁定（$lockShortcutLabel）',
              icon: Icons.lock_outline_rounded,
              onPressed: onLock!,
            ),
          if (Platform.isWindows) ...[
            _WindowButton(
              tooltip: '最小化',
              icon: Icons.minimize_rounded,
              onPressed: windowManager.minimize,
            ),
            _WindowButton(
              tooltip: '最大化/还原',
              icon: Icons.crop_square_rounded,
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            _WindowButton(
              tooltip: closeBehaviorLabel == null
                  ? '关闭'
                  : '关闭：$closeBehaviorLabel',
              icon: Icons.close_rounded,
              destructive: true,
              onPressed: windowManager.close,
            ),
          ],
        ],
      ),
    );

    if (!Platform.isWindows) return title;
    return DragToMoveArea(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: () async {
          if (await windowManager.isMaximized()) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
        },
        child: title,
      ),
    );
  }

  String get _statusLabel => switch (status) {
    ServiceConnectionStatus.unknown => '等待服务',
    ServiceConnectionStatus.running => '服务运行中',
    ServiceConnectionStatus.authenticationRequired => '需要登录',
    ServiceConnectionStatus.unreachable => '服务不可达',
  };

  Color _statusColor(ColorScheme colors) => switch (status) {
    ServiceConnectionStatus.unknown => colors.onSurfaceVariant,
    ServiceConnectionStatus.running => AppColors.success,
    ServiceConnectionStatus.authenticationRequired => AppColors.warning,
    ServiceConnectionStatus.unreachable => AppColors.danger,
  };
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 50,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        hoverColor: destructive
            ? Theme.of(context).colorScheme.error.withValues(alpha: 0.85)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        icon: Icon(icon, size: 18),
      ),
    );
  }
}

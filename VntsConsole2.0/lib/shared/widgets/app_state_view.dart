import 'package:flutter/material.dart';

import '../../core/design_system/app_spacing.dart';

class AppStateView extends StatelessWidget {
  const AppStateView._({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.iconColor,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  const AppStateView.loading({
    Key? key,
    String title = '正在加载',
    String message = '正在获取最新数据，请稍候。',
  }) : this._(
         key: key,
         icon: Icons.hourglass_top_rounded,
         title: title,
         message: message,
         loading: true,
       );

  const AppStateView.empty({
    Key? key,
    IconData icon = Icons.inbox_outlined,
    required String title,
    required String message,
    Color? iconColor,
    String? actionLabel,
    VoidCallback? onAction,
  }) : this._(
         key: key,
         icon: icon,
         title: title,
         message: message,
         iconColor: iconColor,
         actionLabel: actionLabel,
         onAction: onAction,
       );

  const AppStateView.error({
    Key? key,
    String title = '加载失败',
    required String message,
    String actionLabel = '重试',
    VoidCallback? onAction,
  }) : this._(
         key: key,
         icon: Icons.error_outline_rounded,
         title: title,
         message: message,
         actionLabel: actionLabel,
         onAction: onAction,
       );

  final IconData icon;
  final String title;
  final String message;
  final Color? iconColor;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight =
            constraints.hasBoundedHeight && constraints.maxHeight > 48
            ? constraints.maxHeight - 48
            : 0.0;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 480, minHeight: minHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const SizedBox.square(
                      dimension: 42,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  else
                    Icon(
                      icon,
                      size: 46,
                      color: iconColor ?? theme.colorScheme.error,
                    ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton.tonal(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

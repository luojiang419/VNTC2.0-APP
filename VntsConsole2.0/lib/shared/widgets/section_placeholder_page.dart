import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import 'app_state_view.dart';

class SectionPlaceholderPage extends StatelessWidget {
  const SectionPlaceholderPage({super.key, required this.route});

  final AppRoute route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(route.label, style: theme.textTheme.headlineMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            route.description,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: Card(
              child: AppStateView.empty(
                icon: route.icon,
                title: '${route.label}模块',
                message: '应用壳层与路由已就绪，业务数据将在对应模块接入。',
                iconColor: AppColors.brand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

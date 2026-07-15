import 'package:flutter/material.dart';

import '../core/design_system/app_colors.dart';
import '../core/design_system/app_spacing.dart';
import '../shared/widgets/app_title_bar.dart';
import 'app_controller.dart';
import 'app_router.dart';
import 'app_routes.dart';
import 'console_access_gate.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _manuallyCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activator = widget.controller.isAuthenticated
        ? widget.controller.lockShortcut.activator
        : null;
    final content = Focus(
      autofocus: true,
      onKeyEvent: (_, _) {
        widget.controller.recordActivity();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => widget.controller.recordActivity(),
        onPointerSignal: (_) => widget.controller.recordActivity(),
        child: Scaffold(
          body: ColoredBox(
            color: colors.surface,
            child: Stack(
              children: [
                Column(
                  children: [
                    AppTitleBar(
                      status: widget.controller.serviceConnectionStatus,
                      onLock: widget.controller.isAuthenticated
                          ? widget.controller.lockNow
                          : null,
                      lockShortcutLabel: widget.controller.lockShortcut.label,
                      closeBehaviorLabel: widget.controller.closeBehavior.label,
                    ),
                    Expanded(
                      child: widget.controller.isAuthenticated
                          ? _AuthenticatedWorkspace(
                              controller: widget.controller,
                              manuallyCollapsed: _manuallyCollapsed,
                              onToggleCollapsed: () => setState(
                                () => _manuallyCollapsed = !_manuallyCollapsed,
                              ),
                            )
                          : ConsoleAccessGate(controller: widget.controller),
                    ),
                  ],
                ),
                if (widget.controller.showIntegratedServiceOverlay)
                  Positioned.fill(
                    child: _IntegratedServiceOverlay(
                      controller: widget.controller,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (activator == null) return content;
    return CallbackShortcuts(
      bindings: {activator: widget.controller.lockNow},
      child: content,
    );
  }
}

class _AuthenticatedWorkspace extends StatelessWidget {
  const _AuthenticatedWorkspace({
    required this.controller,
    required this.manuallyCollapsed,
    required this.onToggleCollapsed,
  });

  final AppController controller;
  final bool manuallyCollapsed;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final autoCollapsed = constraints.maxWidth < 1180;
        final collapsed = autoCollapsed || manuallyCollapsed;
        return Row(
          children: [
            _SideNavigation(
              key: Key(
                collapsed ? 'navigation-collapsed' : 'navigation-expanded',
              ),
              collapsed: collapsed,
              route: controller.route,
              onSelect: controller.selectRoute,
              onToggle: autoCollapsed ? null : onToggleCollapsed,
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: colors.outlineVariant.withValues(alpha: 0.55),
            ),
            Expanded(
              child: ColoredBox(
                color: colors.surfaceContainerLowest,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1680),
                    child: AppRouter(controller: controller),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _IntegratedServiceOverlay extends StatelessWidget {
  const _IntegratedServiceOverlay({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed =
        controller.integratedServiceState == IntegratedServiceState.failed;
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: 0.72),
      child: Center(
        child: Card(
          key: const Key('integrated-service-overlay'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 48,
                      color: AppColors.warning,
                    )
                  else
                    const SizedBox.square(
                      dimension: 42,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    failed ? '集成服务准备失败' : '正在准备 VNTS2 集成服务',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    controller.integratedServiceMessage ?? '请稍候…',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  if (!failed) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '首次启动会自动创建便携配置、安装并启动服务。',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (failed) ...[
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton.icon(
                      onPressed: controller.initializeIntegratedService,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试集成服务'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    super.key,
    required this.collapsed,
    required this.route,
    required this.onSelect,
    required this.onToggle,
  });

  final bool collapsed;
  final AppRoute route;
  final ValueChanged<AppRoute> onSelect;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: collapsed ? 76 : 252,
      color: colors.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              collapsed ? 12 : AppSpacing.lg,
              AppSpacing.md,
              collapsed ? 12 : AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.spaceBetween,
              children: [
                if (!collapsed)
                  Text(
                    '工作区',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                if (onToggle != null)
                  IconButton(
                    key: const Key('navigation-toggle'),
                    tooltip: collapsed ? '展开侧栏' : '收起侧栏',
                    onPressed: onToggle,
                    icon: Icon(
                      collapsed
                          ? Icons.keyboard_double_arrow_right
                          : Icons.keyboard_double_arrow_left,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              children: [
                for (final item in AppRoute.values)
                  _NavigationItem(
                    collapsed: collapsed,
                    item: item,
                    selected: route == item,
                    onTap: () => onSelect(item),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: collapsed
                ? const Tooltip(
                    message: '本机增强控制台',
                    child: Icon(
                      Icons.admin_panel_settings_outlined,
                      color: AppColors.brand,
                    ),
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.admin_panel_settings_outlined,
                        color: AppColors.brand,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          '管理员模式 · 本机',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.collapsed,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final bool collapsed;
  final AppRoute item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.13)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: Key('route-${item.name}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: collapsed
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              if (!collapsed) const SizedBox(width: AppSpacing.md),
              Icon(
                item.icon,
                size: 21,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              if (!collapsed) ...[
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    item.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? colors.primary : colors.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: collapsed ? Tooltip(message: item.label, child: content) : content,
    );
  }
}

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../controller/dashboard_controller.dart';
import '../data/dashboard_repository.dart';
import '../domain/dashboard_snapshot.dart';
import 'dashboard_formatters.dart';
import 'widgets/traffic_trend_chart.dart';

class DashboardPlaceholderPage extends StatefulWidget {
  const DashboardPlaceholderPage({
    super.key,
    this.apiClient,
    this.controller,
    this.onConnectionChanged,
    this.onRestartService,
    this.pollInterval = const Duration(seconds: 1),
  }) : assert(apiClient == null || controller == null);

  final ApiClient? apiClient;
  final DashboardController? controller;
  final ValueChanged<ServiceConnectionStatus>? onConnectionChanged;
  final Future<void> Function()? onRestartService;
  final Duration pollInterval;

  @override
  State<DashboardPlaceholderPage> createState() =>
      _DashboardPlaceholderPageState();
}

class _DashboardPlaceholderPageState extends State<DashboardPlaceholderPage> {
  DashboardController? _controller;
  bool _ownsController = false;
  int _trendMinutes = 5;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    if (_controller == null && widget.apiClient != null) {
      _controller = DashboardController(
        repository: DashboardRepository(widget.apiClient!),
        pollInterval: widget.pollInterval,
      );
      _ownsController = true;
    }
    _controller?.addListener(_relayConnectionStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller?.setVisible(true);
    });
  }

  void _relayConnectionStatus() {
    final controller = _controller;
    if (controller == null) return;
    final status = switch (controller.state) {
      DashboardLoadState.ready => ServiceConnectionStatus.running,
      DashboardLoadState.authenticationRequired =>
        ServiceConnectionStatus.authenticationRequired,
      DashboardLoadState.error => ServiceConnectionStatus.unreachable,
      DashboardLoadState.idle ||
      DashboardLoadState.loading => ServiceConnectionStatus.unknown,
    };
    widget.onConnectionChanged?.call(status);
  }

  @override
  void dispose() {
    _controller?.setVisible(false);
    _controller?.removeListener(_relayConnectionStatus);
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const _DashboardNotConnected();
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        if (snapshot == null) {
          return _DashboardInitialState(controller: controller);
        }
        return _DashboardContent(
          controller: controller,
          snapshot: snapshot,
          trendMinutes: _trendMinutes,
          onTrendMinutesChanged: (value) =>
              setState(() => _trendMinutes = value),
          onRestartService: widget.onRestartService,
        );
      },
    );
  }
}

class _DashboardInitialState extends StatelessWidget {
  const _DashboardInitialState({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.state == DashboardLoadState.authenticationRequired) {
      return AppStateView.error(
        key: const Key('dashboard-auth-required'),
        title: '需要登录',
        message: 'VNTS2 管理接口已启用认证，请先在服务运维页登录。',
        actionLabel: '立即登录',
        onAction: controller.refresh,
      );
    }
    if (controller.state == DashboardLoadState.error) {
      return AppStateView.error(
        key: const Key('dashboard-error'),
        message: controller.errorMessage ?? '本机 VNTS2 服务不可达',
        onAction: controller.refresh,
      );
    }
    return const AppStateView.loading(key: Key('dashboard-loading'));
  }
}

class _DashboardNotConnected extends StatelessWidget {
  const _DashboardNotConnected();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('仪表盘', style: theme.textTheme.headlineMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '服务健康、资源使用、流量与组网状态',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.lg),
          const Card(
            child: SizedBox(
              height: 420,
              child: AppStateView.empty(
                key: Key('dashboard-shell-empty'),
                icon: Icons.monitor_heart_outlined,
                title: '控制台壳层已就绪',
                message: '运行 Windows 版本后，这里将连接本机回环管理接口并显示真实数据。',
                iconColor: AppColors.brand,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.controller,
    required this.snapshot,
    required this.trendMinutes,
    required this.onTrendMinutesChanged,
    required this.onRestartService,
  });

  final DashboardController controller;
  final DashboardSnapshot snapshot;
  final int trendMinutes;
  final ValueChanged<int> onTrendMinutesChanged;
  final Future<void> Function()? onRestartService;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final samples = trendMinutes == 5
        ? controller.traffic5Minutes
        : controller.traffic15Minutes;
    return SingleChildScrollView(
      key: const Key('dashboard-ready'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            snapshot: snapshot,
            controller: controller,
            onRestartService: onRestartService,
          ),
          if (controller.hasStaleData) ...[
            const SizedBox(height: AppSpacing.md),
            _StaleBanner(message: controller.errorMessage ?? '数据刷新失败'),
          ],
          const SizedBox(height: AppSpacing.lg),
          _KpiGrid(snapshot: snapshot, controller: controller),
          const SizedBox(height: AppSpacing.md),
          _TrafficPanel(
            snapshot: snapshot,
            controller: controller,
            samples: samples,
            minutes: trendMinutes,
            onMinutesChanged: onTrendMinutesChanged,
          ),
          const SizedBox(height: AppSpacing.md),
          _ResourceGrid(snapshot: snapshot),
          const SizedBox(height: AppSpacing.md),
          _TopologyGrid(snapshot: snapshot),
          const SizedBox(height: AppSpacing.md),
          _ListenerAndAlertGrid(snapshot: snapshot),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '最近采样：${_formatTime(snapshot.sampledAt)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.snapshot,
    required this.controller,
    required this.onRestartService,
  });

  final DashboardSnapshot snapshot;
  final DashboardController controller;
  final Future<void> Function()? onRestartService;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.lg,
      runSpacing: AppSpacing.md,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('仪表盘', style: theme.textTheme.headlineMedium),
                const SizedBox(width: AppSpacing.sm),
                const _StatusBadge(
                  label: '服务运行中',
                  icon: Icons.check_circle_outline,
                  color: AppColors.success,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'VNTS2 ${snapshot.server.version} · ${formatUptime(snapshot.server.uptimeSeconds)}',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        Wrap(
          spacing: AppSpacing.xs,
          children: [
            IconButton.filledTonal(
              tooltip: '立即刷新',
              onPressed: controller.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            FilledButton.tonalIcon(
              onPressed: onRestartService == null
                  ? null
                  : () => _restart(context),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('重启服务'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _restart(BuildContext context) async {
    final restart = onRestartService;
    if (restart == null) return;
    try {
      await restart();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('VNTS2 服务已重启')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.snapshot, required this.controller});

  final DashboardSnapshot snapshot;
  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    final throughput =
        (controller.txBytesPerSecond == null ||
            controller.rxBytesPerSecond == null)
        ? '采样中'
        : formatBytes(
            controller.txBytesPerSecond! + controller.rxBytesPerSecond!,
            perSecond: true,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1060 ? 4 : 2;
        final width =
            (constraints.maxWidth - (columns - 1) * AppSpacing.md) / columns;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _KpiCard(
              width: width,
              label: '在线节点',
              value: '${snapshot.topology.nodesOnline}',
              detail: '共 ${snapshot.topology.nodesTotal} 个节点',
              icon: Icons.devices_rounded,
              color: AppColors.success,
            ),
            _KpiCard(
              width: width,
              label: '虚拟网络',
              value: '${snapshot.topology.networks}',
              detail: '${snapshot.topology.nodesOffline} 个离线节点',
              icon: Icons.hub_rounded,
              color: AppColors.cyan,
            ),
            _KpiCard(
              width: width,
              label: '当前总吞吐',
              value: throughput,
              detail: '实时发送 + 接收',
              icon: Icons.swap_vert_circle_outlined,
              color: AppColors.brand,
            ),
            _KpiCard(
              width: width,
              label: '运行时间',
              value: formatUptime(snapshot.server.uptimeSeconds),
              detail: snapshot.server.databaseReady ? '数据库正常' : '数据库未就绪',
              icon: Icons.timer_outlined,
              color: snapshot.server.databaseReady
                  ? AppColors.success
                  : AppColors.warning,
            ),
          ],
        );
      },
    );
  }
}

class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({
    required this.snapshot,
    required this.controller,
    required this.samples,
    required this.minutes,
    required this.onMinutesChanged,
  });

  final DashboardSnapshot snapshot;
  final DashboardController controller;
  final List<dynamic> samples;
  final int minutes;
  final ValueChanged<int> onMinutesChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('实时流量', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      '固定容量趋势，不会随运行时间增长',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 5, label: Text('5 分钟')),
                    ButtonSegment(value: 15, label: Text('15 分钟')),
                  ],
                  selected: {minutes},
                  onSelectionChanged: (value) => onMinutesChanged(value.first),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.sm,
              children: [
                _Legend(
                  color: AppColors.brand,
                  label:
                      '发送 ${formatBytes(controller.txBytesPerSecond, perSecond: true)}',
                ),
                _Legend(
                  color: AppColors.cyan,
                  label:
                      '接收 ${formatBytes(controller.rxBytesPerSecond, perSecond: true)}',
                ),
                Text('累计发送 ${formatBytes(snapshot.traffic.txBytesTotal)}'),
                Text('累计接收 ${formatBytes(snapshot.traffic.rxBytesTotal)}'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 250,
              child: TrafficTrendChart(samples: samples.cast()),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResourceGrid extends StatelessWidget {
  const _ResourceGrid({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final memoryPercent = snapshot.host.memoryTotalBytes == 0
        ? null
        : snapshot.host.memoryUsedBytes / snapshot.host.memoryTotalBytes * 100;
    final diskPercent =
        snapshot.storage.volumeTotalBytes == null ||
            snapshot.storage.volumeTotalBytes == 0 ||
            snapshot.storage.volumeUsedBytes == null
        ? null
        : snapshot.storage.volumeUsedBytes! /
              snapshot.storage.volumeTotalBytes! *
              100;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100 ? 4 : 2;
        final width =
            (constraints.maxWidth - (columns - 1) * AppSpacing.md) / columns;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _ResourceCard(
              width: width,
              title: '主机 CPU',
              value: formatPercent(snapshot.host.cpuPercent),
              progress: snapshot.host.cpuPercent,
              detail: '全系统使用率',
              icon: Icons.memory_rounded,
            ),
            _ResourceCard(
              width: width,
              title: '主机内存',
              value: formatPercent(memoryPercent),
              progress: memoryPercent,
              detail:
                  '${formatBytes(snapshot.host.memoryUsedBytes)} / ${formatBytes(snapshot.host.memoryTotalBytes)}',
              icon: Icons.storage_rounded,
            ),
            _ResourceCard(
              width: width,
              title: 'VNTS2 进程',
              value: formatBytes(snapshot.process.memoryBytes),
              progress: snapshot.process.cpuPercent,
              detail: 'CPU ${formatPercent(snapshot.process.cpuPercent)}',
              icon: Icons.developer_board_outlined,
            ),
            _ResourceCard(
              width: width,
              title: '数据卷',
              value: formatPercent(diskPercent),
              progress: diskPercent,
              detail: snapshot.storage.volumeTotalBytes == null
                  ? '不支持'
                  : '${formatBytes(snapshot.storage.volumeUsedBytes)} / ${formatBytes(snapshot.storage.volumeTotalBytes)}',
              icon: Icons.storage_outlined,
            ),
          ],
        );
      },
    );
  }
}

class _TopologyGrid extends StatelessWidget {
  const _TopologyGrid({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final width = wide
            ? (constraints.maxWidth - AppSpacing.md) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _DetailCard(
              width: width,
              title: '节点与拓扑',
              icon: Icons.account_tree_outlined,
              children: [
                _DetailRow(
                  label: 'VNT 在线',
                  value: '${snapshot.topology.vntOnline}',
                ),
                _DetailRow(
                  label: 'WireGuard 在线',
                  value: '${snapshot.topology.wireGuardOnline}',
                ),
                _DetailRow(
                  label: '离线节点',
                  value: '${snapshot.topology.nodesOffline}',
                ),
                _DetailRow(
                  label: '虚拟网络',
                  value: '${snapshot.topology.networks}',
                ),
              ],
            ),
            _DetailCard(
              width: width,
              title: '互联与 WireGuard',
              icon: Icons.security_outlined,
              children: [
                _DetailRow(
                  label: '互联服务器',
                  value:
                      '${snapshot.peerServers.connected} / ${snapshot.peerServers.total}',
                ),
                _DetailRow(
                  label: 'WireGuard 运行',
                  value: snapshot.wireGuard.running ? '正常' : '未运行',
                ),
                _DetailRow(
                  label: '活动 Peer',
                  value:
                      '${snapshot.wireGuard.activePeers} / ${snapshot.wireGuard.maxActivePeers}',
                ),
                _DetailRow(
                  label: '背压丢弃',
                  value: '${snapshot.traffic.wireGuardDropsTotal}',
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ListenerAndAlertGrid extends StatelessWidget {
  const _ListenerAndAlertGrid({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final alerts = _buildAlerts(snapshot);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final width = wide
            ? (constraints.maxWidth - AppSpacing.md) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _DetailCard(
              width: width,
              title: '监听器',
              icon: Icons.sensors_outlined,
              children: [
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final listener in snapshot.listeners.labeled.entries)
                      _StatusBadge(
                        label: listener.key,
                        icon: listener.value ? Icons.check : Icons.remove,
                        color: listener.value
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                  ],
                ),
              ],
            ),
            _DetailCard(
              width: width,
              title: '告警',
              icon: Icons.notifications_active_outlined,
              children: alerts.isEmpty
                  ? const [_DetailRow(label: '当前状态', value: '没有活动告警')]
                  : [
                      for (final alert in alerts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Row(
                            children: [
                              Icon(alert.$1, size: 18, color: alert.$3),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(child: Text(alert.$2)),
                            ],
                          ),
                        ),
                    ],
            ),
          ],
        );
      },
    );
  }
}

List<(IconData, String, Color)> _buildAlerts(DashboardSnapshot snapshot) {
  return [
    if (!snapshot.server.databaseReady)
      (Icons.storage_outlined, '数据库尚未就绪', AppColors.danger),
    if (snapshot.wireGuard.configured && !snapshot.wireGuard.running)
      (Icons.shield_outlined, 'WireGuard 已配置但未运行', AppColors.warning),
    if (snapshot.peerServers.enabled &&
        snapshot.peerServers.connected < snapshot.peerServers.total)
      (Icons.dns_outlined, '部分互联服务器未连接', AppColors.warning),
    if (snapshot.traffic.wireGuardDropsTotal > 0)
      (
        Icons.warning_amber_rounded,
        'WireGuard 背压丢弃 ${snapshot.traffic.wireGuardDropsTotal} 次',
        AppColors.warning,
      ),
  ];
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.width,
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final double width;
  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 21),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(value, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                detail,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.width,
    required this.title,
    required this.value,
    required this.progress,
    required this.detail,
    required this.icon,
  });

  final double width;
  final String title;
  final String value;
  final double? progress;
  final String detail;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = progress == null
        ? null
        : (progress! / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: AppColors.brand),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(value, style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              LinearProgressIndicator(value: normalized),
              const SizedBox(height: AppSpacing.sm),
              Text(
                detail,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.width,
    required this.title,
    required this.icon,
    required this.children,
  });

  final double width;
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: AppColors.brand),
                  const SizedBox(width: AppSpacing.sm),
                  Text(title, style: theme.textTheme.titleLarge),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label),
      ],
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text('显示上次有效数据：$message')),
        ],
      ),
    );
  }
}

String _formatTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

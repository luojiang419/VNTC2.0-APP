import 'package:flutter/material.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../controller/network_management_controller.dart';
import '../data/network_repository.dart';
import '../domain/network_models.dart';

class NetworkManagementPage extends StatefulWidget {
  const NetworkManagementPage({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<NetworkManagementPage> createState() => _NetworkManagementPageState();
}

class _NetworkManagementPageState extends State<NetworkManagementPage> {
  late final NetworkManagementController controller;

  @override
  void initState() {
    super.initState();
    controller = NetworkManagementController(
      widget.apiClient == null ? null : NetworkRepository(widget.apiClient!),
    )..load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        key: const Key('network-management-page'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              busy: controller.mutating,
              onRefresh: controller.load,
              onCreate: () => _openEditor(),
            ),
            const SizedBox(height: AppSpacing.lg),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (controller.loading) return const Card(child: AppStateView.loading());
    if (controller.error != null && controller.networks.isEmpty) {
      return Card(
        child: AppStateView.error(
          message: controller.error!,
          onAction: controller.load,
        ),
      );
    }
    if (controller.networks.isEmpty) {
      return Card(
        child: AppStateView.empty(
          icon: Icons.hub_outlined,
          title: '尚未创建虚拟网络',
          message: '创建首个网络后即可接入设备与 WireGuard Peer。',
          iconColor: AppColors.brand,
          actionLabel: '创建网络',
          onAction: _openEditor,
        ),
      );
    }
    return ListView.separated(
      itemCount: controller.networks.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final network = controller.networks[index];
        return _NetworkCard(
          network: network,
          disabled: controller.mutating,
          onEdit: () => _openEditor(network),
          onDelete: () => _confirmDelete(network),
        );
      },
    );
  }

  Future<void> _openEditor([NetworkInfo? network]) async {
    final result = await showDialog<_NetworkDraft>(
      context: context,
      builder: (context) => _NetworkEditorDialog(network: network),
    );
    if (result == null) return;
    try {
      if (network == null) {
        await controller.create(
          code: result.code,
          gateway: result.gateway,
          netmask: result.netmask,
          leaseDurationSeconds: result.leaseDurationSeconds,
        );
      } else {
        await controller.update(
          code: network.code,
          gateway: result.gateway,
          netmask: result.netmask,
          leaseDurationSeconds: result.leaseDurationSeconds,
        );
      }
    } on ApiException catch (exception) {
      if (mounted) _showError(exception.message);
    }
  }

  Future<void> _confirmDelete(NetworkInfo network) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除网络'),
        content: Text('确定删除 ${network.code}？网络内的关联配置可能同时失效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.delete(network.code);
    } on ApiException catch (exception) {
      if (mounted) _showError(exception.message);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.busy,
    required this.onRefresh,
    required this.onCreate,
  });

  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('网络', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '创建和维护虚拟网络、地址池与租约策略',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: busy ? null : onRefresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: AppSpacing.xs),
        FilledButton.icon(
          onPressed: busy ? null : onCreate,
          icon: const Icon(Icons.add_rounded),
          label: const Text('创建网络'),
        ),
      ],
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({
    required this.network,
    required this.disabled,
    required this.onEdit,
    required this.onDelete,
  });

  final NetworkInfo network;
  final bool disabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.brand.withValues(alpha: 0.14),
              foregroundColor: AppColors.brand,
              child: const Icon(Icons.hub_outlined),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(network.code, style: theme.textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.lg,
                    runSpacing: AppSpacing.xs,
                    children: [
                      Text('网段 ${network.network}'),
                      Text('网关 ${network.gateway}/${network.netmask}'),
                      Text('租约 ${_duration(network.leaseDurationSeconds)}'),
                      Text(
                        '设备 ${network.onlineDevices}/${network.totalDevices} 在线',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '编辑',
              onPressed: disabled ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: disabled ? null : onDelete,
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(int seconds) {
    if (seconds % 86400 == 0) return '${seconds ~/ 86400} 天';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600} 小时';
    return '$seconds 秒';
  }
}

class _NetworkDraft {
  const _NetworkDraft({
    required this.code,
    required this.gateway,
    required this.netmask,
    required this.leaseDurationSeconds,
  });

  final String code;
  final String gateway;
  final int netmask;
  final int leaseDurationSeconds;
}

class _NetworkEditorDialog extends StatefulWidget {
  const _NetworkEditorDialog({this.network});

  final NetworkInfo? network;

  @override
  State<_NetworkEditorDialog> createState() => _NetworkEditorDialogState();
}

class _NetworkEditorDialogState extends State<_NetworkEditorDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController code;
  late final TextEditingController gateway;
  late final TextEditingController netmask;
  late final TextEditingController lease;

  @override
  void initState() {
    super.initState();
    final network = widget.network;
    code = TextEditingController(text: network?.code ?? '');
    gateway = TextEditingController(text: network?.gateway ?? '10.26.0.1');
    netmask = TextEditingController(text: '${network?.netmask ?? 24}');
    lease = TextEditingController(
      text: '${network?.leaseDurationSeconds ?? 86400}',
    );
  }

  @override
  void dispose() {
    code.dispose();
    gateway.dispose();
    netmask.dispose();
    lease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.network == null ? '创建网络' : '编辑网络'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: code,
                enabled: widget.network == null,
                decoration: const InputDecoration(labelText: '网络编号'),
                validator: _required,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: gateway,
                decoration: const InputDecoration(labelText: 'IPv4 网关'),
                validator: (value) => _isIpv4(value) ? null : '请输入有效 IPv4 地址',
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: netmask,
                decoration: const InputDecoration(labelText: 'CIDR 掩码（0-32）'),
                validator: (value) {
                  final parsed = int.tryParse(value ?? '');
                  return parsed != null && parsed >= 0 && parsed <= 32
                      ? null
                      : '请输入 0 至 32';
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: lease,
                decoration: const InputDecoration(labelText: '租约时长（秒）'),
                validator: (value) {
                  final parsed = int.tryParse(value ?? '');
                  return parsed != null && parsed > 0 ? null : '请输入大于 0 的秒数';
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _NetworkDraft(
                code: code.text.trim(),
                gateway: gateway.text.trim(),
                netmask: int.parse(netmask.text),
                leaseDurationSeconds: int.parse(lease.text),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  static String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '不能为空' : null;
  }

  static bool _isIpv4(String? value) {
    final parts = value?.split('.') ?? const [];
    return parts.length == 4 &&
        parts.every((part) {
          final number = int.tryParse(part);
          return number != null && number >= 0 && number <= 255;
        });
  }
}

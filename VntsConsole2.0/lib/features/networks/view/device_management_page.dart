import 'package:flutter/material.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../../dashboard/view/dashboard_formatters.dart';
import '../controller/network_management_controller.dart';
import '../data/network_repository.dart';
import '../domain/network_models.dart';

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  late final DeviceManagementController controller;

  @override
  void initState() {
    super.initState();
    controller = DeviceManagementController(
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
        key: const Key('device-management-page'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '设备',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '查看虚拟节点在线状态、链路与累计流量',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.networks.isNotEmpty)
                  SizedBox(
                    width: 220,
                    child: DropdownButtonFormField<String>(
                      key: const Key('device-network-selector'),
                      initialValue: controller.selectedNetwork,
                      decoration: const InputDecoration(labelText: '虚拟网络'),
                      items: controller.networks
                          .map(
                            (network) => DropdownMenuItem(
                              value: network.code,
                              child: Text(network.code),
                            ),
                          )
                          .toList(),
                      onChanged: controller.loading || controller.mutating
                          ? null
                          : (value) {
                              if (value != null) {
                                controller.selectNetwork(value);
                              }
                            },
                    ),
                  ),
                const SizedBox(width: AppSpacing.xs),
                IconButton(
                  tooltip: '刷新',
                  onPressed: controller.loading ? null : controller.load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
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
    if (controller.error != null && controller.devices.isEmpty) {
      return Card(
        child: AppStateView.error(
          message: controller.error!,
          onAction: controller.load,
        ),
      );
    }
    if (controller.networks.isEmpty) {
      return const Card(
        child: AppStateView.empty(
          icon: Icons.hub_outlined,
          title: '尚无可用网络',
          message: '请先在网络页面创建虚拟网络。',
          iconColor: AppColors.brand,
        ),
      );
    }
    if (controller.devices.isEmpty) {
      return const Card(
        child: AppStateView.empty(
          icon: Icons.devices_other_outlined,
          title: '当前网络没有设备',
          message: '设备首次成功接入后会显示在这里。',
          iconColor: AppColors.brand,
        ),
      );
    }
    return ListView.separated(
      itemCount: controller.devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final device = controller.devices[index];
        return _DeviceCard(
          device: device,
          disabled: controller.mutating,
          onDelete: () => _confirmDelete(device),
        );
      },
    );
  }

  Future<void> _confirmDelete(DeviceInfo device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除设备'),
        content: Text('确定从当前网络移除 ${device.name}（${device.id}）？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.deleteDevice(device.id);
    } on ApiException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    }
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.disabled,
    required this.onDelete,
  });

  final DeviceInfo device;
  final bool disabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = device.isOnline
        ? AppColors.success
        : theme.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Icon(Icons.circle, size: 12, color: statusColor),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          device.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        device.isOnline ? '在线' : '离线',
                        style: TextStyle(color: statusColor),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.lg,
                    runSpacing: AppSpacing.xs,
                    children: [
                      Text(device.ip ?? '未分配 IP'),
                      Text('ID ${device.id}'),
                      Text('版本 ${device.version}'),
                      Text(
                        device.latencyMs == null
                            ? '延迟 --'
                            : '延迟 ${device.latencyMs} ms',
                      ),
                      Text(
                        '↑ ${formatBytes(device.txBytes)}  ↓ ${formatBytes(device.rxBytes)}',
                      ),
                      if (device.serverAddress != null)
                        Text('服务端 ${device.serverAddress}'),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '移除设备',
              onPressed: disabled ? null : onDelete,
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
            ),
          ],
        ),
      ),
    );
  }
}

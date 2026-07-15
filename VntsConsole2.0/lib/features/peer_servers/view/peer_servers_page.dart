import 'package:flutter/material.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../controller/peer_server_controller.dart';
import '../data/peer_server_repository.dart';
import '../domain/peer_server_models.dart';

class PeerServersPage extends StatefulWidget {
  const PeerServersPage({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<PeerServersPage> createState() => _PeerServersPageState();
}

class _PeerServersPageState extends State<PeerServersPage> {
  late final PeerServerController controller;

  @override
  void initState() {
    super.initState();
    controller = PeerServerController(
      widget.apiClient == null ? null : PeerServerRepository(widget.apiClient!),
    )..load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        key: const Key('peer-servers-page'),
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
                      Text('互联服务器', style: theme.textTheme.headlineMedium),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '管理跨服务端出站连接，并查看入站连接、延迟与健康状态',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: controller.loading ? null : controller.load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: AppSpacing.xs),
                FilledButton.icon(
                  key: const Key('add-peer-server'),
                  onPressed: controller.mutating ? null : _add,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('添加出站服务器'),
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
    if (controller.error != null && controller.snapshot.all.isEmpty) {
      return Card(
        child: AppStateView.error(
          message: controller.error!,
          onAction: controller.load,
        ),
      );
    }
    if (controller.snapshot.all.isEmpty) {
      return Card(
        child: AppStateView.empty(
          icon: Icons.dns_outlined,
          title: '当前没有互联连接',
          message: '添加另一台 VNTS2 服务端的可达地址以建立跨服务端互联。',
          iconColor: AppColors.brand,
          actionLabel: '添加服务器',
          onAction: _add,
        ),
      );
    }
    return ListView(
      children: [
        _groupTitle('出站连接', controller.snapshot.outbound.length),
        const SizedBox(height: AppSpacing.sm),
        for (final server in controller.snapshot.outbound) ...[
          _ServerCard(
            server: server,
            disabled: controller.mutating,
            onDelete: () => _delete(server),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        const SizedBox(height: AppSpacing.md),
        _groupTitle('入站连接（只读）', controller.snapshot.inbound.length),
        const SizedBox(height: AppSpacing.sm),
        for (final server in controller.snapshot.inbound) ...[
          _ServerCard(server: server, disabled: true),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }

  Widget _groupTitle(String title, int count) {
    return Text(
      '$title  $count',
      style: Theme.of(context).textTheme.titleMedium,
    );
  }

  Future<void> _add() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (address == null) return;
    await _run(() => controller.add(address), '互联服务器已添加');
  }

  Future<void> _delete(PeerServerInfo server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除出站服务器'),
        content: Text('确定删除 ${server.address}？现有连接将被断开。'),
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
    if (confirmed == true) {
      await _run(() => controller.delete(server.address), '互联服务器已删除');
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (mounted) _message(success);
    } on ApiException catch (exception) {
      if (mounted) _message(exception.message);
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.disabled,
    this.onDelete,
  });

  final PeerServerInfo server;
  final bool disabled;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = server.connected
        ? AppColors.success
        : theme.colorScheme.error;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          foregroundColor: color,
          child: Icon(
            server.outbound
                ? Icons.call_made_rounded
                : Icons.call_received_rounded,
          ),
        ),
        title: Text(server.address),
        subtitle: Text(
          '${server.connected ? '已连接' : '未连接'} · '
          '${server.latencyMs == 0 ? '延迟 --' : '延迟 ${server.latencyMs} ms'} · '
          '${server.outbound ? '出站' : '入站'}',
        ),
        trailing: onDelete == null
            ? null
            : IconButton(
                tooltip: '删除',
                onPressed: disabled ? null : onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.error,
                ),
              ),
      ),
    );
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final formKey = GlobalKey<FormState>();
  final address = TextEditingController();

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加出站互联服务器'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: formKey,
          child: TextFormField(
            controller: address,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'example.com:29873',
            ),
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) return '不能为空';
              if (!text.contains(':')) return '请包含端口号';
              return null;
            },
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
            if (formKey.currentState!.validate()) {
              Navigator.pop(context, address.text.trim());
            }
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

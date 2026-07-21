import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../core/networking/api_exception.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../controller/wireguard_controller.dart';
import '../data/wireguard_repository.dart';
import '../domain/wireguard_models.dart';

class WireGuardPage extends StatefulWidget {
  const WireGuardPage({super.key, this.apiClient});

  final ApiClient? apiClient;

  @override
  State<WireGuardPage> createState() => _WireGuardPageState();
}

class _WireGuardPageState extends State<WireGuardPage> {
  late final WireGuardController controller;

  @override
  void initState() {
    super.initState();
    controller = WireGuardController(
      widget.apiClient == null ? null : WireGuardRepository(widget.apiClient!),
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
        key: const Key('wireguard-page'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: AppSpacing.lg),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('WireGuard', style: theme.textTheme.headlineMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '管理 Peer 在线状态、DNS、局域网路由与客户端配置',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (controller.networks.isNotEmpty)
          SizedBox(
            width: 210,
            child: DropdownButtonFormField<String>(
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
        const SizedBox(width: AppSpacing.xs),
        OutlinedButton.icon(
          onPressed: _canWrite ? _createWithPublicKey : null,
          icon: const Icon(Icons.key_outlined),
          label: const Text('导入公钥'),
        ),
        const SizedBox(width: AppSpacing.xs),
        FilledButton.icon(
          key: const Key('generate-wireguard-peer'),
          onPressed: _canWrite ? _generate : null,
          icon: const Icon(Icons.qr_code_2_rounded),
          label: const Text('生成配置'),
        ),
      ],
    );
  }

  bool get _canWrite =>
      controller.selectedNetwork != null && !controller.mutating;

  Widget _body() {
    if (controller.loading) return const Card(child: AppStateView.loading());
    if (controller.error != null && controller.peers.isEmpty) {
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
          message: '创建虚拟网络后才能添加 WireGuard Peer。',
          iconColor: AppColors.brand,
        ),
      );
    }
    if (controller.peers.isEmpty) {
      return Card(
        child: AppStateView.empty(
          icon: Icons.shield_outlined,
          title: '当前网络没有 Peer',
          message: '可导入已有公钥，或生成含一次性私钥的客户端配置。',
          iconColor: AppColors.brand,
          actionLabel: '生成配置',
          onAction: _generate,
        ),
      );
    }
    return ListView.separated(
      itemCount: controller.peers.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final peer = controller.peers[index];
        return _PeerCard(
          peer: peer,
          disabled: controller.mutating,
          onEnabledChanged: (value) => _run(
            () => controller.setEnabled(peer, value),
            value ? 'Peer 已启用' : 'Peer 已停用',
          ),
          onReserveIp: () => _reserveIp(peer),
          onEditProfile: () => _editProfile(peer),
          onDownloadConfig: peer.configAvailable
              ? () => _downloadConfig(peer)
              : null,
          onReleaseIp: peer.ip == null
              ? null
              : () => _run(() => controller.releaseIp(peer), 'IP 预留已释放'),
          onDelete: () => _delete(peer),
        );
      },
    );
  }

  Future<void> _createWithPublicKey() async {
    final draft = await showDialog<_PeerDraft>(
      context: context,
      builder: (_) => const _PeerDialog(withPublicKey: true),
    );
    if (draft == null) return;
    await _run(
      () => controller.createPeer(
        peerId: draft.peerId,
        publicKey: draft.publicKey!,
        profile: draft.profile,
      ),
      'Peer 已创建',
    );
  }

  Future<void> _generate() async {
    final draft = await showDialog<_PeerDraft>(
      context: context,
      builder: (_) => const _PeerDialog(withPublicKey: false),
    );
    if (draft == null) return;
    try {
      final generated = await controller.generatePeer(
        draft.peerId,
        draft.profile,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _GeneratedConfigDialog(config: generated, oneTime: true),
      );
    } on ApiException catch (exception) {
      if (mounted) _message(exception.message);
    }
  }

  Future<void> _editProfile(WireGuardPeer peer) async {
    final draft = await showDialog<_PeerDraft>(
      context: context,
      builder: (_) => _PeerDialog(withPublicKey: false, peer: peer),
    );
    if (draft == null) return;
    await _run(
      () => controller.updateProfile(peer, draft.profile),
      'Peer 配置已更新，现有会话已重新握手',
    );
  }

  Future<void> _downloadConfig(WireGuardPeer peer) async {
    try {
      final config = await controller.getPeerConfig(peer);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _GeneratedConfigDialog(config: config, oneTime: false),
      );
    } on ApiException catch (exception) {
      if (mounted) _message(exception.message);
    }
  }

  Future<void> _reserveIp(WireGuardPeer peer) async {
    final ip = await showDialog<String>(
      context: context,
      builder: (_) => _IpDialog(peer: peer),
    );
    if (ip == null) return;
    await _run(() => controller.reserveIp(peer, ip), 'IP 预留已更新');
  }

  Future<void> _delete(WireGuardPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Peer'),
        content: Text('确定删除 ${peer.peerId}？关联 IP 预留也会释放。'),
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
      await _run(() => controller.deletePeer(peer), 'Peer 已删除');
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

class _PeerCard extends StatelessWidget {
  const _PeerCard({
    required this.peer,
    required this.disabled,
    required this.onEnabledChanged,
    required this.onReserveIp,
    required this.onEditProfile,
    required this.onDownloadConfig,
    required this.onReleaseIp,
    required this.onDelete,
  });

  final WireGuardPeer peer;
  final bool disabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onReserveIp;
  final VoidCallback onEditProfile;
  final VoidCallback? onDownloadConfig;
  final VoidCallback? onReleaseIp;
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
              backgroundColor: AppColors.cyan.withValues(alpha: 0.14),
              foregroundColor: AppColors.cyan,
              child: const Icon(Icons.shield_outlined),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(peer.peerId, style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    peer.publicKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(peer.ip == null ? '未预留 IP' : '预留 IP ${peer.ip}'),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          peer.online ? Icons.circle : Icons.circle_outlined,
                          size: 12,
                        ),
                        label: Text(_statusLabel(peer.status)),
                      ),
                      Text(
                        'DNS ${peer.dnsServers.isEmpty ? '未配置' : peer.dnsServers.join(', ')}${peer.dnsInherited ? '（继承）' : ''}',
                      ),
                      Text('Keepalive ${peer.persistentKeepalive} 秒'),
                      Text('局域网路由 ${peer.routes.length} 条'),
                      Text(peer.configAvailable ? '客户端配置可下载' : '仅保存公钥'),
                    ],
                  ),
                ],
              ),
            ),
            Switch(
              value: peer.enabled,
              onChanged: disabled ? null : onEnabledChanged,
            ),
            PopupMenuButton<String>(
              enabled: !disabled,
              onSelected: (value) {
                switch (value) {
                  case 'reserve':
                    onReserveIp();
                  case 'release':
                    onReleaseIp?.call();
                  case 'profile':
                    onEditProfile();
                  case 'download':
                    onDownloadConfig?.call();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'reserve', child: Text('预留/更改 IP')),
                const PopupMenuItem(
                  value: 'profile',
                  child: Text('编辑 DNS / 路由'),
                ),
                if (onDownloadConfig != null)
                  const PopupMenuItem(
                    value: 'download',
                    child: Text('下载客户端配置'),
                  ),
                if (onReleaseIp != null)
                  const PopupMenuItem(value: 'release', child: Text('释放 IP')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    '删除 Peer',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    'online' => '在线',
    'offline' => '离线',
    'disabled' => '已禁用',
    'unassigned' => '未分配 IP',
    _ => '未知',
  };
}

class _PeerDraft {
  const _PeerDraft(this.peerId, this.publicKey, this.profile);

  final String peerId;
  final String? publicKey;
  final WireGuardPeerProfile profile;
}

class _PeerDialog extends StatefulWidget {
  const _PeerDialog({required this.withPublicKey, this.peer});

  final bool withPublicKey;
  final WireGuardPeer? peer;

  @override
  State<_PeerDialog> createState() => _PeerDialogState();
}

class _PeerDialogState extends State<_PeerDialog> {
  final formKey = GlobalKey<FormState>();
  final peerId = TextEditingController();
  final publicKey = TextEditingController();
  final dnsServers = TextEditingController();
  final persistentKeepalive = TextEditingController(text: '25');
  final routes = TextEditingController();
  bool dnsInherited = true;

  @override
  void initState() {
    super.initState();
    final peer = widget.peer;
    if (peer == null) return;
    peerId.text = peer.peerId;
    publicKey.text = peer.publicKey;
    dnsInherited = peer.dnsInherited;
    dnsServers.text = peer.dnsServers.join(', ');
    persistentKeepalive.text = peer.persistentKeepalive.toString();
    routes.text = peer.routes
        .map((route) => '${route.lanNetwork} -> ${route.vntClientIp}')
        .join('\n');
  }

  @override
  void dispose() {
    peerId.dispose();
    publicKey.dispose();
    dnsServers.dispose();
    persistentKeepalive.dispose();
    routes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.peer != null
            ? '编辑 Peer DNS / 路由'
            : (widget.withPublicKey ? '导入 Peer 公钥' : '生成客户端配置'),
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: peerId,
                autofocus: true,
                enabled: widget.peer == null,
                decoration: const InputDecoration(labelText: 'Peer ID'),
                validator: _required,
              ),
              if (widget.withPublicKey && widget.peer == null) ...[
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: publicKey,
                  decoration: const InputDecoration(
                    labelText: 'WireGuard 公钥（标准 Base64）',
                  ),
                  validator: _required,
                ),
              ],
              if (!widget.withPublicKey && widget.peer == null) ...[
                const SizedBox(height: AppSpacing.md),
                const Text('客户端私钥会由服务端主密钥加密保存，下一步请立即下载或扫码导入。'),
              ],
              const SizedBox(height: AppSpacing.md),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: dnsInherited,
                title: const Text('继承服务端全局 DNS'),
                onChanged: (value) =>
                    setState(() => dnsInherited = value ?? true),
              ),
              if (!dnsInherited)
                TextFormField(
                  controller: dnsServers,
                  decoration: const InputDecoration(
                    labelText: 'DNS（逗号或空格分隔，最多 4 个）',
                  ),
                  validator: _validateDns,
                ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: persistentKeepalive,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PersistentKeepalive（秒）',
                ),
                validator: _validateKeepalive,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: routes,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Peer 后方局域网路由',
                  hintText: '每行一条：192.168.10.0/24 -> 10.26.0.10',
                ),
                validator: _validateRoutes,
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
              _PeerDraft(
                peerId.text.trim(),
                widget.withPublicKey && widget.peer == null
                    ? publicKey.text.trim()
                    : null,
                WireGuardPeerProfile(
                  dnsServers: dnsInherited
                      ? null
                      : dnsServers.text
                            .split(RegExp(r'[\s,]+'))
                            .where((value) => value.isNotEmpty)
                            .toList(growable: false),
                  persistentKeepalive: int.parse(
                    persistentKeepalive.text.trim(),
                  ),
                  routes: _parseRoutes(routes.text),
                ),
              ),
            );
          },
          child: Text(
            widget.peer != null ? '保存' : (widget.withPublicKey ? '创建' : '生成'),
          ),
        ),
      ],
    );
  }

  static String? _required(String? value) {
    return value == null || value.trim().isEmpty ? '不能为空' : null;
  }

  static String? _validateDns(String? value) {
    final values = (value ?? '')
        .split(RegExp(r'[\s,]+'))
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return values.length > 4 ? '最多填写 4 个 DNS 地址' : null;
  }

  static String? _validateKeepalive(String? value) {
    final number = int.tryParse(value?.trim() ?? '');
    if (number == null || number < 0 || number > 65535) {
      return '请输入 0 到 65535 之间的整数';
    }
    return null;
  }

  static String? _validateRoutes(String? value) {
    try {
      _parseRoutes(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  static List<WireGuardRoute> _parseRoutes(String value) {
    final result = <WireGuardRoute>[];
    final lines = value.split(RegExp(r'\r?\n'));
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s*(?:->|,|\s+)\s*'))
        ..removeWhere((part) => part.isEmpty);
      if (parts.length != 2) {
        throw FormatException('第 ${index + 1} 行格式应为“CIDR -> VNT 客户端 IP”');
      }
      result.add(WireGuardRoute(lanNetwork: parts[0], vntClientIp: parts[1]));
    }
    return result;
  }
}

class _IpDialog extends StatefulWidget {
  const _IpDialog({required this.peer});

  final WireGuardPeer peer;

  @override
  State<_IpDialog> createState() => _IpDialogState();
}

class _IpDialogState extends State<_IpDialog> {
  final formKey = GlobalKey<FormState>();
  late final TextEditingController ip;

  @override
  void initState() {
    super.initState();
    ip = TextEditingController(text: widget.peer.ip);
  }

  @override
  void dispose() {
    ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('为 ${widget.peer.peerId} 预留 IP'),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: ip,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'IPv4 地址'),
          validator: (value) => _isIpv4(value) ? null : '请输入有效 IPv4 地址',
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
              Navigator.pop(context, ip.text.trim());
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
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

class _GeneratedConfigDialog extends StatelessWidget {
  const _GeneratedConfigDialog({required this.config, required this.oneTime});

  final GeneratedWireGuardConfig config;
  final bool oneTime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(oneTime ? '新建客户端配置' : '客户端配置'),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: QrImageView(
                  data: config.clientConfig,
                  version: QrVersions.auto,
                  size: 240,
                  eyeStyle: const QrEyeStyle(color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              constraints: const BoxConstraints(maxHeight: 230),
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppSpacing.controlRadius),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  config.clientConfig,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              oneTime ? '请立即复制或扫描，并妥善保管客户端私钥。' : '此配置来自服务端主密钥加密存储，请仅在可信设备上导入。',
              style: TextStyle(
                color: oneTime
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: config.clientConfig));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('配置已复制到剪贴板')));
            }
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('复制配置'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(oneTime ? '我已安全保存' : '关闭'),
        ),
      ],
    );
  }
}

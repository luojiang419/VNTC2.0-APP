import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/networking/api_client.dart';
import '../../../core/platform/portable_layout.dart';
import '../../../core/platform/service_operations.dart';
import '../../../shared/widgets/admin_credentials_dialog.dart';
import '../../settings/data/server_config_repository.dart';
import '../controller/service_control_controller.dart';

class ServiceControlPage extends StatefulWidget {
  const ServiceControlPage({
    super.key,
    this.operations,
    this.apiClient,
    this.layout,
    this.controller,
    this.onConnectionChanged,
    this.adminUsername = 'admin',
    this.onLock,
    this.onChangeAdminCredentials,
  });

  final ServiceOperations? operations;
  final ApiClient? apiClient;
  final PortableLayout? layout;
  final ServiceControlController? controller;
  final ValueChanged<ServiceConnectionStatus>? onConnectionChanged;
  final String adminUsername;
  final VoidCallback? onLock;
  final Future<bool> Function(String username, String password)?
  onChangeAdminCredentials;

  @override
  State<ServiceControlPage> createState() => _ServiceControlPageState();
}

class _ServiceControlPageState extends State<ServiceControlPage> {
  late final ServiceControlController _controller;
  late final bool _ownsController;
  final _updateSource = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        ServiceControlController(
          operations: widget.operations,
          apiClient: widget.apiClient,
          configRepository: widget.layout == null
              ? null
              : ServerConfigRepository(widget.layout!.config),
        );
    _controller.addListener(_relayConnectionStatus);
    _controller.refreshStatus();
  }

  void _relayConnectionStatus() {
    final status = switch (_controller.authState) {
      AuthSessionState.authenticated => ServiceConnectionStatus.running,
      AuthSessionState.error => ServiceConnectionStatus.authenticationRequired,
      AuthSessionState.loggedOut || AuthSessionState.authenticating =>
        _controller.serviceStatus?.isRunning == false
            ? ServiceConnectionStatus.unreachable
            : ServiceConnectionStatus.unknown,
    };
    widget.onConnectionChanged?.call(status);
  }

  @override
  void dispose() {
    _controller.removeListener(_relayConnectionStatus);
    if (_ownsController) _controller.dispose();
    _updateSource.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        return SingleChildScrollView(
          key: const Key('service-control-page'),
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
                        Text('服务运维', style: theme.textTheme.headlineMedium),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '复用便携目录与已验证 PowerShell 脚本',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: '刷新服务状态',
                    onPressed: _controller.busy
                        ? null
                        : _controller.refreshStatus,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              if (_controller.message != null) ...[
                const SizedBox(height: AppSpacing.md),
                _MessageBanner(
                  message: _controller.message!,
                  details: _controller.errorDetails,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              _ServiceStatusCard(controller: _controller),
              const SizedBox(height: AppSpacing.md),
              _ServiceActions(
                controller: _controller,
                updateSource: _updateSource,
                onAction: _runAction,
              ),
              const SizedBox(height: AppSpacing.md),
              _LoginCard(
                controller: _controller,
                adminUsername: widget.adminUsername,
                onLock: widget.onLock,
                onChangeCredentials: widget.onChangeAdminCredentials == null
                    ? null
                    : _changeAdminCredentials,
              ),
              if (_controller.diagnostics.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _DiagnosticsCard(checks: _controller.diagnostics),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _runAction(ServiceAction action) async {
    if (action == ServiceAction.uninstall) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('卸载 Windows 服务？'),
          content: const Text('服务注册将被删除，但配置、数据库、密钥、日志和备份数据会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认卸载'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _controller.runAction(
      action,
      updateSource: action == ServiceAction.update ? _updateSource.text : null,
    );
  }

  Future<void> _changeAdminCredentials() async {
    final credentials = await showAdminCredentialsDialog(
      context,
      currentUsername: widget.adminUsername,
    );
    if (credentials == null || !mounted) return;
    await widget.onChangeAdminCredentials!(
      credentials.username,
      credentials.password,
    );
  }
}

class _ServiceStatusCard extends StatelessWidget {
  const _ServiceStatusCard({required this.controller});

  final ServiceControlController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = controller.serviceStatus;
    final installed = status?.installed == true;
    final running = status?.isRunning == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StatusIcon(
              icon: running
                  ? Icons.play_circle_outline
                  : Icons.stop_circle_outlined,
              color: running ? AppColors.success : AppColors.warning,
            ),
            SizedBox(
              width: 230,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    !controller.scriptsAvailable
                        ? '运维脚本不可用'
                        : !installed
                        ? '服务未安装'
                        : running
                        ? '服务运行中'
                        : '服务已停止',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status == null
                        ? '请从完整增强版发布目录运行'
                        : '状态 ${status.state} · PID ${status.processId}',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            _InfoValue(
              label: '便携布局',
              value: status?.portableLayout == true ? '已验证' : '待验证',
            ),
            _InfoValue(label: '数据策略', value: '卸载时保留'),
            _InfoValue(label: '权限', value: '管理员'),
          ],
        ),
      ),
    );
  }
}

class _ServiceActions extends StatelessWidget {
  const _ServiceActions({
    required this.controller,
    required this.updateSource,
    required this.onAction,
  });

  final ServiceControlController controller;
  final TextEditingController updateSource;
  final ValueChanged<ServiceAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = controller.scriptsAvailable && !controller.busy;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('服务操作', style: theme.textTheme.titleLarge),
                if (controller.busy) ...[
                  const SizedBox(width: AppSpacing.md),
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _ActionButton(
                  label: '安装',
                  icon: Icons.install_desktop_outlined,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.install)
                      : null,
                ),
                _ActionButton(
                  label: '启动',
                  icon: Icons.play_arrow_rounded,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.start)
                      : null,
                ),
                _ActionButton(
                  label: '停止',
                  icon: Icons.stop_rounded,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.stop)
                      : null,
                ),
                _ActionButton(
                  label: '重启',
                  icon: Icons.restart_alt_rounded,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.restart)
                      : null,
                ),
                _ActionButton(
                  label: '诊断',
                  icon: Icons.health_and_safety_outlined,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.diagnose)
                      : null,
                ),
                _ActionButton(
                  label: '卸载',
                  icon: Icons.delete_outline_rounded,
                  onPressed: enabled
                      ? () => onAction(ServiceAction.uninstall)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const Key('update-source-field'),
              controller: updateSource,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: '更新源 vnts2.exe 完整路径',
                hintText: r'D:\Downloads\vnts2.exe',
                suffixIcon: IconButton(
                  tooltip: '执行安全更新',
                  onPressed: enabled
                      ? () => onAction(ServiceAction.update)
                      : null,
                  icon: const Icon(Icons.system_update_alt_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.controller,
    required this.adminUsername,
    required this.onLock,
    required this.onChangeCredentials,
  });

  final ServiceControlController controller;
  final String adminUsername;
  final VoidCallback? onLock;
  final VoidCallback? onChangeCredentials;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  color: AppColors.success,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('管理员与隐私保护', style: theme.textTheme.titleLarge),
                ),
                const Text('已通过全局门禁'),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '当前管理员：$adminUsername。Cookie 与 CSRF 仅保留在当前进程内存；锁定后全部业务页面会立即隐藏。',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (onChangeCredentials != null)
                  OutlinedButton.icon(
                    key: const Key('change-admin-credentials-service'),
                    onPressed: controller.busy ? null : onChangeCredentials,
                    icon: const Icon(Icons.manage_accounts_outlined),
                    label: const Text('修改管理员凭据'),
                  ),
                if (onLock != null)
                  FilledButton.tonalIcon(
                    key: const Key('lock-console-service'),
                    onPressed: onLock,
                    icon: const Icon(Icons.lock_outline_rounded),
                    label: const Text('立即锁定'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.checks});

  final List<DiagnosticCheck> checks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('诊断结果', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            for (final check in checks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  check.status == 'PASS'
                      ? Icons.check_circle_outline
                      : check.status == 'FAIL'
                      ? Icons.error_outline
                      : Icons.warning_amber_rounded,
                  color: check.status == 'PASS'
                      ? AppColors.success
                      : check.status == 'FAIL'
                      ? AppColors.danger
                      : AppColors.warning,
                ),
                title: Text(check.name),
                subtitle: SelectableText(check.details),
                trailing: Text(check.status),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(icon, color: color, size: 30),
    );
  }
}

class _InfoValue extends StatelessWidget {
  const _InfoValue({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, this.details});
  final String message;
  final String? details;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (details != null && details!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            SelectableText(
              details!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

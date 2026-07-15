import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/platform/portable_layout.dart';
import '../../../core/platform/service_operations.dart';
import '../../../core/platform/desktop_behavior.dart';
import '../../../core/security/console_lock_shortcut.dart';
import '../../../shared/widgets/admin_credentials_dialog.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../controller/server_config_controller.dart';
import '../data/server_config_repository.dart';
import '../domain/server_config_settings.dart';

class SettingsShellPage extends StatelessWidget {
  const SettingsShellPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.dashboardPollSeconds,
    required this.onDashboardPollSecondsChanged,
    required this.autoLockHours,
    required this.onAutoLockHoursChanged,
    required this.lockShortcut,
    required this.onLockShortcutChanged,
    required this.adminUsername,
    required this.onChangeAdminCredentials,
    required this.onLock,
    required this.closeBehavior,
    required this.onCloseBehaviorChanged,
    required this.startupBehavior,
    required this.onStartupBehaviorChanged,
    required this.desktopBehaviorBusy,
    required this.desktopBehaviorMessage,
    required this.onExecuteCloseBehavior,
    this.layout,
    this.operations,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final int dashboardPollSeconds;
  final ValueChanged<int> onDashboardPollSecondsChanged;
  final int autoLockHours;
  final ValueChanged<int> onAutoLockHoursChanged;
  final ConsoleLockShortcut lockShortcut;
  final ValueChanged<ConsoleLockShortcut> onLockShortcutChanged;
  final String adminUsername;
  final Future<bool> Function(String username, String password)
  onChangeAdminCredentials;
  final VoidCallback onLock;
  final AppCloseBehavior closeBehavior;
  final ValueChanged<AppCloseBehavior> onCloseBehaviorChanged;
  final AppStartupBehavior startupBehavior;
  final Future<bool> Function(AppStartupBehavior) onStartupBehaviorChanged;
  final bool desktopBehaviorBusy;
  final String? desktopBehaviorMessage;
  final Future<void> Function(AppCloseBehavior) onExecuteCloseBehavior;
  final PortableLayout? layout;
  final ServiceOperations? operations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      key: const Key('settings-page'),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: theme.textTheme.headlineMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '控制台外观、采样策略与便携服务配置',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _ConsolePreferencesCard(
            themeMode: themeMode,
            onThemeModeChanged: onThemeModeChanged,
            dashboardPollSeconds: dashboardPollSeconds,
            onDashboardPollSecondsChanged: onDashboardPollSecondsChanged,
          ),
          const SizedBox(height: AppSpacing.md),
          _DesktopBehaviorCard(
            closeBehavior: closeBehavior,
            onCloseBehaviorChanged: onCloseBehaviorChanged,
            startupBehavior: startupBehavior,
            onStartupBehaviorChanged: onStartupBehaviorChanged,
            busy: desktopBehaviorBusy,
            message: desktopBehaviorMessage,
            onExecuteCloseBehavior: onExecuteCloseBehavior,
          ),
          const SizedBox(height: AppSpacing.md),
          _SecurityPrivacyCard(
            autoLockHours: autoLockHours,
            onAutoLockHoursChanged: onAutoLockHoursChanged,
            lockShortcut: lockShortcut,
            onLockShortcutChanged: onLockShortcutChanged,
            adminUsername: adminUsername,
            onChangeAdminCredentials: onChangeAdminCredentials,
            onLock: onLock,
          ),
          const SizedBox(height: AppSpacing.md),
          ServerConfigSection(layout: layout, operations: operations),
        ],
      ),
    );
  }
}

class _DesktopBehaviorCard extends StatelessWidget {
  const _DesktopBehaviorCard({
    required this.closeBehavior,
    required this.onCloseBehaviorChanged,
    required this.startupBehavior,
    required this.onStartupBehaviorChanged,
    required this.busy,
    required this.message,
    required this.onExecuteCloseBehavior,
  });

  final AppCloseBehavior closeBehavior;
  final ValueChanged<AppCloseBehavior> onCloseBehaviorChanged;
  final AppStartupBehavior startupBehavior;
  final Future<bool> Function(AppStartupBehavior) onStartupBehaviorChanged;
  final bool busy;
  final String? message;
  final Future<void> Function(AppCloseBehavior) onExecuteCloseBehavior;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasError = message?.contains('失败') == true;
    return Card(
      key: const Key('desktop-behavior-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关闭与开机行为', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '关闭窗口可保留服务并驻留托盘，也可停止服务后退出；开机自启会在登录 Windows 后以最高权限运行。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.lg,
              children: [
                SizedBox(
                  width: 360,
                  child: DropdownButtonFormField<AppCloseBehavior>(
                    key: ValueKey('close-behavior-${closeBehavior.name}'),
                    isExpanded: true,
                    initialValue: closeBehavior,
                    decoration: const InputDecoration(labelText: '默认关闭行为'),
                    items: [
                      for (final behavior in AppCloseBehavior.values)
                        DropdownMenuItem(
                          value: behavior,
                          child: Text(behavior.label),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) onCloseBehaviorChanged(value);
                          },
                  ),
                ),
                SizedBox(
                  width: 430,
                  child: DropdownButtonFormField<AppStartupBehavior>(
                    key: ValueKey('startup-behavior-${startupBehavior.name}'),
                    isExpanded: true,
                    initialValue: startupBehavior,
                    decoration: const InputDecoration(labelText: '开机自启行为'),
                    items: [
                      for (final behavior in AppStartupBehavior.values)
                        DropdownMenuItem(
                          value: behavior,
                          child: Text(behavior.label),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) async {
                            if (value != null) {
                              await onStartupBehaviorChanged(value);
                            }
                          },
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('minimize-to-tray-now'),
                  onPressed: busy
                      ? null
                      : () => onExecuteCloseBehavior(
                          AppCloseBehavior.minimizeToTray,
                        ),
                  icon: const Icon(Icons.move_to_inbox_outlined),
                  label: const Text('立即最小化到托盘'),
                ),
                FilledButton.icon(
                  key: const Key('stop-service-and-exit-now'),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  ),
                  onPressed: busy ? null : () => _confirmStopAndExit(context),
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: const Text('关闭服务并退出'),
                ),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (message != null && message!.trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: (hasError ? colors.error : AppColors.brand).withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (hasError ? colors.error : AppColors.brand)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(message!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmStopAndExit(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭服务并退出？'),
        content: const Text('VNTS2 服务将停止，所有已连接节点会断开。确认继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('关闭服务并退出'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await onExecuteCloseBehavior(AppCloseBehavior.stopServiceAndExit);
    }
  }
}

class _SecurityPrivacyCard extends StatelessWidget {
  const _SecurityPrivacyCard({
    required this.autoLockHours,
    required this.onAutoLockHoursChanged,
    required this.lockShortcut,
    required this.onLockShortcutChanged,
    required this.adminUsername,
    required this.onChangeAdminCredentials,
    required this.onLock,
  });

  final int autoLockHours;
  final ValueChanged<int> onAutoLockHoursChanged;
  final ConsoleLockShortcut lockShortcut;
  final ValueChanged<ConsoleLockShortcut> onLockShortcutChanged;
  final String adminUsername;
  final Future<bool> Function(String username, String password)
  onChangeAdminCredentials;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('安全与隐私', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '无操作时自动隐藏全部业务页面；解锁必须重新验证管理员账号和密码。',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.lg,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<int>(
                    key: const Key('auto-lock-hours'),
                    isExpanded: true,
                    initialValue: autoLockHours,
                    decoration: const InputDecoration(labelText: '无操作自动锁定'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('不自动锁定')),
                      DropdownMenuItem(value: 1, child: Text('1 小时后')),
                      DropdownMenuItem(value: 2, child: Text('2 小时后')),
                      DropdownMenuItem(value: 4, child: Text('4 小时后')),
                      DropdownMenuItem(value: 8, child: Text('8 小时后')),
                      DropdownMenuItem(value: 12, child: Text('12 小时后')),
                      DropdownMenuItem(value: 24, child: Text('24 小时后')),
                    ],
                    onChanged: (value) {
                      if (value != null) onAutoLockHoursChanged(value);
                    },
                  ),
                ),
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<ConsoleLockShortcut>(
                    key: const Key('lock-shortcut'),
                    isExpanded: true,
                    initialValue: lockShortcut,
                    decoration: const InputDecoration(labelText: '立即锁定快捷键'),
                    items: [
                      for (final shortcut in ConsoleLockShortcut.values)
                        DropdownMenuItem(
                          value: shortcut,
                          child: Text(shortcut.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) onLockShortcutChanged(value);
                    },
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('change-admin-credentials'),
                  onPressed: () => _changeCredentials(context),
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: const Text('修改管理员凭据'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('lock-console-now'),
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

  Future<void> _changeCredentials(BuildContext context) async {
    final credentials = await showAdminCredentialsDialog(
      context,
      currentUsername: adminUsername,
    );
    if (credentials == null) return;
    await onChangeAdminCredentials(credentials.username, credentials.password);
  }
}

class _ConsolePreferencesCard extends StatelessWidget {
  const _ConsolePreferencesCard({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.dashboardPollSeconds,
    required this.onDashboardPollSecondsChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final int dashboardPollSeconds;
  final ValueChanged<int> onDashboardPollSecondsChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('控制台偏好', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '仅保存主题和仪表盘采样间隔，不保存密码、Token 或服务配置正文。',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.xl,
              runSpacing: AppSpacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<ThemeMode>(
                  key: const Key('theme-mode-selector'),
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined),
                      label: Text('跟随系统'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined),
                      label: Text('浅色'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined),
                      label: Text('暗黑'),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (value) {
                    onThemeModeChanged(value.first);
                  },
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('仪表盘采样'),
                    const SizedBox(width: AppSpacing.sm),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1 秒')),
                        ButtonSegment(value: 2, label: Text('2 秒')),
                        ButtonSegment(value: 5, label: Text('5 秒')),
                      ],
                      selected: {dashboardPollSeconds},
                      onSelectionChanged: (value) {
                        onDashboardPollSecondsChanged(value.first);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ServerConfigSection extends StatefulWidget {
  const ServerConfigSection({
    super.key,
    this.layout,
    this.operations,
    this.controller,
  });

  final PortableLayout? layout;
  final ServiceOperations? operations;
  final ServerConfigController? controller;

  @override
  State<ServerConfigSection> createState() => _ServerConfigSectionState();
}

class _ServerConfigSectionState extends State<ServerConfigSection> {
  late final ServerConfigController controller;
  late final bool ownsController;
  final formKey = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  final newServerToken = TextEditingController();
  bool? persistence;
  bool? webEnabled;
  bool? wireGuardEnabled;
  bool? serverQuicEnabled;
  bool synced = false;

  @override
  void initState() {
    super.initState();
    ownsController = widget.controller == null;
    controller =
        widget.controller ??
        ServerConfigController(
          widget.layout == null
              ? null
              : ServerConfigRepository(widget.layout!.config),
          widget.operations,
        );
    if (controller.settings != null) {
      _sync(notify: false);
    } else {
      controller.load().then((_) {
        if (mounted) _sync();
      });
    }
  }

  @override
  void dispose() {
    for (final value in fields.values) {
      value.dispose();
    }
    newServerToken.dispose();
    if (ownsController) controller.dispose();
    super.dispose();
  }

  TextEditingController _field(String key) {
    return fields.putIfAbsent(key, TextEditingController.new);
  }

  void _sync({bool notify = true}) {
    final settings = controller.settings;
    if (settings == null) return;
    final values = <String, String>{
      'tcp': settings.tcpBind,
      'quic': settings.quicBind,
      'ws': settings.webSocketBind,
      'network': settings.network,
      'whitelist': settings.whiteList.join('\n'),
      'lease': '${settings.leaseDurationSeconds}',
      'webBind': settings.webBind,
      'cert': settings.certificateFile,
      'key': settings.privateKeyFile,
      'wgKey': settings.wireGuardMasterKeyFile,
      'wgBind': settings.wireGuardBind,
      'wgEndpoint': settings.wireGuardPublicEndpoint,
      'wgMax': '${settings.wireGuardMaxActivePeers}',
      'serverBind': settings.serverQuicBind,
    };
    for (final entry in values.entries) {
      _field(entry.key).text = entry.value;
    }
    persistence = settings.persistence;
    webEnabled = settings.webEnabled;
    wireGuardEnabled = settings.wireGuardEnabled;
    serverQuicEnabled = settings.serverQuicEnabled;
    synced = true;
    if (notify) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.loading || (!synced && controller.settings != null)) {
          return const Card(
            child: SizedBox(height: 300, child: AppStateView.loading()),
          );
        }
        if (controller.settings == null) {
          return Card(
            child: SizedBox(
              height: 300,
              child: AppStateView.error(
                message: controller.error ?? '配置不可用',
                onAction: controller.load,
              ),
            ),
          );
        }
        return _editor();
      },
    );
  }

  Widget _editor() {
    final theme = Theme.of(context);
    final settings = controller.settings!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('服务配置', style: theme.textTheme.titleLarge),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '保存前自动备份；管理员凭据在“安全与隐私”中统一修改，Token 从不显示明文。',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '重新加载',
                    onPressed: controller.saving ? null : _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _section(
                title: '基础网络与监听',
                icon: Icons.lan_outlined,
                initiallyExpanded: true,
                children: [
                  _text('network', '默认网络 CIDR', required: true),
                  _number('lease', '租约时长（秒）'),
                  _text('tcp', 'TCP 监听（可选）'),
                  _text('quic', 'QUIC 监听（可选）'),
                  _text('ws', 'WebSocket 监听（可选）'),
                  _text('whitelist', '白名单（每行一项）', lines: 3),
                  _switch(
                    '启用数据持久化',
                    persistence!,
                    (value) => setState(() => persistence = value),
                  ),
                ],
              ),
              _section(
                title: 'Web 管理与 TLS',
                icon: Icons.admin_panel_settings_outlined,
                children: [
                  _switch(
                    '启用本机 Web 管理',
                    webEnabled!,
                    (value) => setState(() => webEnabled = value),
                  ),
                  if (webEnabled!) ...[
                    _text('webBind', 'Web 绑定（仅回环）', required: true),
                    SizedBox(
                      width: 616,
                      child: Text(
                        '当前管理员：${settings.username}。账号和密码请在上方“安全与隐私”中修改，保存后会立即要求重新登录。',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                  _text('cert', 'TLS 证书文件（可选）'),
                  _text('key', 'TLS 私钥文件（可选）'),
                ],
              ),
              _section(
                title: 'WireGuard',
                icon: Icons.shield_outlined,
                children: [
                  _switch(
                    '启用 WireGuard',
                    wireGuardEnabled!,
                    _setWireGuardEnabled,
                  ),
                  if (wireGuardEnabled!) ...[
                    _text('wgKey', '主密钥文件', required: true),
                    _text('wgBind', 'UDP 监听地址', required: true),
                    _text('wgEndpoint', '外部访问地址', required: true),
                    _number('wgMax', '最大活跃 Peer'),
                  ],
                ],
              ),
              _section(
                title: '服务端互联',
                icon: Icons.dns_outlined,
                children: [
                  _switch(
                    '启用互联监听',
                    serverQuicEnabled!,
                    (value) => setState(() => serverQuicEnabled = value),
                  ),
                  if (serverQuicEnabled!) ...[
                    _text('serverBind', '互联 QUIC 监听', required: true),
                    _secret(
                      controller: newServerToken,
                      label: settings.hasServerToken
                          ? '新 Token（留空则保留已配置 Token）'
                          : '新服务端 Token',
                      configured: settings.hasServerToken,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Text(
                        '配置文件内已有 ${settings.peerServerCount} 个初始互联地址；运行时地址请在“互联服务器”页面管理。',
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (controller.lastBackupPath != null) ...[
                    const Text(
                      '上次保存已在 data/.backups 创建时间戳备份。',
                      style: TextStyle(color: AppColors.success),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      OutlinedButton(
                        onPressed: controller.saving
                            ? null
                            : () => _save(false),
                        child: const Text('仅保存'),
                      ),
                      FilledButton.icon(
                        key: const Key('save-config-restart'),
                        onPressed: controller.saving ? null : () => _save(true),
                        icon: controller.saving
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.restart_alt_rounded),
                        label: const Text('保存并重启'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setWireGuardEnabled(bool value) async {
    setState(() => wireGuardEnabled = value);
    if (!value) return;
    if (_field('wgKey').text.trim().isEmpty) {
      _field('wgKey').text = WireGuardDefaults.masterKeyFile;
    }
    if (_field('wgBind').text.trim().isEmpty) {
      _field('wgBind').text = WireGuardDefaults.bind;
    }
    if (_field('wgEndpoint').text.trim().isEmpty) {
      final endpoint = await WireGuardDefaults.publicEndpoint();
      if (!mounted) return;
      _field('wgEndpoint').text = endpoint;
      setState(() {});
    }
  }

  Widget _section({
    required String title,
    required IconData icon,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      leading: Icon(icon, color: AppColors.brand),
      title: Text(title),
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.lg,
          children: children,
        ),
      ],
    );
  }

  Widget _text(
    String key,
    String label, {
    bool required = false,
    int lines = 1,
  }) {
    return SizedBox(
      width: lines > 1 ? 616 : 300,
      child: TextFormField(
        controller: _field(key),
        minLines: lines,
        maxLines: lines,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (value) => value == null || value.trim().isEmpty ? '不能为空' : null
            : null,
      ),
    );
  }

  Widget _number(String key, String label) {
    return SizedBox(
      width: 300,
      child: TextFormField(
        controller: _field(key),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final number = int.tryParse(value ?? '');
          return number != null && number > 0 ? null : '请输入大于 0 的整数';
        },
      ),
    );
  }

  Widget _secret({
    required TextEditingController controller,
    required String label,
    required bool configured,
  }) {
    return SizedBox(
      width: 300,
      child: TextFormField(
        controller: controller,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(
            configured ? Icons.check_circle_outline : Icons.key_outlined,
            color: configured ? AppColors.success : null,
          ),
        ),
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      width: 300,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  ServerConfigSettings _draft() {
    return controller.settings!.copyWith(
      tcpBind: _field('tcp').text.trim(),
      quicBind: _field('quic').text.trim(),
      webSocketBind: _field('ws').text.trim(),
      network: _field('network').text.trim(),
      whiteList: _field('whitelist').text
          .split(RegExp(r'[\r\n,]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(),
      leaseDurationSeconds: int.parse(_field('lease').text),
      persistence: persistence,
      webEnabled: webEnabled,
      webBind: _field('webBind').text.trim(),
      certificateFile: _field('cert').text.trim(),
      privateKeyFile: _field('key').text.trim(),
      wireGuardEnabled: wireGuardEnabled,
      wireGuardMasterKeyFile: _field('wgKey').text.trim(),
      wireGuardBind: _field('wgBind').text.trim(),
      wireGuardPublicEndpoint: _field('wgEndpoint').text.trim(),
      wireGuardMaxActivePeers: int.parse(_field('wgMax').text),
      serverQuicEnabled: serverQuicEnabled,
      serverQuicBind: _field('serverBind').text.trim(),
    );
  }

  Future<void> _save(bool restart) async {
    if (!formKey.currentState!.validate()) return;
    try {
      await controller.save(
        _draft(),
        newPassword: '',
        newServerToken: newServerToken.text,
        restart: restart,
      );
      newServerToken.clear();
      _sync();
      if (mounted) _message(restart ? '配置已保存并重启服务' : '配置已安全保存');
    } on ConfigValidationException catch (exception) {
      if (mounted) _message(exception.message);
    } on FileSystemException catch (exception) {
      if (mounted) _message('保存配置失败：${exception.message}');
    } on ServiceOperationException catch (exception) {
      if (mounted) _message(exception.message);
    }
  }

  Future<void> _reload() async {
    synced = false;
    await controller.load();
    if (mounted) _sync();
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }
}

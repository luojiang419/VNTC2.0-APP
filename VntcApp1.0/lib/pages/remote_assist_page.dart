import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_manager.dart';
import 'package:vnt_app/remote_assist/remote_assist_models.dart';
import 'package:vnt_app/remote_assist/remote_assist_utils.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/toast_utils.dart';

class RemoteAssistPage extends StatefulWidget {
  const RemoteAssistPage({super.key});

  @override
  State<RemoteAssistPage> createState() => _RemoteAssistPageState();
}

class _RemoteAssistPageState extends State<RemoteAssistPage> {
  final RemoteAssistManager _manager = RemoteAssistManager.instance;
  final TextEditingController _targetIpController = TextEditingController();
  final TextEditingController _targetPasswordController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _manager.start();
    _manager.refresh();
  }

  @override
  void dispose() {
    _targetIpController.dispose();
    _targetPasswordController.dispose();
    super.dispose();
  }

  Future<void> _launchRemoteAssist() async {
    final targetIp = _targetIpController.text.trim();
    final accessPassword = _targetPasswordController.text;
    if (!isValidIpv4(targetIp)) {
      showTopToast(context, '请输入有效的目标虚拟 IP', isSuccess: false);
      return;
    }

    try {
      await _manager.launchController(
        targetIp,
        password: accessPassword.isEmpty ? null : accessPassword,
      );
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        accessPassword.isEmpty ? '已拉起远程协助窗口，等待对方确认' : '已拉起远程协助窗口，正在尝试使用访问密码连接',
        isSuccess: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '远程协助启动失败: $error', isSuccess: false);
    }
  }

  void _selectPeer(RemoteAssistPeer peer) {
    _targetIpController.text = peer.virtualIp;
    Clipboard.setData(ClipboardData(text: peer.virtualIp));
    showTopToast(
      context,
      '${peer.virtualIp} 已复制并填入连接框',
      isSuccess: true,
    );
  }

  Future<void> _showAccessPasswordDialog() async {
    final controller = TextEditingController();
    try {
      final password = await showDialog<String?>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('设置远程密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设置后，对方输入正确密码即可直接远程控制；留空则清空密码，并恢复为本机手动接受。',
                ),
                SizedBox(height: context.spacingMedium),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '远程密码',
                    hintText: '留空表示清空密码',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text),
                child: const Text('确定'),
              ),
            ],
          );
        },
      );

      if (password == null) {
        return;
      }

      await _manager.configureAccessPassword(password);
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        password.isEmpty ? '已清空远程密码，后续需要本机手动接受协助' : '已设置远程密码，后续可通过密码无人值守协助',
        isSuccess: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(context, '远程密码设置失败: $error', isSuccess: false);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _toggleControlledService() async {
    final shouldStop = _manager.health.controlledServiceRunning;
    try {
      if (shouldStop) {
        await _manager.stopControlledService();
      } else {
        await _manager.startControlledService();
      }
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        shouldStop ? '已停止受控服务' : '已启动受控服务',
        isSuccess: true,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showTopToast(
        context,
        shouldStop ? '停止受控服务失败: $error' : '启动受控服务失败: $error',
        isSuccess: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _manager,
          builder: (context, _) {
            final health = _manager.health;
            final peers = _manager.peers
                .where((peer) => peer.isOnline)
                .toList(growable: false);
            final useAndroidLayout = health.isAndroid ||
                defaultTargetPlatform == TargetPlatform.android;
            return RefreshIndicator(
              onRefresh: () => _manager.refresh(),
              child: ListView(
                padding: EdgeInsets.all(context.spacingLarge),
                children: [
                  _buildHeader(isDark),
                  SizedBox(height: context.spacingLarge),
                  if (useAndroidLayout) ...[
                    _buildAndroidControllerCard(isDark, health, peers),
                    SizedBox(height: context.spacingLarge),
                    _buildAndroidControlledCard(isDark, health),
                    SizedBox(height: context.spacingLarge),
                    _buildAndroidPermissionCard(isDark, health),
                  ] else ...[
                    _buildConnectCard(isDark, health),
                    SizedBox(height: context.spacingLarge),
                    if (health.isMacOS) ...[
                      _buildMacosControlledCard(isDark, health),
                      SizedBox(height: context.spacingLarge),
                    ],
                    _buildPeerList(isDark, peers),
                  ],
                  SizedBox(height: context.spacingLarge),
                  if (useAndroidLayout) _buildPeerList(isDark, peers),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    final primaryColor = Theme.of(context).primaryColor;
    return Row(
      children: [
        Container(
          width: context.iconXLarge,
          height: context.iconXLarge,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryColor, primaryColor.withOpacity(0.75)],
            ),
            borderRadius: BorderRadius.circular(context.cardRadius),
          ),
          child: Icon(
            Icons.support_agent,
            color: Colors.white,
            size: context.iconLarge,
          ),
        ),
        SizedBox(width: context.spacingMedium),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '远程协助',
                style: TextStyle(
                  fontSize: context.fontXLarge,
                  fontWeight: FontWeight.bold,
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                ),
              ),
              Text(
                '基于 VNT 虚拟 IP 管理远程协助连接与受控服务状态',
                style: TextStyle(
                  fontSize: context.fontBody,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: _showAccessPasswordDialog,
          child: const Text('设置远程密码'),
        ),
        IconButton(
          onPressed: _manager.refreshing ? null : () => _manager.refresh(),
          tooltip: '刷新状态',
          icon: Icon(
            Icons.refresh,
            color:
                isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildAndroidControllerCard(
    bool isDark,
    RemoteAssistHealthStatus health,
    List<RemoteAssistPeer> peers,
  ) {
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '控制别人',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingSmall),
          Text(
            '使用 VNT 虚拟 IP 直接打开内置远控会话。同一个 APK 内即可完成组网、聊天和远程协助。',
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          TextField(
            controller: _targetIpController,
            decoration: InputDecoration(
              labelText: '目标虚拟 IP',
              hintText: '例如 10.26.0.8',
              suffixIcon: IconButton(
                tooltip: '粘贴',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final pasted = data?.text?.trim() ?? '';
                  if (pasted.isNotEmpty) {
                    _targetIpController.text = pasted;
                  }
                },
                icon: const Icon(Icons.content_paste_go),
              ),
            ),
          ),
          SizedBox(height: context.spacingMedium),
          TextField(
            controller: _targetPasswordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '访问密码',
              hintText: '可选，留空则等待对方手动接受',
            ),
          ),
          SizedBox(height: context.spacingMedium),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: health.canLaunch ? _launchRemoteAssist : null,
                  icon: const Icon(Icons.computer),
                  label: const Text('发起协助'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: context.spacingSmall),
              TextButton(
                onPressed:
                    peers.isEmpty ? null : () => _selectPeer(peers.first),
                child: const Text('填入首个在线设备'),
              ),
            ],
          ),
          if (!health.controllerAvailable) ...[
            SizedBox(height: context.spacingMedium),
            _buildWarningBox(
              isDark,
              '当前安装包未包含适用于本机架构的内置控制端，请使用 arm64 真机安装包后再发起协助。',
            ),
          ] else if (!health.vntConnected) ...[
            SizedBox(height: context.spacingMedium),
            _buildWarningBox(
              isDark,
              '当前还未连接 VNT 虚拟网络。先建立组网连接后，Android 控制端才能通过虚拟 IP 发起协助。',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAndroidControlledCard(
    bool isDark,
    RemoteAssistHealthStatus health,
  ) {
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '让别人控制我',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingSmall),
          Text(
            health.supportsControlledRole
                ? '启动受控服务后，Windows 端可通过你的 VNT 虚拟 IP 发起协助。建议先完成下方全部权限。'
                : '当前版本先收口 Android 控制端链路，Android 作为受控端的真实 RustDesk host 会话尚未接入，因此这里仅保留状态预检，不再对外宣称可被控制。',
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          _buildStatusLine(
            isDark,
            '本机虚拟 IP',
            health.localVirtualIps.isEmpty
                ? '--'
                : health.localVirtualIps.join(', '),
          ),
          _buildStatusLine(
            isDark,
            '虚拟网段',
            health.networkCidrs.isEmpty ? '--' : health.networkCidrs.join(', '),
          ),
          _buildStatusLine(
            isDark,
            '受控能力',
            health.supportsControlledRole
                ? (health.controlledReady ? '已就绪' : '未就绪')
                : '当前版本未开放',
          ),
          _buildStatusLine(
            isDark,
            '运行时版本',
            health.runtimeVersion.isEmpty ? '--' : health.runtimeVersion,
          ),
          SizedBox(height: context.spacingMedium),
          Wrap(
            spacing: context.spacingSmall,
            runSpacing: context.spacingSmall,
            children: [
              _buildChip(
                isDark,
                label: health.vntConnected ? 'VNT 已连接' : 'VNT 未连接',
                isActive: health.vntConnected,
              ),
              _buildChip(
                isDark,
                label: health.supportsControlledRole
                    ? (health.screenCapturePermissionGranted
                        ? '录屏已授权'
                        : '录屏未授权')
                    : '受控端暂未开放',
                isActive: health.supportsControlledRole
                    ? health.screenCapturePermissionGranted
                    : false,
              ),
              _buildChip(
                isDark,
                label: health.supportsControlledRole
                    ? (health.accessibilityPermissionGranted
                        ? '无障碍已开启'
                        : '无障碍未开启')
                    : '仅控制端已接入',
                isActive: health.supportsControlledRole
                    ? health.accessibilityPermissionGranted
                    : health.controllerReady,
              ),
            ],
          ),
          SizedBox(height: context.spacingMedium),
          if (!health.supportsControlledRole)
            _buildWarningBox(
              isDark,
              '这轮修复已停止把 Android 端误判为“可被控制”。在真正 host 链路接入前，Windows 或其他设备不会再被误导去连接当前 Android 端。',
            )
          else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: health.controlledServiceRunning ||
                            health.canStartControlledService
                        ? _toggleControlledService
                        : null,
                    icon: Icon(
                      health.controlledServiceRunning
                          ? Icons.stop_circle_outlined
                          : Icons.play_circle_outline,
                    ),
                    label: Text(
                      health.controlledServiceRunning ? '停止受控服务' : '启动受控服务',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                SizedBox(width: context.spacingSmall),
                OutlinedButton(
                  onPressed: _showAccessPasswordDialog,
                  child: const Text('设置访问密码'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildAndroidPermissionCard(
    bool isDark,
    RemoteAssistHealthStatus health,
  ) {
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '权限与系统',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          _buildPermissionTile(
            isDark,
            title: '通知权限',
            granted: health.notificationPermissionGranted,
            actionLabel: '打开',
            onTap: () => _manager.requestPermission(
              RemoteAssistConstants.androidPermissionNotification,
            ),
          ),
          _buildPermissionTile(
            isDark,
            title: '屏幕录制',
            granted: health.screenCapturePermissionGranted,
            actionLabel: '授权',
            onTap: () => _manager.requestPermission(
              RemoteAssistConstants.androidPermissionScreenCapture,
            ),
          ),
          _buildPermissionTile(
            isDark,
            title: '无障碍控制',
            granted: health.accessibilityPermissionGranted,
            actionLabel: '设置',
            onTap: () => _manager.openSystemSettings(
              RemoteAssistConstants.androidSettingsAccessibility,
            ),
          ),
          _buildPermissionTile(
            isDark,
            title: '悬浮窗',
            granted: health.overlayPermissionGranted,
            actionLabel: '设置',
            onTap: () => _manager.openSystemSettings(
              RemoteAssistConstants.androidSettingsOverlay,
            ),
          ),
          _buildPermissionTile(
            isDark,
            title: '电池优化白名单',
            granted: health.batteryOptimizationIgnored,
            actionLabel: '设置',
            onTap: () => _manager.openSystemSettings(
              RemoteAssistConstants.androidSettingsBatteryOptimization,
            ),
          ),
          if (health.issues.isNotEmpty) ...[
            SizedBox(height: context.spacingMedium),
            _buildWarningBox(isDark, health.issues.join('\n')),
          ],
        ],
      ),
    );
  }

  Widget _buildMacosControlledCard(
    bool isDark,
    RemoteAssistHealthStatus health,
  ) {
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本机受控服务',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingSmall),
          Text(
            '启动内置 VNTC RustDesk 后，其他设备可通过你的 VNT 虚拟 IP 和 49999 端口发起远程协助。',
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          _buildStatusLine(
            isDark,
            '组件状态',
            health.installationModeDescription,
          ),
          _buildStatusLine(
            isDark,
            '运行时版本',
            health.runtimeVersion.isEmpty ? '--' : health.runtimeVersion,
          ),
          _buildStatusLine(
            isDark,
            '本机虚拟 IP',
            health.localVirtualIps.isEmpty
                ? '--'
                : health.localVirtualIps.join(', '),
          ),
          _buildStatusLine(
            isDark,
            '受控监听',
            health.portListening ? '49999 已监听' : '49999 未监听',
          ),
          SizedBox(height: context.spacingMedium),
          Wrap(
            spacing: context.spacingSmall,
            runSpacing: context.spacingSmall,
            children: [
              _buildChip(
                isDark,
                label: health.vntConnected ? 'VNT 已连接' : 'VNT 未连接',
                isActive: health.vntConnected,
              ),
              _buildChip(
                isDark,
                label: health.runtimeAvailable ? '远控组件已找到' : '远控组件缺失',
                isActive: health.runtimeAvailable,
              ),
              _buildChip(
                isDark,
                label: health.controlledServiceRunning ? '受控服务运行中' : '受控服务未启动',
                isActive: health.controlledServiceRunning,
              ),
            ],
          ),
          SizedBox(height: context.spacingMedium),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: health.runtimeAvailable &&
                          (health.controlledServiceRunning ||
                              health.canStartControlledService)
                      ? _toggleControlledService
                      : null,
                  icon: Icon(
                    health.controlledServiceRunning
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  label: Text(
                    health.controlledServiceRunning ? '停止受控服务' : '启动受控服务',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: context.spacingSmall),
              OutlinedButton(
                onPressed:
                    health.runtimeAvailable ? _showAccessPasswordDialog : null,
                child: const Text('设置访问密码'),
              ),
            ],
          ),
          SizedBox(height: context.spacingMedium),
          Wrap(
            spacing: context.spacingSmall,
            runSpacing: context.spacingSmall,
            children: [
              OutlinedButton(
                onPressed: () => _manager.openSystemSettings(
                  RemoteAssistConstants.macosSettingsScreenRecording,
                ),
                child: const Text('屏幕录制权限'),
              ),
              OutlinedButton(
                onPressed: () => _manager.openSystemSettings(
                  RemoteAssistConstants.macosSettingsAccessibility,
                ),
                child: const Text('辅助功能权限'),
              ),
              OutlinedButton(
                onPressed: () => _manager.openSystemSettings(
                  RemoteAssistConstants.macosSettingsMicrophone,
                ),
                child: const Text('麦克风权限'),
              ),
            ],
          ),
          if (health.issues.isNotEmpty) ...[
            SizedBox(height: context.spacingMedium),
            _buildWarningBox(isDark, health.issues.join('\n')),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectCard(bool isDark, RemoteAssistHealthStatus health) {
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '目标连接',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          TextField(
            controller: _targetIpController,
            decoration: InputDecoration(
              labelText: '目标虚拟 IP',
              hintText: '例如 10.26.0.8',
              suffixIcon: IconButton(
                tooltip: '粘贴',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final pasted = data?.text?.trim() ?? '';
                  if (pasted.isNotEmpty) {
                    _targetIpController.text = pasted;
                  }
                },
                icon: const Icon(Icons.content_paste_go),
              ),
            ),
          ),
          SizedBox(height: context.spacingMedium),
          TextField(
            controller: _targetPasswordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '访问密码',
              hintText: '可选，留空则等待对方手动接受',
            ),
          ),
          SizedBox(height: context.spacingMedium),
          Text(
            '点击下方在线用户卡片会自动复制并填入该用户虚拟 IP；访问密码需要按实际情况手动输入，随后点击“连接”即可发起协助。',
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: health.canLaunch ? _launchRemoteAssist : null,
                  icon: const Icon(Icons.link),
                  label: const Text('连接'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionTile(
    bool isDark, {
    required String title,
    required bool granted,
    required String actionLabel,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.spacingSmall),
      child: Container(
        padding: EdgeInsets.all(context.spacingMedium),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : Colors.black.withOpacity(0.02),
          borderRadius: BorderRadius.circular(context.cardRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: context.fontMedium,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                    ),
                  ),
                  SizedBox(height: context.spacingXXSmall),
                  Text(
                    granted ? '已完成' : '待处理',
                    style: TextStyle(
                      fontSize: context.fontSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onTap, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusLine(bool isDark, String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.spacingSmall),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
          ),
          SizedBox(width: context.spacingSmall),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningBox(bool isDark, String text) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingMedium),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: context.fontSmall,
          height: 1.45,
          color: Colors.orange[isDark ? 200 : 900],
        ),
      ),
    );
  }

  Widget _buildPeerList(bool isDark, List<RemoteAssistPeer> peers) {
    return Container(
      padding: EdgeInsets.all(context.cardPadding),
      decoration: BoxDecoration(
        color:
            isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在线用户',
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.w700,
              color:
                  isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingMedium),
          if (peers.isEmpty)
            Text(
              '当前没有在线的远程协助目标。请先连接 VNT，并确认对端在线且已安装 vntcrustdesk。',
              style: TextStyle(
                fontSize: context.fontBody,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            )
          else
            ...peers.map(
              (peer) => Padding(
                padding: EdgeInsets.only(bottom: context.spacingSmall),
                child: _buildPeerCard(isDark, peer),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPeerCard(bool isDark, RemoteAssistPeer peer) {
    final primaryColor = Theme.of(context).primaryColor;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _selectPeer(peer),
        borderRadius: BorderRadius.circular(context.cardRadius),
        child: Container(
          padding: EdgeInsets.all(context.spacingMedium),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withOpacity(0.04)
                : Colors.black.withOpacity(0.02),
            borderRadius: BorderRadius.circular(context.cardRadius),
            border: Border.all(
              color: peer.isOnline
                  ? primaryColor.withOpacity(0.25)
                  : Colors.grey.withOpacity(0.25),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: context.iconXLarge,
                height: context.iconXLarge,
                decoration: BoxDecoration(
                  color: peer.isOnline
                      ? primaryColor.withOpacity(0.12)
                      : Colors.grey.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(context.cardRadius),
                ),
                child: Icon(
                  Icons.computer,
                  color: peer.isOnline ? primaryColor : Colors.grey,
                ),
              ),
              SizedBox(width: context.spacingMedium),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.displayName,
                      style: TextStyle(
                        fontSize: context.fontMedium,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                      ),
                    ),
                    SizedBox(height: context.spacingXXSmall),
                    Text(
                      peer.virtualIp,
                      style: TextStyle(
                        fontSize: context.fontSmall,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                    SizedBox(height: context.spacingXXSmall),
                    Text(
                      peer.networkName,
                      style: TextStyle(
                        fontSize: context.fontXSmall,
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                    if (peer.hasPresence) ...[
                      SizedBox(height: context.spacingXXSmall),
                      Text(
                        _buildPeerCapabilitySummary(peer),
                        style: TextStyle(
                          fontSize: context.fontXSmall,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _buildChip(
                    isDark,
                    label: peer.isOnline ? '在线' : '离线',
                    isActive: peer.isOnline,
                  ),
                  SizedBox(height: context.spacingXXSmall),
                  Text(
                    peer.hasPresence
                        ? '${_platformLabel(peer.platform)} · 可复制并连接'
                        : '等待 Presence',
                    style: TextStyle(
                      fontSize: context.fontXSmall,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildPeerCapabilitySummary(RemoteAssistPeer peer) {
    final roles = <String>[];
    if (peer.canControlOthers) {
      roles.add('可发起控制');
    }
    if (peer.canBeControlled) {
      roles.add('可被控');
    }
    if (roles.isEmpty) {
      roles.add('能力未知');
    }
    return '${_platformLabel(peer.platform)} · ${roles.join(' / ')}';
  }

  String _platformLabel(RemoteAssistPlatform platform) {
    switch (platform) {
      case RemoteAssistPlatform.windows:
        return 'Windows';
      case RemoteAssistPlatform.android:
        return 'Android';
      case RemoteAssistPlatform.macos:
        return 'macOS';
      case RemoteAssistPlatform.unsupported:
        return '未知平台';
    }
  }

  Widget _buildChip(
    bool isDark, {
    required String label,
    required bool isActive,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingSmall,
        vertical: context.spacingXXSmall,
      ),
      decoration: BoxDecoration(
        color: isActive
            ? Colors.green.withOpacity(0.15)
            : Colors.grey.withOpacity(isDark ? 0.20 : 0.14),
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.fontXSmall,
          fontWeight: FontWeight.w600,
          color: isActive
              ? Colors.green[800]
              : (isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary),
        ),
      ),
    );
  }
}

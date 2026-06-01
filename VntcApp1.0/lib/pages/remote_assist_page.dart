import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        accessPassword.isEmpty
            ? '已拉起远程协助窗口，等待对方确认'
            : '已拉起远程协助窗口，正在尝试使用访问密码连接',
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
        password.isEmpty
            ? '已清空远程密码，后续需要本机手动接受协助'
            : '已设置远程密码，后续可通过密码无人值守协助',
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
            return RefreshIndicator(
              onRefresh: () => _manager.refresh(),
              child: ListView(
                padding: EdgeInsets.all(context.spacingLarge),
                children: [
                  _buildHeader(isDark),
                  SizedBox(height: context.spacingLarge),
                  _buildConnectCard(isDark, health),
                  SizedBox(height: context.spacingLarge),
                  _buildPeerList(isDark, peers),
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
                '基于 VNT 虚拟 IP 直连 vntcrustdesk，支持访问密码无人值守或手动接受',
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
                    peer.hasPresence ? '可复制并连接' : '等待 Presence',
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

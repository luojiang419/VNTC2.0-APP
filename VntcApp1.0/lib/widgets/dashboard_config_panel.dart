import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

@immutable
class DashboardConfigActionResult {
  final bool isSuccess;
  final String message;

  const DashboardConfigActionResult._({
    required this.isSuccess,
    required this.message,
  });

  const DashboardConfigActionResult.success(String message)
      : this._(isSuccess: true, message: message);

  const DashboardConfigActionResult.failure(String message)
      : this._(isSuccess: false, message: message);
}

@immutable
class DashboardBatchConnectResult {
  final int requestedCount;
  final int startedCount;
  final int alreadyConnectedCount;
  final bool platformLimited;
  final Map<String, String> failures;

  DashboardBatchConnectResult({
    required this.requestedCount,
    required this.startedCount,
    required this.alreadyConnectedCount,
    this.platformLimited = false,
    Map<String, String> failures = const {},
  }) : failures = UnmodifiableMapView(Map<String, String>.from(failures));

  bool get hasFailures => failures.isNotEmpty;

  String get summary {
    if (requestedCount == 0) {
      return '暂无可连接配置';
    }
    final parts = <String>[];
    if (startedCount > 0) {
      parts.add('已发起 $startedCount 个连接');
    }
    if (alreadyConnectedCount > 0) {
      parts.add('$alreadyConnectedCount 个已连接');
    }
    if (failures.isNotEmpty) {
      parts.add('${failures.length} 个失败');
    }
    if (platformLimited) {
      parts.add('当前平台一次仅支持 1 个 VPN');
    }
    return parts.isEmpty ? '没有需要连接的配置' : parts.join('，');
  }
}

typedef DashboardConfigAction = Future<DashboardConfigActionResult> Function(
  NetworkConfig config,
);

enum DashboardConfigPanelAction {
  create,
  import,
}

/// 仪表盘的多配置控制面板。
///
/// 配置顺序以传入列表为唯一数据源，拖拽后通过 [onReorder] 交给上层持久化。
class DashboardConfigPanel extends StatefulWidget {
  final List<NetworkConfig> configs;
  final bool supportsMultipleConnections;
  final DashboardConfigAction onConnect;
  final DashboardConfigAction onDisconnect;
  final Future<NetworkConfig?> Function(NetworkConfig config) onEdit;
  final Future<void> Function(List<NetworkConfig> configs) onReorder;
  final bool Function(NetworkConfig config)? isConnected;
  final VntManager? manager;

  const DashboardConfigPanel({
    super.key,
    required this.configs,
    required this.supportsMultipleConnections,
    required this.onConnect,
    required this.onDisconnect,
    required this.onEdit,
    required this.onReorder,
    this.isConnected,
    this.manager,
  });

  @override
  State<DashboardConfigPanel> createState() => _DashboardConfigPanelState();
}

class _DashboardConfigPanelState extends State<DashboardConfigPanel> {
  late List<NetworkConfig> _configs;
  final Set<String> _busyKeys = <String>{};
  final Map<String, DashboardConfigActionResult> _actionResults =
      <String, DashboardConfigActionResult>{};

  VntManager get _manager => widget.manager ?? vntManager;

  @override
  void initState() {
    super.initState();
    _configs = List<NetworkConfig>.from(widget.configs);
    _manager.addConnectionListener(_handleConnectionChanged);
  }

  @override
  void didUpdateWidget(covariant DashboardConfigPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager) {
      (oldWidget.manager ?? vntManager)
          .removeConnectionListener(_handleConnectionChanged);
      _manager.addConnectionListener(_handleConnectionChanged);
    }
  }

  @override
  void dispose() {
    _manager.removeConnectionListener(_handleConnectionChanged);
    super.dispose();
  }

  void _handleConnectionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (oldIndex == newIndex) {
      return;
    }

    final previous = List<NetworkConfig>.from(_configs);
    setState(() {
      final config = _configs.removeAt(oldIndex);
      _configs.insert(newIndex, config);
    });

    try {
      await widget.onReorder(List<NetworkConfig>.unmodifiable(_configs));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _configs = previous;
        _actionResults['__order__'] = DashboardConfigActionResult.failure(
          '排序保存失败：$error',
        );
      });
    }
  }

  Future<void> _runAction(
    NetworkConfig config,
    DashboardConfigAction action,
  ) async {
    if (_busyKeys.contains(config.itemKey)) {
      return;
    }
    setState(() {
      _busyKeys.add(config.itemKey);
      _actionResults.remove(config.itemKey);
    });
    DashboardConfigActionResult result;
    try {
      result = await action(config);
    } catch (error) {
      result = DashboardConfigActionResult.failure('操作失败：$error');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busyKeys.remove(config.itemKey);
      _actionResults[config.itemKey] = result;
    });
  }

  Future<void> _edit(NetworkConfig config) async {
    if (_busyKeys.contains(config.itemKey)) {
      return;
    }
    setState(() => _busyKeys.add(config.itemKey));
    NetworkConfig? updated;
    Object? editError;
    try {
      updated = await widget.onEdit(config);
    } catch (error) {
      editError = error;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busyKeys.remove(config.itemKey);
      if (editError != null) {
        _actionResults[config.itemKey] =
            DashboardConfigActionResult.failure('编辑失败：$editError');
      }
      if (updated != null) {
        final index = _configs.indexWhere(
          (item) => item.itemKey == config.itemKey,
        );
        if (index >= 0) {
          _configs[index] = updated;
          _actionResults[updated.itemKey] =
              const DashboardConfigActionResult.success('配置已更新');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.themeTokens;
    final orderError = _actionResults['__order__'];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(context.spacingMedium),
      child: Container(
        width: context.w(640),
        constraints: BoxConstraints(maxHeight: context.w(720)),
        padding: EdgeInsets.all(context.spacingLarge),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(context.dialogRadius),
          border: Border.all(color: tokens.outline),
          boxShadow: [BoxShadow(color: tokens.shadow, blurRadius: 24)],
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.layers_outlined,
                    color: Theme.of(context).primaryColor),
                SizedBox(width: context.spacingSmall),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '添加与管理配置',
                        style: TextStyle(
                          color: tokens.textPrimary,
                          fontSize: context.fontLarge,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '新建、导入或管理已有组网配置',
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontSize: context.fontSmall,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('dashboard-config-panel-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            SizedBox(height: context.spacingMedium),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('dashboard-config-panel-create'),
                    onPressed: () => Navigator.of(context).pop(
                      DashboardConfigPanelAction.create,
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('新建配置'),
                  ),
                ),
                SizedBox(width: context.spacingSmall),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('dashboard-config-panel-import'),
                    onPressed: () => Navigator.of(context).pop(
                      DashboardConfigPanelAction.import,
                    ),
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('导入配置'),
                  ),
                ),
              ],
            ),
            if (!widget.supportsMultipleConnections && _configs.length > 1)
              Container(
                key: const ValueKey('dashboard-single-vpn-notice'),
                width: double.infinity,
                margin: EdgeInsets.only(top: context.spacingSmall),
                padding: EdgeInsets.all(context.spacingSmall),
                decoration: BoxDecoration(
                  color: AppTheme.warningColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(context.cardRadius),
                  border: Border.all(
                    color: AppTheme.warningColor.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  'Android / iOS 受系统单 VPN 通道限制，一次只能连接一个配置。',
                  style: TextStyle(
                    color: tokens.textPrimary,
                    fontSize: context.fontSmall,
                  ),
                ),
              ),
            if (orderError != null)
              Padding(
                padding: EdgeInsets.only(top: context.spacingSmall),
                child: Text(
                  orderError.message,
                  style: TextStyle(
                    color: AppTheme.errorColor,
                    fontSize: context.fontSmall,
                  ),
                ),
              ),
            SizedBox(height: context.spacingMedium),
            Expanded(
              child: _configs.isEmpty
                  ? Center(
                      child: Text(
                        '暂无配置，请点击上方按钮新建或导入。',
                        style: TextStyle(color: tokens.textSecondary),
                      ),
                    )
                  : ReorderableListView.builder(
                      key: const ValueKey('dashboard-config-list'),
                      buildDefaultDragHandles: false,
                      itemCount: _configs.length,
                      // Flutter 3.44 已提供 onReorderItem，但当前项目仍需兼容
                      // 尚未暴露该参数的旧 Flutter SDK。
                      // ignore: deprecated_member_use
                      onReorder: _reorder,
                      proxyDecorator: (child, index, animation) => Material(
                        color: Colors.transparent,
                        elevation: 8,
                        borderRadius: BorderRadius.circular(context.cardRadius),
                        child: child,
                      ),
                      itemBuilder: (context, index) => _buildConfigCard(
                        _configs[index],
                        index,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigCard(NetworkConfig config, int index) {
    final tokens = context.themeTokens;
    final primaryColor = Theme.of(context).primaryColor;
    final isConnected = widget.isConnected?.call(config) ??
        _manager.hasConnectionItem(config.itemKey);
    final isConnecting = _manager.isConnectingItem(config.itemKey);
    final isBusy = _busyKeys.contains(config.itemKey) || isConnecting;
    final result = _actionResults[config.itemKey];
    final statusColor = isConnected
        ? AppTheme.successColor
        : isConnecting
            ? AppTheme.warningColor
            : tokens.textSecondary;

    return Card(
      key: ValueKey('dashboard-config-card-${config.itemKey}'),
      margin: EdgeInsets.only(bottom: context.spacingSmall),
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.cardRadius),
        side: BorderSide(
          color: isConnected
              ? primaryColor.withValues(alpha: 0.55)
              : tokens.outline,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.spacingMedium),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReorderableDragStartListener(
              key: ValueKey('dashboard-config-drag-${config.itemKey}'),
              index: index,
              child: Padding(
                padding: EdgeInsets.only(
                  right: context.spacingSmall,
                  top: context.spacingXSmall,
                ),
                child: Icon(Icons.drag_indicator, color: tokens.textSecondary),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      SizedBox(width: context.spacingXSmall),
                      Expanded(
                        child: Text(
                          config.configName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tokens.textPrimary,
                            fontSize: context.fontMedium,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        isConnected
                            ? '已连接'
                            : isConnecting
                                ? '连接中'
                                : '未连接',
                        style: TextStyle(
                          color: statusColor,
                          fontSize: context.fontSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.spacingXSmall),
                  Text(
                    '${config.deviceName} · ${config.serverAddress}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tokens.textSecondary,
                      fontSize: context.fontSmall,
                    ),
                  ),
                  SizedBox(height: context.spacingSmall),
                  Wrap(
                    spacing: context.spacingXSmall,
                    runSpacing: context.spacingXSmall,
                    children: [
                      if (isConnected)
                        OutlinedButton.icon(
                          key: ValueKey(
                              'dashboard-config-disconnect-${config.itemKey}'),
                          onPressed: isBusy
                              ? null
                              : () => _runAction(
                                    config,
                                    widget.onDisconnect,
                                  ),
                          icon: const Icon(Icons.link_off, size: 18),
                          label: const Text('断开'),
                        )
                      else
                        FilledButton.icon(
                          key: ValueKey(
                              'dashboard-config-connect-${config.itemKey}'),
                          onPressed: isBusy
                              ? null
                              : () => _runAction(config, widget.onConnect),
                          icon: isBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow, size: 18),
                          label: Text(isBusy ? '连接中' : '连接'),
                        ),
                      IconButton.outlined(
                        key:
                            ValueKey('dashboard-config-edit-${config.itemKey}'),
                        onPressed: isBusy ? null : () => _edit(config),
                        tooltip: '编辑配置',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    ],
                  ),
                  if (result != null) ...[
                    SizedBox(height: context.spacingXSmall),
                    Text(
                      result.message,
                      style: TextStyle(
                        color: result.isSuccess
                            ? AppTheme.successColor
                            : AppTheme.errorColor,
                        fontSize: context.fontSmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

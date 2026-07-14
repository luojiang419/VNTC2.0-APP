import 'package:flutter/material.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';
import 'package:vnt_app/utils/responsive_utils.dart';

/// 连接状态卡片
class StatusCard extends StatelessWidget {
  final bool isConnected;
  final int connectionCount;
  final VoidCallback? onDisconnectAll;

  const StatusCard({
    super.key,
    required this.isConnected,
    required this.connectionCount,
    this.onDisconnectAll,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.themeTokens;
    final foregroundColor = isConnected ? Colors.white : tokens.textPrimary;

    return Container(
      width: double.infinity,
      padding: ResponsiveUtils.padding(context, all: 20),
      decoration: BoxDecoration(
        gradient: isConnected
            ? const LinearGradient(
                colors: [AppTheme.successColor, Color(0xFF2ECC71)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : LinearGradient(
                colors: [tokens.surfaceRaised, tokens.surface],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(context.radius(20)),
        border: Border.all(
          color: isConnected
              ? AppTheme.successColor.withValues(alpha: 0.45)
              : tokens.outline,
        ),
        boxShadow: [
          BoxShadow(
            color: isConnected
                ? AppTheme.successColor.withValues(alpha: 0.3)
                : tokens.shadow,
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          // 状态图标
          Container(
            width: context.w(64),
            height: context.w(64),
            decoration: BoxDecoration(
              color: foregroundColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(context.radius(16)),
            ),
            child: Icon(
              isConnected ? Icons.wifi : Icons.wifi_off,
              color: foregroundColor,
              size: context.iconLarge,
            ),
          ),
          SizedBox(width: context.spacing(16)),

          // 状态文字
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isConnected ? '已连接' : '未连接',
                  style: TextStyle(
                    fontSize: context.fontXLarge,
                    fontWeight: FontWeight.bold,
                    color: foregroundColor,
                  ),
                ),
                SizedBox(height: context.spacing(4)),
                Text(
                  isConnected ? '$connectionCount 个活动连接' : '点击配置开始连接',
                  style: TextStyle(
                    fontSize: context.fontBody,
                    color: foregroundColor.withValues(alpha: 0.78),
                  ),
                ),
              ],
            ),
          ),

          // 断开按钮
          if (isConnected && onDisconnectAll != null)
            IconButton(
              onPressed: onDisconnectAll,
              icon: Container(
                width: context.w(40),
                height: context.w(40),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(context.radius(10)),
                ),
                child: Icon(
                  Icons.power_settings_new,
                  color: Colors.white,
                  size: context.iconSmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/widgets/app_glow_surface.dart';
import 'package:vnt_app/utils/responsive_utils.dart';

/// 统计数据卡片
class StatsCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const StatsCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AppGlowSurface(
      padding: ResponsiveUtils.padding(context, all: 16),
      borderRadius: BorderRadius.circular(context.radius(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: context.w(36),
                height: context.w(36),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(context.radius(10)),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: context.iconSmall,
                ),
              ),
              const Spacer(),
            ],
          ),
          SizedBox(height: context.spacing(12)),
          Text(
            value,
            style: TextStyle(
              fontSize: context.fontLarge,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
            ),
          ),
          SizedBox(height: context.spacing(4)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.fontSmall,
              color: context.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

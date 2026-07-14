import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vnt_app/theme/app_theme_tokens.dart';

/// 统一的模块表面：提供主题化背景、细边框、柔和投影和克制微光。
class AppGlowSurface extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final bool raised;
  final bool active;
  final bool pulse;
  final VoidCallback? onTap;

  const AppGlowSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.raised = false,
    this.active = false,
    this.pulse = false,
    this.onTap,
  });

  @override
  State<AppGlowSurface> createState() => _AppGlowSurfaceState();
}

class _AppGlowSurfaceState extends State<AppGlowSurface>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant AppGlowSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse != widget.pulse || oldWidget.active != widget.active) {
      _syncPulse();
    }
  }

  void _syncPulse() {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.pulse && widget.active && !disableAnimations) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.themeTokens;
    final radius = widget.borderRadius ?? BorderRadius.circular(16);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final wave = widget.pulse
              ? (math.sin(_controller.value * math.pi * 2) + 1) / 2
              : 0.0;
          final glowOpacity = (_hovered ? 0.72 : 0.0) +
              (widget.active ? 0.34 : 0.0) +
              (widget.active && widget.pulse ? wave * 0.22 : 0.0);

          return AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: widget.margin,
            decoration: BoxDecoration(
              color: widget.raised ? tokens.surfaceRaised : tokens.surface,
              borderRadius: radius,
              border: Border.all(
                color: Color.lerp(
                  tokens.outline,
                  Theme.of(context).colorScheme.primary,
                  widget.active || _hovered ? 0.28 : 0,
                )!,
              ),
              boxShadow: [
                BoxShadow(
                  color: tokens.shadow,
                  blurRadius: widget.raised ? 24 : 18,
                  offset: const Offset(0, 8),
                ),
                if (glowOpacity > 0)
                  BoxShadow(
                    color: tokens.glow.withValues(
                      alpha: tokens.glow.a * glowOpacity.clamp(0.0, 1.0),
                    ),
                    blurRadius: 24 + wave * 8,
                    spreadRadius: -3 + wave,
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: radius,
                  child: Padding(
                    padding: widget.padding ?? EdgeInsets.zero,
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

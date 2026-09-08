import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

// ─── Shared painter ──────────────────────────────────────────────────────────

class _GlowRipplePainter extends CustomPainter {
  const _GlowRipplePainter({
    required this.center,
    required this.maxRadius,
    required this.scale,
    required this.opacity,
    required this.color,
    required this.intensity,
  });

  final Offset center;
  final double maxRadius;
  final double scale;
  final double opacity;
  final Color color;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final radius = maxRadius * scale;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: intensity * opacity),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.7],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlowRipplePainter old) =>
      old.scale != scale ||
      old.opacity != opacity ||
      old.center != center ||
      old.intensity != intensity;
}

// ─── Shared animation mixin ───────────────────────────────────────────────────

mixin _GlowRippleMixin<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController rippleCtrl = AnimationController(
    duration: const Duration(milliseconds: 800),
    vsync: this,
  );

  late final Animation<double> rippleScale = Tween<double>(begin: 0.2, end: 2.5)
      .animate(CurvedAnimation(parent: rippleCtrl, curve: Curves.easeOut));

  late final Animation<double> rippleOpacity =
      Tween<double>(begin: 1.0, end: 0.0)
          .animate(CurvedAnimation(parent: rippleCtrl, curve: Curves.easeOut));

  Offset rippleTapPos = Offset.zero;
  Size rippleSize = Size.zero;

  Widget buildRippleOverlay(
    Color color,
    Widget child, {
    double radiusFactor = 1.0,
    double intensity = 0.15,
  }) {
    return AnimatedBuilder(
      animation: rippleCtrl,
      builder: (context, inner) => CustomPaint(
        painter: rippleCtrl.value > 0
            ? _GlowRipplePainter(
                center: rippleTapPos,
                maxRadius:
                    math.max(rippleSize.width, rippleSize.height) *
                    radiusFactor,
                scale: rippleScale.value,
                opacity: rippleOpacity.value,
                color: color,
                intensity: intensity,
              )
            : null,
        child: inner,
      ),
      child: child,
    );
  }

  @override
  void dispose() {
    rippleCtrl.dispose();
    super.dispose();
  }
}

// ─── GlowInkWell ─────────────────────────────────────────────────────────────

/// Drop-in for [GestureDetector] with a glow ripple originating from the tap
/// point and clipped to the widget bounds. Ported from interactionEffects.js.
class GlowInkWell extends StatefulWidget {
  const GlowInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.glowColor,
    this.radiusFactor = 1.0,
    this.intensity = 0.15,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final Color? glowColor;
  final double radiusFactor;
  final double intensity;

  @override
  State<GlowInkWell> createState() => _GlowInkWellState();
}

class _GlowInkWellState extends State<GlowInkWell>
    with SingleTickerProviderStateMixin, _GlowRippleMixin {
  void _handleTapDown(TapDownDetails details) {
    final box = context.findRenderObject() as RenderBox;
    rippleTapPos = details.localPosition;
    rippleSize = box.size;
    rippleCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.glowColor ?? context.cs.primary;

    // Always clip so the glow can never bleed past the widget bounds; a null
    // borderRadius degrades to a plain rectangular clip.
    final Widget inner = ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
      child: buildRippleOverlay(
        color,
        widget.child,
        radiusFactor: widget.radiusFactor,
        intensity: widget.intensity,
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _handleTapDown,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: inner,
    );
  }
}

// ─── GlowRippleOverlay ────────────────────────────────────────────────────────

/// Adds a full-area glow ripple to [child] without consuming pointer events —
/// all [GestureDetector]s in the subtree continue to fire normally.
///
/// Uses [Listener] (non-blocking) to detect touches, so it is safe to wrap
/// a row of interactive buttons (e.g. the glass nav bar).
class GlowRippleOverlay extends StatefulWidget {
  const GlowRippleOverlay({
    super.key,
    required this.child,
    this.glowColor,
    this.borderRadius,
    this.radiusFactor = 1.0,
    this.intensity = 0.15,
  });

  final Widget child;
  final Color? glowColor;

  /// Rounds the clip that keeps the glow inside the surface bounds. The glow is
  /// always clipped; a null value falls back to a plain rectangular clip.
  final BorderRadius? borderRadius;

  /// Scales the ripple's maximum radius (1.0 = full child extent). Lower values
  /// keep the glow tighter around the tap point.
  final double radiusFactor;

  /// Peak alpha of the glow at its center. Higher values read as more vivid.
  final double intensity;

  @override
  State<GlowRippleOverlay> createState() => _GlowRippleOverlayState();
}

class _GlowRippleOverlayState extends State<GlowRippleOverlay>
    with SingleTickerProviderStateMixin, _GlowRippleMixin {
  void _onPointerDown(PointerDownEvent event) {
    final box = context.findRenderObject() as RenderBox;
    rippleTapPos = box.globalToLocal(event.position);
    rippleSize = box.size;
    rippleCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.glowColor ?? context.cs.primary;
    // Always clip so the glow can never bleed past the surface bounds; a null
    // borderRadius degrades to a plain rectangular clip.
    final Widget overlay = ClipRRect(
      borderRadius: widget.borderRadius ?? BorderRadius.zero,
      child: buildRippleOverlay(
        color,
        const SizedBox.expand(),
        radiusFactor: widget.radiusFactor,
        intensity: widget.intensity,
      ),
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(child: overlay),
          ),
        ],
      ),
    );
  }
}

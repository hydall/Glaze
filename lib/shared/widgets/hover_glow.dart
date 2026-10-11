import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Mouse-tracking radial glow — the Flutter port of the Vue `v-hover-glow`
/// directive (`interactionEffects.js`).
///
/// Paints a soft accent-coloured pool of light that follows the cursor across
/// the child, over a flat hover tint. Pointer devices only: on touch the
/// [MouseRegion] never fires, so the child renders exactly as it would have.
class HoverGlow extends StatefulWidget {
  final Widget child;

  /// Glow colour; defaults to the scheme's primary.
  final Color? color;

  /// Flat tint painted under the glow while hovered.
  final double hoverTintAlpha;

  /// Radius of the light pool, in logical pixels.
  final double radius;

  /// Clips the glow to a rounded rectangle. Null keeps square corners.
  final BorderRadius? borderRadius;

  /// Border painted above the child while the pointer is over it — a hover
  /// outline. Null paints none. Shape it with [borderRadius].
  final BoxBorder? hoverBorder;

  /// Inset of [hoverBorder] from the child's edges, so the rounded corners of a
  /// full-bleed row stay clear of the surface's own clipping.
  final EdgeInsets borderInset;

  const HoverGlow({
    super.key,
    required this.child,
    this.color,
    this.hoverTintAlpha = 0.05,
    this.radius = 200,
    this.borderRadius,
    this.hoverBorder,
    this.borderInset = EdgeInsets.zero,
  });

  @override
  State<HoverGlow> createState() => _HoverGlowState();
}

class _HoverGlowState extends State<HoverGlow> {
  Offset? _glowPos;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glow = widget.color ?? scheme.primary;

    Widget stack = Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              color: _hovered
                  ? scheme.onSurface.withValues(alpha: widget.hoverTintAlpha)
                  : Colors.transparent,
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _hovered && _glowPos != null ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
              curve: Curves.ease,
              child: CustomPaint(
                painter: _glowPos == null
                    ? null
                    : RadialGlowPainter(
                        position: _glowPos!,
                        color: glow,
                        radius: widget.radius,
                      ),
              ),
            ),
          ),
        ),
        widget.child,
        if (widget.hoverBorder != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                curve: Curves.ease,
                child: Padding(
                  padding: widget.borderInset,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: widget.hoverBorder,
                      borderRadius: widget.borderRadius,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.borderRadius != null) {
      stack = ClipRRect(borderRadius: widget.borderRadius!, child: stack);
    } else {
      stack = ClipRect(child: stack);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      opaque: false,
      onHover: (e) {
        if (_hovered && _glowPos == e.localPosition) return;
        setState(() {
          _glowPos = e.localPosition;
          _hovered = true;
        });
      },
      onExit: (_) {
        if (!_hovered) return;
        setState(() => _hovered = false);
      },
      child: stack,
    );
  }
}

/// The radial gradient behind [HoverGlow]; kept public so callers that already
/// track hover themselves (e.g. an animated card) can reuse the exact stops.
class RadialGlowPainter extends CustomPainter {
  final Offset position;
  final Color color;
  final double radius;

  const RadialGlowPainter({
    required this.position,
    required this.color,
    this.radius = 200,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shader = ui.Gradient.radial(
      position,
      radius,
      [
        color.withValues(alpha: 0.07),
        color.withValues(alpha: 0.04),
        color.withValues(alpha: 0.015),
        color.withValues(alpha: 0.0),
      ],
      [0.0, 0.38, 0.68, 1.0],
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(RadialGlowPainter old) =>
      old.position != position || old.color != color || old.radius != radius;
}

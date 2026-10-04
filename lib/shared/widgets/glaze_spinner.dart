import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Glaze's loading indicator — a rounded arc that tapers into the accent color
/// and sweeps around a faint track under a soft halo. Used app-wide in place of
/// [CircularProgressIndicator].
///
/// Sizing works like [CircularProgressIndicator]: the arc fills whatever box it
/// is given, so an existing `SizedBox(width: 18, height: 18, child: ...)`
/// wrapper keeps working, and [strokeWidth] scales with the diameter it ends up
/// painting at. Pass [size] to size the spinner itself; with neither a size nor
/// tight constraints it falls back to [defaultSize].
///
/// Pass [value] (0..1) for a determinate arc; leave it null to spin.
class GlazeSpinner extends StatefulWidget {
  const GlazeSpinner({
    super.key,
    this.size,
    this.strokeWidth,
    this.color,
    this.trackColor,
    this.value,
    this.glow = true,
    this.semanticsLabel,
  }) : assert(value == null || (value >= 0.0 && value <= 1.0));

  /// Diameter used when no [size] is given and the parent constraints are not
  /// tight. Matches `CircularProgressIndicator`'s default so swapping the two
  /// never shifts a layout.
  static const double defaultSize = 36;

  /// Outer diameter. Null fills the parent's constraints instead, falling back
  /// to [defaultSize] when they are loose.
  final double? size;

  /// Arc thickness. Null scales with the diameter the arc paints at.
  final double? strokeWidth;

  /// Arc color. Defaults to the color scheme's primary.
  final Color? color;

  /// The ring behind the arc. Null derives a faint tint of [color]; pass
  /// [Colors.transparent] to drop the track entirely.
  final Color? trackColor;

  /// Progress in 0..1 for a determinate arc, or null to spin indefinitely.
  final double? value;

  /// Whether to paint the soft halo around the arc. Turn it off for dense rows
  /// of tiny spinners, where the glow only muddies the shape.
  final bool glow;

  final String? semanticsLabel;

  @override
  State<GlazeSpinner> createState() => _GlazeSpinnerState();
}

class _GlazeSpinnerState extends State<GlazeSpinner>
    with SingleTickerProviderStateMixin {
  /// One grow-and-shrink pass of the arc. The arc's tail travels exactly two
  /// turns per cycle (one from the tail easing, one from the constant spin), so
  /// the angle is continuous across the controller's wrap-around.
  static const _cycle = Duration(milliseconds: 1600);

  /// Arc length at its shortest and longest, in turns.
  static const _minSweepTurns = 0.08;
  static const _maxSweepTurns = 0.82;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Created unconditionally: a lazy controller would have to spin up a ticker
    // from dispose(), which the ticker provider rejects once unmounted.
    _controller = AnimationController(vsync: this, duration: _cycle);
    if (widget.value == null) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant GlazeSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final spinning = widget.value == null;
    if (spinning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!spinning && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final track = widget.trackColor ?? color.withValues(alpha: 0.12 * color.a);
    final stroke = widget.strokeWidth;

    // The painter fills its box, so the box is what decides the diameter: an
    // explicit size pins it, otherwise the parent's constraints do, floored at
    // the default so a loose parent still gets a sensible spinner.
    Widget spinner = ConstrainedBox(
      constraints: widget.size == null
          ? const BoxConstraints(
              minWidth: GlazeSpinner.defaultSize,
              minHeight: GlazeSpinner.defaultSize,
            )
          : BoxConstraints.tightFor(
              width: widget.size,
              height: widget.size,
            ),
      child: RepaintBoundary(
        child: widget.value == null
            ? _buildSpinning(color, track, stroke)
            : _buildProgress(widget.value!, color, track, stroke),
      ),
    );

    if (widget.semanticsLabel != null) {
      spinner = Semantics(label: widget.semanticsLabel, child: spinner);
    }
    return spinner;
  }

  Widget _buildSpinning(Color color, Color track, double? stroke) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // The head runs its full travel over the first half of the cycle, the
        // tail over the second, so the arc grows then shrinks; a constant turn
        // on top keeps it moving while the two are level.
        final head = Curves.easeInOutCubic.transform((t * 2).clamp(0.0, 1.0));
        final tail = Curves.easeInOutCubic.transform(
          (t * 2 - 1).clamp(0.0, 1.0),
        );
        final sweepTurns = _minSweepTurns +
            (head - tail) * (_maxSweepTurns - _minSweepTurns);

        return CustomPaint(
          painter: _GlazeSpinnerPainter(
            startAngle: -math.pi / 2 + (tail + t) * 2 * math.pi,
            sweep: sweepTurns * 2 * math.pi,
            color: color,
            trackColor: track,
            stroke: stroke,
            glow: widget.glow,
            tapered: true,
          ),
        );
      },
    );
  }

  Widget _buildProgress(
    double value,
    Color color,
    Color track,
    double? stroke,
  ) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, shown, _) => CustomPaint(
        painter: _GlazeSpinnerPainter(
          startAngle: -math.pi / 2,
          // A hair of arc at zero keeps the rounded cap visible instead of
          // blinking out of existence.
          sweep: math.max(shown, 0.004) * 2 * math.pi,
          color: color,
          trackColor: track,
          stroke: stroke,
          glow: widget.glow,
          tapered: false,
        ),
      ),
    );
  }
}

class _GlazeSpinnerPainter extends CustomPainter {
  const _GlazeSpinnerPainter({
    required this.startAngle,
    required this.sweep,
    required this.color,
    required this.trackColor,
    required this.stroke,
    required this.glow,
    required this.tapered,
  });

  final double startAngle;
  final double sweep;
  final Color color;
  final Color trackColor;

  /// Explicit arc thickness, or null to scale it with the painted diameter.
  final double? stroke;

  final bool glow;

  /// Whether the arc fades out towards its tail. The indeterminate arc tapers
  /// (it reads as motion); a progress arc stays solid so a full ring has no
  /// seam where the transparent tail would meet the opaque head.
  final bool tapered;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final width = stroke ?? _strokeFor(size.shortestSide);
    // Room for the inner halo pass. Reserving space for the outer one too cost
    // ~20% of the radius and left the spinner visibly smaller than the box it
    // was given; the outer pass is faint enough to bleed a pixel past the
    // bounds instead (nothing clips it).
    final halo = glow ? width * 0.25 : 0.0;
    final radius = (size.shortestSide - width) / 2 - halo;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);

    if (trackColor.a > 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = trackColor,
      );
    }

    if (glow) {
      _paintArc(canvas, rect, radius, width: width * 2.2, alpha: 0.08);
      _paintArc(canvas, rect, radius, width: width * 1.5, alpha: 0.14);
    }
    _paintArc(canvas, rect, radius, width: width, alpha: 1);

    if (glow) _paintHeadGlow(canvas, center, radius, width);
  }

  /// Keeps the arc's weight proportional to its diameter, so a 16 px spinner in
  /// a button and a 96 px one on a blank screen read as the same shape.
  static double _strokeFor(double diameter) =>
      (diameter * 0.115).clamp(1.8, 12.0).toDouble();

  void _paintArc(
    Canvas canvas,
    Rect rect,
    double radius, {
    required double width,
    required double alpha,
  }) {
    final peak = alpha * color.a;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width;

    if (tapered) {
      // The round cap at the tail sticks out behind the arc's start. Angles
      // outside a sweep gradient's range clamp to its end colors, and behind
      // the start means wrapping onto the *far* end — so without a pad of
      // transparent gradient covering the cap it paints at full color, leaving
      // a bright nub floating behind the tail.
      final pad = width / 2 / radius;
      final total = sweep + pad;
      final capStop = pad / total;

      paint.shader = SweepGradient(
        startAngle: 0,
        endAngle: total,
        transform: GradientRotation(startAngle - pad),
        // Fades in over the tail third only: a taper spread across the whole
        // arc left it looking washed out at its longest.
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0),
          color.withValues(alpha: peak * 0.7),
          color.withValues(alpha: peak),
        ],
        stops: [0, capStop, capStop + (1 - capStop) * 0.3, 1],
      ).createShader(rect);
    } else {
      paint.color = color.withValues(alpha: peak);
    }

    canvas.drawArc(rect, startAngle, sweep, false, paint);
  }

  /// A soft bloom on the leading cap — the touch that makes the arc read as lit
  /// rather than drawn.
  void _paintHeadGlow(
    Canvas canvas,
    Offset center,
    double radius,
    double width,
  ) {
    final angle = startAngle + sweep;
    final head = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    final bloom = width * 2;
    final rect = Rect.fromCircle(center: head, radius: bloom);
    canvas.drawCircle(
      head,
      bloom,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.35 * color.a),
            color.withValues(alpha: 0),
          ],
          stops: const [0.2, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlazeSpinnerPainter old) =>
      old.startAngle != startAngle ||
      old.sweep != sweep ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.stroke != stroke ||
      old.glow != glow ||
      old.tapered != tapered;
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import '../theme/ui_scale.dart';

/// The Glaze slider: a slim accent track with a soft fill and a ringed thumb.
///
/// Replaces Material's [Slider], whose step ticks dotted the whole track and
/// whose thumb read as stock Android. [divisions] still snaps the value, but
/// the steps are felt (a selection click per step) rather than drawn. Track
/// and thumb corners follow the UI corner scale, so "square corners" squares
/// the slider too.
///
/// A null [onChanged] renders the disabled state.
class GlazeSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Fill and thumb ring colour; the theme accent when null.
  final Color? activeColor;

  const GlazeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeEnd,
    this.activeColor,
  }) : assert(max > min);

  @override
  State<GlazeSlider> createState() => _GlazeSliderState();
}

class _GlazeSliderState extends State<GlazeSlider>
    with SingleTickerProviderStateMixin {
  static const double _height = 32;
  static const double _thumbSize = 18;

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'GlazeSlider');
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;

  bool get _enabled => widget.onChanged != null;

  double get _fraction {
    final v = widget.value.clamp(widget.min, widget.max);
    return (v - widget.min) / (widget.max - widget.min);
  }

  @override
  void dispose() {
    _press.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double _snap(double raw) {
    final v = raw.clamp(widget.min, widget.max).toDouble();
    final d = widget.divisions;
    if (d == null || d <= 0) return v;
    final step = (widget.max - widget.min) / d;
    return widget.min + ((v - widget.min) / step).round() * step;
  }

  void _emit(double raw) {
    final next = _snap(raw);
    if (next == widget.value) return;
    if (widget.divisions != null) Haptics.selectionClick();
    widget.onChanged?.call(next);
  }

  void _seek(Offset local, double width) {
    final usable = width - _thumbSize;
    if (usable <= 0) return;
    final t = ((local.dx - _thumbSize / 2) / usable).clamp(0.0, 1.0);
    _emit(widget.min + t * (widget.max - widget.min));
  }

  void _start() {
    _dragging = true;
    _press.forward();
    if (_focusNode.canRequestFocus) _focusNode.requestFocus();
  }

  void _end() {
    if (!_dragging) return;
    _dragging = false;
    _press.reverse();
    widget.onChangeEnd?.call(widget.value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    final d = widget.divisions;
    final step = (widget.max - widget.min) / (d != null && d > 0 ? d : 20);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp) {
      _emit(widget.value + step);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown) {
      _emit(widget.value - step);
    } else {
      return KeyEventResult.ignored;
    }
    widget.onChangeEnd?.call(_snap(widget.value));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.activeColor ?? context.cs.primary;
    final scale = context.glazeUiScale;
    return Semantics(
      slider: true,
      enabled: _enabled,
      value: widget.value.toStringAsFixed(0),
      child: Focus(
        focusNode: _focusNode,
        canRequestFocus: _enabled,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Opacity(
            opacity: _enabled ? 1 : 0.4,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: _enabled
                      ? (d) {
                          _start();
                          _seek(d.localPosition, width);
                        }
                      : null,
                  onTapUp: _enabled ? (_) => _end() : null,
                  onTapCancel: _enabled ? _end : null,
                  onHorizontalDragStart: _enabled
                      ? (d) {
                          _start();
                          _seek(d.localPosition, width);
                        }
                      : null,
                  onHorizontalDragUpdate: _enabled
                      ? (d) => _seek(d.localPosition, width)
                      : null,
                  onHorizontalDragEnd: _enabled ? (_) => _end() : null,
                  onHorizontalDragCancel: _enabled ? _end : null,
                  child: AnimatedBuilder(
                    animation: _press,
                    builder: (context, _) => CustomPaint(
                      size: Size(width, _height),
                      painter: _GlazeSliderPainter(
                        fraction: _fraction,
                        accent: accent,
                        track: context.cs.onSurface.withValues(alpha: 0.08),
                        trackBorder: context.cs.outlineVariant,
                        thumbFill: context.cs.surface,
                        press: _press.value,
                        highlight: _enabled && (_hovered || _focused),
                        trackRadius: scale.radius(3).clamp(0.0, 3.0),
                        thumbRadius: scale
                            .radius(_thumbSize / 2)
                            .clamp(0.0, _thumbSize / 2),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _GlazeSliderPainter extends CustomPainter {
  final double fraction;
  final Color accent;
  final Color track;
  final Color trackBorder;
  final Color thumbFill;
  final double press;
  final bool highlight;
  final double trackRadius;
  final double thumbRadius;

  const _GlazeSliderPainter({
    required this.fraction,
    required this.accent,
    required this.track,
    required this.trackBorder,
    required this.thumbFill,
    required this.press,
    required this.highlight,
    required this.trackRadius,
    required this.thumbRadius,
  });

  static const double _trackHeight = 6;
  static const double _thumb = _GlazeSliderState._thumbSize;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final left = _thumb / 2;
    final right = size.width - _thumb / 2;
    final cx = left + (right - left) * fraction;

    final trackRect = Rect.fromLTRB(
      left - _trackHeight / 2,
      cy - _trackHeight / 2,
      right + _trackHeight / 2,
      cy + _trackHeight / 2,
    );
    final trackR = Radius.circular(trackRadius);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, trackR),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, trackR).deflate(0.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = trackBorder,
    );

    final fillRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      cx,
      trackRect.bottom,
    );
    if (fillRect.width > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, trackR),
        Paint()
          ..shader = LinearGradient(
            colors: [accent.withValues(alpha: 0.55), accent],
          ).createShader(fillRect),
      );
    }

    // Halo while hovered / held.
    final glow = (highlight ? 0.5 : 0.0) + press * 0.5;
    final grow = 1 + press * 0.18;
    final half = _thumb / 2 * grow;
    final r = thumbRadius * grow;
    if (glow > 0) {
      final haloHalf = half + 7 * glow;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, cy),
            width: haloHalf * 2,
            height: haloHalf * 2,
          ),
          Radius.circular(r + 7 * glow),
        ),
        Paint()..color = accent.withValues(alpha: 0.16 * glow),
      );
    }

    final thumbRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: half * 2,
        height: half * 2,
      ),
      Radius.circular(r),
    );
    canvas.drawRRect(
      thumbRect.shift(const Offset(0, 1.5)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(thumbRect, Paint()..color = thumbFill);
    canvas.drawRRect(
      thumbRect.deflate(1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent,
    );
    // Accent core so the thumb reads as "on" rather than an empty ring.
    final core = half * 0.32;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy),
          width: core * 2,
          height: core * 2,
        ),
        Radius.circular(r * 0.32),
      ),
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(_GlazeSliderPainter old) =>
      old.fraction != fraction ||
      old.accent != accent ||
      old.track != track ||
      old.trackBorder != trackBorder ||
      old.thumbFill != thumbFill ||
      old.press != press ||
      old.highlight != highlight ||
      old.trackRadius != trackRadius ||
      old.thumbRadius != thumbRadius;
}

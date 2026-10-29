import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// The app's dark theme, reduced to what the setup draws: the same background,
/// surfaces, accent and font (lib/shared/theme/app_theme.dart).
abstract final class SetupColors {
  static const background = Color(0xFF19191A);
  static const surface = Color(0xFF1E1E1E);
  static const surfaceHigh = Color(0xFF242426);
  static const accent = Color(0xFFC42A4A);
  static const text = Color(0xFFE1E3E6);
  static const muted = Color(0xFF828282);
  static const error = Color(0xFFCF6679);
  static const success = Color(0xFF4CAF7A);
}

ThemeData setupTheme() {
  final scheme = const ColorScheme.dark(
    primary: SetupColors.accent,
    onPrimary: Colors.white,
    surface: SetupColors.background,
    onSurface: SetupColors.text,
    onSurfaceVariant: SetupColors.muted,
    error: SetupColors.error,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: SetupColors.background,
    splashFactory: InkSparkle.splashFactory,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? SetupColors.accent
            : const Color(0xFFE0E0E0),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? SetupColors.accent.withValues(alpha: 0.35)
            : const Color(0xFF3A3A3C),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? SetupColors.accent
            : Colors.transparent,
      ),
      side: const BorderSide(color: SetupColors.muted, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
  );
}

/// A rounded, faintly bordered panel — the app's grouped-menu surface.
class SetupPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? tint;

  const SetupPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.tint,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: tint ?? SetupColors.surface.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    ),
    child: child,
  );
}

enum SetupButtonTone { primary, neutral, destructive }

/// The app's action button (GlazeActionButton): a tinted glass pill with an
/// icon, lit on hover.
class SetupButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final SetupButtonTone tone;
  final bool large;

  const SetupButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.tone = SetupButtonTone.neutral,
    this.large = false,
  });

  @override
  State<SetupButton> createState() => _SetupButtonState();
}

class _SetupButtonState extends State<SetupButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final accent = switch (widget.tone) {
      SetupButtonTone.primary => SetupColors.accent,
      SetupButtonTone.neutral => SetupColors.text,
      SetupButtonTone.destructive => SetupColors.error,
    };
    final filled = widget.tone == SetupButtonTone.primary;
    final fill = filled
        ? Color.lerp(
            SetupColors.accent,
            Colors.white,
            _hover && enabled ? 0.08 : 0,
          )!
        : accent.withValues(alpha: _hover && enabled ? 0.12 : 0.06);
    final foreground = filled ? Colors.white : accent;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = _down = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(
                horizontal: widget.large ? 26 : 18,
                vertical: widget.large ? 13 : 10,
              ),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: filled
                      ? Colors.white.withValues(alpha: 0.12)
                      : accent.withValues(alpha: 0.22),
                ),
                boxShadow: filled && enabled
                    ? [
                        BoxShadow(
                          color: SetupColors.accent.withValues(
                            alpha: _hover ? 0.45 : 0.28,
                          ),
                          blurRadius: _hover ? 24 : 16,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 17, color: foreground),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: widget.large ? 14.5 : 13,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The slow, soft glow behind every page: two blurred accent blobs drifting.
class AmbientGlow extends StatefulWidget {
  /// 0 to 1: how lit the room is. Rises while working, peaks when done.
  final double intensity;
  final Color color;

  const AmbientGlow({
    super.key,
    this.intensity = 0.5,
    this.color = SetupColors.accent,
  });

  @override
  State<AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<AmbientGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: widget.intensity),
    duration: const Duration(milliseconds: 900),
    curve: Curves.easeOutCubic,
    builder: (context, intensity, _) => TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.color),
      duration: const Duration(milliseconds: 700),
      builder: (context, color, _) => AnimatedBuilder(
        animation: _drift,
        builder: (context, _) => CustomPaint(
          painter: _GlowPainter(
            t: _drift.value,
            intensity: intensity,
            color: color ?? widget.color,
          ),
          size: Size.infinite,
        ),
      ),
    ),
  );
}

class _GlowPainter extends CustomPainter {
  final double t;
  final double intensity;
  final Color color;

  _GlowPainter({required this.t, required this.intensity, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    void blob(double x, double y, double r, double alpha) {
      final center = Offset(size.width * x, size.height * y);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha * intensity),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: r))
          ..blendMode = BlendMode.plus,
      );
    }

    blob(
      0.18 + 0.06 * math.sin(a),
      0.15 + 0.05 * math.cos(a * 2),
      size.shortestSide * 0.9,
      0.22,
    );
    blob(
      0.92 + 0.05 * math.cos(a),
      0.95 + 0.06 * math.sin(a),
      size.shortestSide * 0.75,
      0.14,
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.t != t || old.intensity != intensity || old.color != color;
}

/// Blurs what is behind it — the glass of the app's panels.
class Frost extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;

  const Frost({
    super.key,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(18)),
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: radius,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: child,
    ),
  );
}

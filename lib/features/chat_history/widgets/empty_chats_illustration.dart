import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';

/// The empty dialog list's illustration: two chat bubbles — a muted "their"
/// bubble with placeholder lines and an accent "your" bubble that is typing,
/// i.e. the conversation waiting to happen. The bubbles slide in once on
/// mount and then stay still: an idle loop on an empty screen distracts.
class EmptyChatsIllustration extends StatelessWidget {
  const EmptyChatsIllustration({super.key});

  static const _curve = Cubic(0.2, 0.8, 0.2, 1);

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      builder: (context, t, _) {
        // The reply lands a beat after the incoming bubble.
        final back = _curve.transform(const Interval(0, 0.7).transform(t));
        final front = _curve.transform(const Interval(0.25, 1).transform(t));
        return SizedBox(
          width: 200,
          height: 160,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 14 - 16 * (1 - back),
                top: 22 + 10 * (1 - back),
                child: Opacity(
                  opacity: back,
                  child: _BackBubble(color: cs.onSurfaceVariant),
                ),
              ),
              Positioned(
                right: 18 - 16 * (1 - front),
                bottom: 26 - 10 * (1 - front),
                child: Opacity(
                  opacity: front,
                  child: Transform.scale(
                    scale: 0.85 + 0.15 * front,
                    child: _FrontBubble(
                      color: cs.primary,
                      dotColor: cs.onPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BackBubble extends StatelessWidget {
  final Color color;

  const _BackBubble({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomRight: Radius.circular(20),
          bottomLeft: Radius.circular(5),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(width: 72, color: color.withValues(alpha: 0.35)),
          const SizedBox(height: 8),
          _Line(width: 46, color: color.withValues(alpha: 0.22)),
        ],
      ),
    );
  }
}

class _FrontBubble extends StatelessWidget {
  final Color color;
  final Color dotColor;

  const _FrontBubble({required this.color, required this.dotColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.25)!],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(5),
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, alpha) in const [1.0, 0.7, 0.4].indexed)
            Container(
              width: 7,
              height: 7,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
              decoration: BoxDecoration(
                color: dotColor.withValues(alpha: alpha),
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final double width;
  final Color color;

  const _Line({required this.width, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

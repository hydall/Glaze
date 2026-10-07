import 'dart:math';

import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import 'typing_dots.dart';

/// The empty dialog list's illustration: two drifting chat bubbles — a muted "their" bubble with placeholder lines and an accent
/// "your" bubble that is typing, i.e. the conversation waiting to happen.
class EmptyChatsIllustration extends StatefulWidget {
  const EmptyChatsIllustration({super.key});

  @override
  State<EmptyChatsIllustration> createState() => _EmptyChatsIllustrationState();
}

class _EmptyChatsIllustrationState extends State<EmptyChatsIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..repeat();

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
      ),
      child: SizedBox(
        width: 200,
        height: 160,
        child: AnimatedBuilder(
          animation: _float,
          builder: (context, _) {
            final a = _float.value * 2 * pi;
            // Opposite phases, so the bubbles bob past each other.
            final backDy = sin(a) * 4;
            final frontDy = sin(a + pi) * 4;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 14,
                  top: 22 + backDy,
                  child: _BackBubble(color: cs.onSurfaceVariant),
                ),
                Positioned(
                  right: 18,
                  bottom: 26 + frontDy,
                  child: _FrontBubble(
                    color: cs.primary,
                    dotColor: cs.onPrimary,
                  ),
                ),
              ],
            );
          },
        ),
      ),
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
      child: TypingDots(color: dotColor, size: 7),
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

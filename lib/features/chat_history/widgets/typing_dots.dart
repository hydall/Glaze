import 'package:flutter/material.dart';

/// Three dots that pulse in sequence — the "…is typing" indicator shown on a
/// chat-list row while that session is generating a reply. Purely decorative;
/// the driving state lives in `generatingSessionsProvider`.
class TypingDots extends StatefulWidget {
  final Color color;
  final double size;

  const TypingDots({super.key, required this.color, this.size = 6});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.size * 1.8,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(3, (i) {
              // Stagger each dot a third of the cycle apart.
              final phase = (_controller.value - i * 0.2) % 1.0;
              // Ease up then down over the first 60% of the cycle, rest low.
              final t = phase < 0.3
                  ? phase / 0.3
                  : phase < 0.6
                  ? 1 - (phase - 0.3) / 0.3
                  : 0.0;
              final opacity = 0.3 + 0.7 * t;
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? widget.size * 0.6 : 0),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

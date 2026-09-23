import 'package:flutter/material.dart';

/// One button's mark: a Material [icon], or a short [glyph] token when the
/// button stands for characters it types rather than a feature it opens.
///
/// The composer's pair-insert buttons type markdown markers, so they wear the
/// same `**` / `""` tokens the fullscreen editor's format bar draws instead of
/// a lookalike icon. Everywhere a composer action appears — the Actions grid,
/// the pinned row, the "+" sheet and the empty composer's button — goes through
/// here so the mark cannot drift between them.
class ActionGlyph extends StatelessWidget {
  final IconData? icon;
  final String? glyph;
  final double size;
  final Color color;

  const ActionGlyph({
    super.key,
    this.icon,
    this.glyph,
    required this.size,
    required this.color,
  }) : assert(icon != null || glyph != null);

  @override
  Widget build(BuildContext context) {
    final token = glyph;
    if (token != null) {
      return Text(
        token,
        style: TextStyle(
          fontSize: size * 0.85,
          fontWeight: FontWeight.w700,
          letterSpacing: -1,
          height: 1,
          color: color,
        ),
      );
    }
    return Icon(icon, size: size, color: color);
  }
}

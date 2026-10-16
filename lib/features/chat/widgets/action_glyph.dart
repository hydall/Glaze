import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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

  /// An image file drawn in place of [icon] — a plugin's own icon. An SVG
  /// takes [color] like an icon; a raster image keeps its colours. [icon]
  /// stands in when the file cannot be drawn.
  final String? file;
  final double size;
  final Color color;

  const ActionGlyph({
    super.key,
    this.icon,
    this.glyph,
    this.file,
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
    final fallback = Icon(icon, size: size, color: color);
    final path = file;
    if (path == null) return fallback;
    if (path.toLowerCase().endsWith('.svg')) {
      return SvgPicture.file(
        File(path),
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        placeholderBuilder: (_) => SizedBox.square(dimension: size),
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Image.file(
      File(path),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

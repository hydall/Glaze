import 'package:flutter/painting.dart';

double contrastRatio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final lighter = l1 > l2 ? l1 : l2;
  final darker = l1 > l2 ? l2 : l1;
  return (lighter + 0.05) / (darker + 0.05);
}

Color ensureContrast(Color accent, Color surface) {
  if (contrastRatio(accent, surface) >= 4.5) return accent;
  final hsl = HSLColor.fromColor(accent);
  final isDark = surface.computeLuminance() < 0.5;
  double lightness = hsl.lightness;
  for (int i = 0; i < 20; i++) {
    lightness = isDark ? lightness + 0.04 : lightness - 0.04;
    final candidate = HSLColor.fromAHSL(
      1.0,
      hsl.hue,
      hsl.saturation,
      lightness.clamp(0.0, 1.0),
    ).toColor();
    if (contrastRatio(candidate, surface) >= 4.5) return candidate;
  }
  return isDark
      ? HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation, 0.6).toColor()
      : HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation, 0.4).toColor();
}

Color contrastFor(Color bg, {bool secondary = false}) {
  final lum = bg.computeLuminance();
  final light = secondary
      ? const Color(0xFFB0B8C1)
      : const Color(0xFFE1E3E6);
  final dark = const Color(0xFF1A1A1B);
  return lum > 0.5 ? dark : light;
}

Color? ensureTextContrast(Color? text, Color bg) {
  if (text == null) return contrastFor(bg);
  final ratio = contrastRatio(text, bg);
  if (ratio < 2.5) return contrastFor(bg);
  return text;
}

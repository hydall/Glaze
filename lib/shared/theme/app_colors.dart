import 'package:flutter/material.dart';

import '../utils/color_utils.dart';
import 'theme_preset.dart';

class GlazeColors extends ThemeExtension<GlazeColors> {
  final Color accent;
  final Color userBubble;
  final Color charBubble;
  final Color? userText;
  final Color? charText;
  final Color? userQuote;
  final Color? charQuote;
  final Color? userItalic;
  final Color? charItalic;

  const GlazeColors({
    required this.accent,
    required this.userBubble,
    required this.charBubble,
    this.userText,
    this.charText,
    this.userQuote,
    this.charQuote,
    this.userItalic,
    this.charItalic,
  });

  static const dark = GlazeColors(
    accent: Color(0xFF7996CE),
    userBubble: Color(0xFF7996CE),
    charBubble: Color(0xFF1E1E1E),
  );

  static const light = GlazeColors(
    accent: Color(0xFF7996CE),
    userBubble: Color(0xFF7996CE),
    charBubble: Color(0xFFEEEEF0),
  );

  // Defaults matching Glaze JS: italic = gray (#888)
  static const _defaultItalic = Color(0xFF888888);

  // Vue base UI element bg (src/assets/css/base.css: --ui-bg-default-rgb)
  static const _vueUiBg = Color(0xFF1E1E1E);

  /// Build chat/bubble colors straight from a Material 3 [ColorScheme] (used by
  /// the built-in "Material You" theme). The accent and bubble colors track the
  /// dynamic palette; italics stay the neutral gray default.
  static GlazeColors fromColorScheme(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final charBubble = isDark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerHighest;
    return GlazeColors(
      accent: scheme.primary,
      userBubble: scheme.primary,
      charBubble: charBubble,
      userText: scheme.onPrimary,
      charText: scheme.onSurface,
      userQuote: scheme.onPrimary,
      charQuote: scheme.primary,
      userItalic: _defaultItalic,
      charItalic: _defaultItalic,
    );
  }

  static GlazeColors fromPreset(ThemePreset preset, {required bool isDark}) {
    final base = isDark ? dark : light;
    final accent = preset.accent;
    final uiColor = preset.uiColorParsed ??
        (isDark ? _vueUiBg : _deriveUiColor(accent, isDark));
    final effectiveBg = uiColor;

    final userBubble = preset.userBubbleParsed ?? accent;
    final charBubbleRaw = preset.charBubbleParsed ?? base.charBubble;
    final charBubble = _distinctBubble(charBubbleRaw, effectiveBg, isDark);

    // Auto (null) text colors are judged against the bubble *as it actually
    // paints*: the (possibly gradient) color composited over the chat
    // background at the theme's element opacity. Judging the raw opaque color
    // picked dark text for translucent mid-tone bubbles that render much darker
    // on screen — e.g. the default blue user bubble in the dark theme ended up
    // with near-black text that blended into it.
    final op = preset.elementOpacity.clamp(0.0, 1.0);
    final userBubbleVisible = _visibleBubble(
        userBubble, preset.userBubbleGradientParsed, op, effectiveBg);
    final charBubbleVisible = _visibleBubble(
        charBubble, preset.charBubbleGradientParsed, op, effectiveBg);

    return base.copyWith(
      accent: accent,
      userBubble: userBubble,
      charBubble: charBubble,
      userText: _ensureContrast(preset.userTextParsed, userBubbleVisible),
      charText: _ensureContrast(preset.charTextParsed, charBubbleVisible),
      // If preset sets a quote/italic color — use it; otherwise fall back to accent
      userQuote: preset.userQuoteParsed ?? accent,
      charQuote: preset.charQuoteParsed ?? accent,
      userItalic: preset.userItalicParsed ?? _defaultItalic,
      charItalic: preset.charItalicParsed ?? _defaultItalic,
    );
  }

  static Color _deriveUiColor(Color accent, bool isDark) {
    if (isDark) {
      final hsl = HSLColor.fromColor(accent);
      return HSLColor.fromAHSL(
        1.0,
        hsl.hue,
        (hsl.saturation * 0.6).clamp(0.0, 1.0),
        (hsl.lightness * 0.15).clamp(0.02, 0.12),
      ).toColor();
    }
    final hsl = HSLColor.fromColor(accent);
    return HSLColor.fromAHSL(
      1.0,
      hsl.hue,
      (hsl.saturation * 0.3).clamp(0.0, 1.0),
      (0.92 + hsl.lightness * 0.06).clamp(0.9, 0.97),
    ).toColor();
  }

  static Color _distinctBubble(Color bubble, Color bg, bool isDark) {
    final diff = ((bubble.r * 255 - bg.r * 255).abs()).round() +
        ((bubble.g * 255 - bg.g * 255).abs()).round() +
        ((bubble.b * 255 - bg.b * 255).abs()).round();
    if (diff < 60) {
      final factor = isDark ? 1.25 : 0.85;
      return Color.fromARGB(
        (bubble.a * 255).round(),
        (bubble.r * 255 * factor).round().clamp(0, 255),
        (bubble.g * 255 * factor).round().clamp(0, 255),
        (bubble.b * 255 * factor).round().clamp(0, 255),
      );
    }
    return bubble;
  }

  /// The bubble color as it actually paints, used only to pick a readable auto
  /// text color (not for the bubble fill itself): a 2-stop gradient is reduced
  /// to the midpoint of its stops, then alpha-composited over the chat
  /// background at the element opacity.
  static Color _visibleBubble(
    Color solid,
    BubbleGradient? gradient,
    double opacity,
    Color bg,
  ) {
    final base = gradient == null
        ? solid
        : Color.lerp(gradient.color1, gradient.color2, 0.5)!;
    return Color.alphaBlend(base.withValues(alpha: opacity), bg);
  }

  static Color _contrastFor(Color bg) {
    // Perceptual midpoint split: light bubbles get dark text, dark bubbles get
    // light text. The old saturation-biased threshold (0.25 for saturated
    // colors) forced dark text onto saturated mid-tone bubbles, where light
    // text is far more readable.
    return bg.computeLuminance() > 0.5
        ? const Color(0xFF1A1A1B)
        : const Color(0xFFE1E3E6);
  }

  static Color? _ensureContrast(Color? text, Color bg) {
    if (text == null) return _contrastFor(bg);
    final ratio = contrastRatio(text, bg);
    if (ratio < 2.5) return _contrastFor(bg);
    return text;
  }

  @override
  GlazeColors copyWith({
    Color? accent,
    Color? userBubble,
    Color? charBubble,
    Color? userText,
    Color? charText,
    Color? userQuote,
    Color? charQuote,
    Color? userItalic,
    Color? charItalic,
  }) {
    return GlazeColors(
      accent: accent ?? this.accent,
      userBubble: userBubble ?? this.userBubble,
      charBubble: charBubble ?? this.charBubble,
      userText: userText ?? this.userText,
      charText: charText ?? this.charText,
      userQuote: userQuote ?? this.userQuote,
      charQuote: charQuote ?? this.charQuote,
      userItalic: userItalic ?? this.userItalic,
      charItalic: charItalic ?? this.charItalic,
    );
  }

  @override
  GlazeColors lerp(covariant GlazeColors? other, double t) {
    if (other == null) return this;
    return GlazeColors(
      accent: Color.lerp(accent, other.accent, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      charBubble: Color.lerp(charBubble, other.charBubble, t)!,
      userText: Color.lerp(userText, other.userText, t),
      charText: Color.lerp(charText, other.charText, t),
      userQuote: Color.lerp(userQuote, other.userQuote, t),
      charQuote: Color.lerp(charQuote, other.charQuote, t),
      userItalic: Color.lerp(userItalic, other.userItalic, t),
      charItalic: Color.lerp(charItalic, other.charItalic, t),
    );
  }
}

extension GlazeColorsX on BuildContext {
  GlazeColors get colors => Theme.of(this).extension<GlazeColors>() ?? GlazeColors.dark;
  ColorScheme get cs => Theme.of(this).colorScheme;
}

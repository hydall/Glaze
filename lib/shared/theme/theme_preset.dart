import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'theme_preset.freezed.dart';
part 'theme_preset.g.dart';

/// Id of the built-in "Material You" standard theme. Its palette is driven by
/// the system dynamic color (Android) or a seed fallback elsewhere and cannot
/// be edited — only fonts and background/element effects are customisable.
const String kMaterialYouPresetId = 'material_you';

@Freezed(fromJson: true, toJson: true)
abstract class ThemePreset with _$ThemePreset {
  const factory ThemePreset({
    required String id,
    required String name,
    @Default('') String author,
    @Default('dark') String themeMode,
    @Default('#7996CE') String accentColor,
    @Default(0.85) double bgOpacity,
    @Default(0) double bgBlur,
    @Default(0.8) double elementOpacity,
    @Default(12) double elementBlur,
    String? uiColor,
    String? bgColor,
    @Default('default') String chatLayout,
    String? userBubbleColor,
    String? charBubbleColor,
    // Optional bubble gradients. When non-empty, the bubble is painted with a
    // 2-stop linear gradient instead of the solid `*BubbleColor`. Encoded as
    // "angle|#hex1|#hex2" (angle in CSS degrees, 0 = upward, clockwise).
    String? userBubbleGradient,
    String? charBubbleGradient,
    String? userQuoteColor,
    String? charQuoteColor,
    String? userTextColor,
    String? charTextColor,
    String? userItalicColor,
    String? charItalicColor,
    @Default('system') dynamic uiFontSize,
    @Default(400) int uiFontWeight,
    @Default(0) double uiLetterSpacing,
    @Default('system') dynamic chatFontSize,
    @Default(400) int userMessageFontWeight,
    @Default(400) int charMessageFontWeight,
    @Default(0) double chatLetterSpacing,
    String? customFont,
    String? customFontName,
    String? chatFont,
    String? chatFontName,
    String? googleFontName,
    String? chatGoogleFontName,
    @Default('glaze') String uiFontMode,
    @Default('ui') String chatFontMode,
    String? uiTextColor,
    String? uiTextGrayColor,
    @Default(1) double borderWidth,
    String? borderColor,
    @Default(0.1) double borderOpacity,
    @Default(18) double userBubbleRadius,
    @Default(18) double charBubbleRadius,
    @Default(true) bool showUserAvatar,
    @Default(true) bool showCharAvatar,
    @Default(true) bool showUserName,
    @Default(true) bool showCharName,
    bool? hideMessageId,
    bool? hideGenerationTime,
    bool? hideTokenCount,
    @Default(0.03) double noiseOpacity,
    @Default(0.8) double noiseIntensity,
    @Default(0.03) double bgNoiseOpacity,
    @Default(0.4) double bgNoiseIntensity,
    @Default(0) double bgDim,
    String? bgImage,
    // Chat-area background. Independent of the global UI background.
    //   'inherit' → reuse the global background (default)
    //   'color'   → solid [chatBgColor]
    //   'avatar'  → the active character's avatar image
    //   'custom'  → a separate [chatBgImage] data URI
    @Default('inherit') String chatBgMode,
    String? chatBgColor,
    String? chatBgImage,
    // Desktop-only: semi-transparent backdrop behind each message body in
    // layout-default so text stays readable over vivid background images.
    // 0.0 = fully transparent (default, preserves current look on mobile).
    @Default(0.0) double textBgOpacity,
  }) = _ThemePreset;

  factory ThemePreset.fromJson(Map<String, dynamic> json) =>
      _$ThemePresetFromJson(json);
}

/// A parsed 2-stop bubble gradient. [angle] is in CSS degrees
/// (0 = upward, increasing clockwise).
class BubbleGradient {
  final double angle;
  final Color color1;
  final Color color2;

  const BubbleGradient(this.angle, this.color1, this.color2);

  /// Encode back to the "angle|#hex1|#hex2" storage string.
  String encode() => '${angle.round()}|${_hexOf(color1)}|${_hexOf(color2)}';

  static String _hexOf(Color c) {
    final r = (c.r * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final g = (c.g * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final b = (c.b * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b'.toUpperCase();
  }
}

extension ThemePresetX on ThemePreset {
  Color get accent => _parseHex(accentColor);
  Color? get uiColorParsed => _parseNullableHex(uiColor);
  Color? get bgColorParsed => _parseNullableHex(bgColor);
  Color? get userBubbleParsed => _parseNullableHex(userBubbleColor);
  Color? get charBubbleParsed => _parseNullableHex(charBubbleColor);
  BubbleGradient? get userBubbleGradientParsed =>
      _parseBubbleGradient(userBubbleGradient);
  BubbleGradient? get charBubbleGradientParsed =>
      _parseBubbleGradient(charBubbleGradient);
  LinearGradient? get userBubbleGradientValue =>
      _toLinearGradient(userBubbleGradientParsed);
  LinearGradient? get charBubbleGradientValue =>
      _toLinearGradient(charBubbleGradientParsed);
  Color? get userQuoteParsed => _parseNullableHex(userQuoteColor);
  Color? get charQuoteParsed => _parseNullableHex(charQuoteColor);
  Color? get userTextParsed => _parseNullableHex(userTextColor);
  Color? get charTextParsed => _parseNullableHex(charTextColor);
  Color? get userItalicParsed => _parseNullableHex(userItalicColor);
  Color? get charItalicParsed => _parseNullableHex(charItalicColor);
  Color? get uiTextParsed => _parseNullableHex(uiTextColor);
  Color? get uiTextGrayParsed => _parseNullableHex(uiTextGrayColor);
  Color? get borderParsed => _parseNullableHex(borderColor);
  FontWeight get uiFontWeightValue => _fontWeightFromInt(uiFontWeight);
  FontWeight get userMessageFontWeightValue =>
      _fontWeightFromInt(userMessageFontWeight);
  FontWeight get charMessageFontWeightValue =>
      _fontWeightFromInt(charMessageFontWeight);

  double get chatFontSizeValue {
    final v = chatFontSize;
    if (v is num) return v.toDouble();
    return 14.0;
  }

  double get uiFontSizeValue {
    final v = uiFontSize;
    if (v is num) return v.toDouble();
    return 15.0;
  }

  bool get hasCustomFont => customFont != null && customFont!.isNotEmpty;
  bool get hasChatFont => chatFont != null && chatFont!.isNotEmpty;
  bool get hasBgImage => bgImage != null && bgImage!.isNotEmpty;
  bool get hasChatBgImage => chatBgImage != null && chatBgImage!.isNotEmpty;
  Color? get chatBgColorParsed => _parseNullableHex(chatBgColor);

  /// Built-in "Material You" theme whose colors come from the system dynamic
  /// palette (Android) / seed fallback and are not user-editable.
  bool get isMaterialYou => id == kMaterialYouPresetId;

  /// Built-in standard themes that always exist and cannot be deleted.
  bool get isBuiltIn => id == 'default' || id == kMaterialYouPresetId;
}

Color _parseHex(String hex) {
  final clean = hex.replaceFirst('#', '');
  if (clean.length == 6) {
    return Color(int.parse('FF$clean', radix: 16));
  }
  if (clean.length == 8) {
    return Color(int.parse(clean, radix: 16));
  }
  return const Color(0xFF7996CE);
}

Color? _parseNullableHex(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  return _parseHex(hex);
}

BubbleGradient? _parseBubbleGradient(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final parts = raw.split('|');
  if (parts.length != 3) return null;
  final angle = double.tryParse(parts[0]);
  final c1 = _parseNullableHex(parts[1]);
  final c2 = _parseNullableHex(parts[2]);
  if (angle == null || c1 == null || c2 == null) return null;
  return BubbleGradient(angle, c1, c2);
}

/// Convert a [BubbleGradient] into a Flutter [LinearGradient] whose direction
/// mirrors the CSS `linear-gradient(<angle>deg, …)` convention so the in-app
/// preview matches the WebView rendering.
LinearGradient? _toLinearGradient(BubbleGradient? g) {
  if (g == null) return null;
  final rad = g.angle * math.pi / 180.0;
  // CSS angle: 0deg points up (gradient line toward the last stop), clockwise.
  // Screen y grows downward, so the direction vector is (sin, -cos).
  final dx = math.sin(rad);
  final dy = -math.cos(rad);
  return LinearGradient(
    begin: Alignment(-dx, -dy),
    end: Alignment(dx, dy),
    colors: [g.color1, g.color2],
  );
}

FontWeight _fontWeightFromInt(int value) {
  const weights = <int, FontWeight>{
    100: FontWeight.w100,
    200: FontWeight.w200,
    300: FontWeight.w300,
    400: FontWeight.w400,
    500: FontWeight.w500,
    600: FontWeight.w600,
    700: FontWeight.w700,
    800: FontWeight.w800,
    900: FontWeight.w900,
  };
  final normalized = (value ~/ 100) * 100;
  return weights[normalized.clamp(100, 900)] ?? FontWeight.w400;
}

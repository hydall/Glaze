import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../utils/color_utils.dart';
import 'app_colors.dart';
import 'theme_preset.dart';

const String kInterFontFamily = 'Inter';

TextTheme _applySafe(TextTheme theme, {
  required Color bodyColor,
  required Color displayColor,
  required double fontSizeFactor,
  required double letterSpacingDelta,
  required FontWeight fontWeight,
}) {
  TextStyle? scale(TextStyle? s) {
    if (s == null) return null;
    return s.copyWith(
      color: s.color ?? bodyColor,
      fontSize: s.fontSize != null ? s.fontSize! * fontSizeFactor : null,
      letterSpacing: (s.letterSpacing ?? 0) + letterSpacingDelta,
      fontWeight: fontWeight,
      // The bundled Inter font is a variable font loaded at runtime, which
      // ignores `fontWeight` — its weight axis must be driven explicitly via
      // `fontVariations`. Harmless for static fonts (the axis is simply unused).
      fontVariations: [FontVariation('wght', fontWeight.value.toDouble())],
    );
  }

  return TextTheme(
    displayLarge: scale(theme.displayLarge),
    displayMedium: scale(theme.displayMedium),
    displaySmall: scale(theme.displaySmall),
    headlineLarge: scale(theme.headlineLarge),
    headlineMedium: scale(theme.headlineMedium),
    headlineSmall: scale(theme.headlineSmall),
    titleLarge: scale(theme.titleLarge),
    titleMedium: scale(theme.titleMedium),
    titleSmall: scale(theme.titleSmall),
    bodyLarge: scale(theme.bodyLarge),
    bodyMedium: scale(theme.bodyMedium),
    bodySmall: scale(theme.bodySmall),
    labelLarge: scale(theme.labelLarge),
    labelMedium: scale(theme.labelMedium),
    labelSmall: scale(theme.labelSmall),
  );
}

// Vue base colors (src/assets/css/base.css, variables.css)
const _vueAppBg = Color(0xFF19191A); // --app-bg / --vk-header-bg
const _vueUiBg = Color(0xFF1E1E1E); // --ui-bg-default-rgb: 30,30,30

ColorScheme _buildColorScheme(ThemePreset preset, {required bool isDark}) {
  final accent = preset.accent;
  final uiColor =
      preset.uiColorParsed ?? (isDark ? _vueUiBg : _deriveUiColor(accent, isDark));
  final bgColor =
      preset.bgColorParsed ?? (isDark ? _vueAppBg : uiColor);
  final onBg = contrastFor(uiColor);
  final onBgVariant = contrastFor(uiColor, secondary: true);
  final surfaceHigh = uiColor;
  final outlineColor = _borderFor(uiColor, isDark);
  final outlineVariant = isDark
      ? Colors.white.withValues(alpha: 0.1)
      : Colors.black.withValues(alpha: 0.1);
  final btnFg = accent.computeLuminance() > 0.35
      ? const Color(0xFF1A1A1B)
      : const Color(0xFFE1E3E6);

  const defaultSecondary = Color(0xFF828282);
  return ColorScheme(
    brightness: isDark ? Brightness.dark : Brightness.light,
    primary: accent,
    onPrimary: btnFg,
    secondary: defaultSecondary,
    onSecondary: Colors.white,
    tertiary: accent,
    onTertiary: btnFg,
    error: const Color(0xFFCF6679),
    onError: Colors.white,
    surface: bgColor,
    onSurface: onBg,
    // Neutralize M3 surface tint so all surface roles stay free of accent blue.
    surfaceTint: bgColor,
    // Explicitly pin every surface container role to uiColor — otherwise
    // ColorScheme derives them via surface + surfaceTint blending and
    // sheets/dialogs end up accent-tinted (e.g. blue-tinted #14141C over #19191A).
    surfaceDim: bgColor,
    surfaceBright: surfaceHigh,
    surfaceContainerLowest: bgColor,
    surfaceContainerLow: surfaceHigh,
    surfaceContainer: surfaceHigh,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHigh,
    onSurfaceVariant: onBgVariant,
    outline: outlineColor,
    outlineVariant: outlineVariant,
  );
}

/// Seed used by the "Material You" theme when the system does not provide a
/// dynamic palette (non-Android platforms, older Android).
const _materialYouFallbackSeed = Color(0xFF7996CE);

/// Resolve the Material 3 [ColorScheme] for the built-in "Material You" theme.
/// On Android [dynamicScheme] is the system palette; everywhere else (or when
/// unavailable) it falls back to a seeded tonal palette so the theme still
/// renders consistently.
ColorScheme _materialYouScheme(ColorScheme? dynamicScheme,
    {required bool isDark}) {
  if (dynamicScheme != null) {
    return dynamicScheme;
  }
  return ColorScheme.fromSeed(
    seedColor: _materialYouFallbackSeed,
    brightness: isDark ? Brightness.dark : Brightness.light,
  );
}

Color _deriveUiColor(Color accent, bool isDark) {
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

Color _ensureButtonContrast(Color accent, Color surface, {required bool isDark}) {
  if (contrastRatio(accent, surface) >= 4.5) return accent;
  final hsl = HSLColor.fromColor(accent);
  double lightness = hsl.lightness;
  for (int i = 0; i < 20; i++) {
    lightness = isDark ? lightness + 0.04 : lightness - 0.04;
    final candidate = HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation, lightness.clamp(0.0, 1.0)).toColor();
    if (contrastRatio(candidate, surface) >= 4.5) return candidate;
  }
  return isDark
      ? HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation, 0.6).toColor()
      : HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation, 0.4).toColor();
}

Color _borderFor(Color bg, bool isDark) {
  final lum = bg.computeLuminance();
  if (isDark) {
    return lum > 0.35
        ? const Color(0xFF5C5D5E)
        : const Color(0xFF2C2D2E);
  }
  return lum > 0.35
      ? const Color(0xFFB8B9BA)
      : const Color(0xFFD8D9DA);
}

class AppTheme {
  static ThemeData dark(ThemePreset preset,
      {String? fontFamily, ColorScheme? dynamicScheme}) {
    final isMaterialYou = preset.isMaterialYou;
    final colorScheme = isMaterialYou
        ? _materialYouScheme(dynamicScheme, isDark: true)
        : _buildColorScheme(preset, isDark: true);
    final effectiveFont = fontFamily;
    final uiSize = preset.uiFontSizeValue;
    final uiSpacing = preset.uiLetterSpacing;
    final uiWeight = preset.uiFontWeightValue;
    final scaleFactor = preset.uiFontSize is num ? uiSize / 15.0 : 1.0;
    final glazeColors = isMaterialYou
        ? GlazeColors.fromColorScheme(colorScheme)
        : GlazeColors.fromPreset(preset, isDark: true);
    final btnBg = _ensureButtonContrast(
        colorScheme.primary, colorScheme.surface, isDark: true);
    final btnFg = btnBg.computeLuminance() > 0.35
        ? const Color(0xFF1A1A1B)
        : const Color(0xFFE1E3E6);

    final base = FlexThemeData.dark(
      colorScheme: colorScheme,
      useMaterial3: true,
      blendLevel: 0,
      subThemesData: const FlexSubThemesData(
        inputDecoratorIsFilled: true,
        inputDecoratorBorderType: FlexInputBorderType.outline,
        cardRadius: 16,
        dialogRadius: 16,
      ),
      visualDensity: VisualDensity.compact,
      fontFamily: effectiveFont,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      canvasColor: colorScheme.surface,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionHandleColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        modalBackgroundColor: colorScheme.surfaceContainerHighest,
        surfaceTintColor: colorScheme.surface,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerHighest,
        surfaceTintColor: colorScheme.surface,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: colorScheme.outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.primary),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: btnBg,
          foregroundColor: btnFg,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return colorScheme.primary;
          return colorScheme.onSurface.withValues(alpha: 0.3);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      textTheme: _applySafe(
        base.textTheme.apply(fontFamily: effectiveFont),
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
        fontSizeFactor: scaleFactor,
        letterSpacingDelta: uiSpacing,
        fontWeight: uiWeight,
      ),
      extensions: [
        glazeColors,
        GptMarkdownThemeData(
          brightness: Brightness.dark,
          highlightColor: colorScheme.primary.withAlpha(40),
          linkColor: colorScheme.primary,
          linkHoverColor: colorScheme.primary.withAlpha(180),
          hrLineColor: colorScheme.outline,
          h1: TextStyle(color: colorScheme.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
          h2: TextStyle(color: colorScheme.onSurface, fontSize: 22, fontWeight: FontWeight.bold),
          h3: TextStyle(color: colorScheme.onSurface, fontSize: 20, fontWeight: FontWeight.w600),
          h4: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
          h5: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 16, fontWeight: FontWeight.w600),
          h6: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  static ThemeData light(ThemePreset preset,
      {String? fontFamily, ColorScheme? dynamicScheme}) {
    final isMaterialYou = preset.isMaterialYou;
    final colorScheme = isMaterialYou
        ? _materialYouScheme(dynamicScheme, isDark: false)
        : _buildColorScheme(preset, isDark: false);
    final effectiveFont = fontFamily;
    final uiSize = preset.uiFontSizeValue;
    final uiSpacing = preset.uiLetterSpacing;
    final uiWeight = preset.uiFontWeightValue;
    final scaleFactor = preset.uiFontSize is num ? uiSize / 15.0 : 1.0;
    final glazeColors = isMaterialYou
        ? GlazeColors.fromColorScheme(colorScheme)
        : GlazeColors.fromPreset(preset, isDark: false);
    final btnBg = _ensureButtonContrast(
        colorScheme.primary, colorScheme.surface, isDark: false);
    final btnFg = btnBg.computeLuminance() > 0.35
        ? const Color(0xFF1A1A1B)
        : const Color(0xFFE1E3E6);

    final base = FlexThemeData.light(
      colorScheme: colorScheme,
      useMaterial3: true,
      blendLevel: 0,
      subThemesData: const FlexSubThemesData(
        inputDecoratorIsFilled: true,
        inputDecoratorBorderType: FlexInputBorderType.outline,
        cardRadius: 16,
        dialogRadius: 16,
      ),
      visualDensity: VisualDensity.compact,
      fontFamily: effectiveFont,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      canvasColor: colorScheme.surface,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionHandleColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        modalBackgroundColor: colorScheme.surfaceContainerHighest,
        surfaceTintColor: colorScheme.surface,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colorScheme.surfaceContainerHighest,
        surfaceTintColor: colorScheme.surface,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: colorScheme.outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colorScheme.primary),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: btnBg,
          foregroundColor: btnFg,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return colorScheme.primary;
          return colorScheme.onSurface.withValues(alpha: 0.3);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      textTheme: _applySafe(
        base.textTheme.apply(fontFamily: effectiveFont),
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
        fontSizeFactor: scaleFactor,
        letterSpacingDelta: uiSpacing,
        fontWeight: uiWeight,
      ),
      extensions: [
        glazeColors,
        GptMarkdownThemeData(
          brightness: Brightness.light,
          highlightColor: colorScheme.primary.withAlpha(40),
          linkColor: colorScheme.primary,
          linkHoverColor: colorScheme.primary.withAlpha(180),
          hrLineColor: colorScheme.outline,
          h1: TextStyle(color: colorScheme.onSurface, fontSize: 24, fontWeight: FontWeight.bold),
          h2: TextStyle(color: colorScheme.onSurface, fontSize: 22, fontWeight: FontWeight.bold),
          h3: TextStyle(color: colorScheme.onSurface, fontSize: 20, fontWeight: FontWeight.w600),
          h4: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
          h5: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 16, fontWeight: FontWeight.w600),
          h6: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

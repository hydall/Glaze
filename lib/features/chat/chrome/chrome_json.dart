import 'package:flutter/material.dart';

import '../../../core/debug/perf_debug.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/theme/theme_preset.dart';
import '../../../shared/theme/ui_scale.dart';
import '../bridge/chat_webview_environment.dart';

/// A colour as the chat chrome reads it: `[r, g, b, a]`, channels 0..255 and
/// alpha 0..1.
List<num> chromeColor(Color c) => [
  (c.r * 255).round(),
  (c.g * 255).round(),
  (c.b * 255).round(),
  double.parse(c.a.toStringAsFixed(4)),
];

/// One button's mark for the chrome — see `drawIcon` in
/// `assets/chat_webview/chrome/ui.js`. The page draws Material glyphs from
/// paths baked into `chrome/icons.js`, keyed by [IconData.codePoint]; a short
/// [glyph] token is drawn as text, and a [file] (a plugin's own icon) as an
/// image served to the page.
Map<String, Object> chromeIcon(IconData icon, {String? glyph, String? file}) {
  if (glyph != null) return {'g': glyph};
  if (file != null) {
    final url = chatWebViewResolveLocalFileUrl(file);
    if (url != null && url.isNotEmpty) {
      return {
        'f': url,
        'svg': file.toLowerCase().endsWith('.svg'),
        'cp': icon.codePoint,
      };
    }
  }
  return {'cp': icon.codePoint};
}

/// Glyphs the chrome draws on its own, without Dart naming them — so the
/// icon coverage test knows they are needed too.
const List<IconData> kChromeOwnIcons = [
  Icons.arrow_back_ios_new_rounded,
  Icons.search,
  Icons.search_rounded,
  Icons.close,
  Icons.close_rounded,
  Icons.keyboard_arrow_up,
  Icons.keyboard_arrow_down,
  Icons.keyboard_double_arrow_up,
  Icons.keyboard_double_arrow_down,
  Icons.visibility,
  Icons.visibility_off,
  Icons.delete,
  Icons.tips_and_updates_outlined,
  Icons.arrow_downward,
  Icons.undo,
  Icons.check,
  Icons.edit_outlined,
  Icons.add,
];

/// Glyphs the composer host names for its own states.
const List<IconData> kChromeComposerIcons = [
  Icons.stop_rounded,
  Icons.check_rounded,
  Icons.send_rounded,
  Icons.account_circle_rounded,
  Icons.undo,
  Icons.extension_rounded,
  Icons.widgets_outlined,
  Icons.auto_awesome,
  Icons.bolt,
];

/// The theme the chat chrome paints with, resolved the way the Flutter
/// widgets it replaced resolved theirs: GlassSurface's tint and blur, the
/// preset's UI text colours, border and type scale, the corner and avatar
/// rounding.
Map<String, Object?> chromeTheme(
  BuildContext context,
  ThemePreset preset, {
  required bool batterySaver,
  required bool desktop,
  String? fontFamily,
}) {
  final cs = context.cs;
  final borderBase = preset.borderParsed ?? cs.onSurface;
  // GlassSurface's fill: its tint (the theme's highest surface container by
  // default) at the preset's element opacity, opaque in battery saver.
  final alpha = batterySaver ? 1.0 : preset.elementOpacity.clamp(0.0, 1.0);
  Color tintOf(Color? tint) => tint == null
      ? cs.surfaceContainerHighest.withValues(alpha: alpha)
      : tint.withValues(alpha: (tint.a * alpha).clamp(0.0, 1.0));
  final header = tintOf(null);
  final surface = tintOf(cs.surface);
  final blur =
      !batterySaver &&
      !PerfDebug.noGlassBlur &&
      preset.elementBlur > 0 &&
      surface.a < 1.0;
  final noise = !batterySaver && !PerfDebug.noNoise && preset.noiseOpacity > 0;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final scale = context.glazeUiScale;
  return {
    'accent': chromeColor(cs.primary),
    'onSurface': chromeColor(cs.onSurface),
    'onSurfaceVariant': chromeColor(cs.onSurfaceVariant),
    'outlineVariant': chromeColor(cs.outlineVariant),
    'outline': chromeColor(cs.outline),
    'surfaceHigh': chromeColor(cs.surfaceContainerHighest),
    'text': chromeColor(preset.uiTextParsed ?? cs.onSurface),
    'text2': chromeColor(preset.uiTextGrayParsed ?? cs.onSurfaceVariant),
    'uiBorder': {
      'c': chromeColor(
        borderBase.withValues(alpha: preset.borderOpacity.clamp(0.0, 1.0)),
      ),
      'w': preset.borderWidth,
    },
    'fillHeader': chromeColor(header),
    'fillSurface': chromeColor(surface),
    'blur': blur,
    'blurSigma': preset.elementBlur,
    'noiseOpacity': noise ? preset.noiseOpacity : 0,
    'noiseIntensity': noise ? preset.noiseIntensity : 0,
    'batterySaver': batterySaver,
    'desktop': desktop,
    'fontScale': preset.uiFontSize is num ? preset.uiFontSizeValue / 15.0 : 1.0,
    'letterSpacing': preset.uiLetterSpacing,
    'cornerScale': scale.cornerScale,
    'avatarRoundness': scale.avatarRoundness,
    'disabled': chromeColor(cs.onSurface.withValues(alpha: 0.38)),
    // Material's tooltip defaults.
    'tipBg': chromeColor(
      dark
          ? Colors.white.withValues(alpha: 0.9)
          : Colors.grey[700]!.withValues(alpha: 0.9),
    ),
    'tipText': chromeColor(dark ? Colors.black : Colors.white),
    // A font the page has no file for (system, Google): asked for by name.
    // The file of a bundled or custom font goes in the 'font' section.
    'fontFamily': fontFamily,
  };
}

/// The 'font' section: the UI font's file as a `data:` URL, or none.
/// [variable] says the file holds every weight (the bundled Inter).
Map<String, Object?> chromeFont(String? dataUrl, {bool variable = false}) {
  if (dataUrl == null || dataUrl.isEmpty) return const {'data': null};
  return {
    'data': dataUrl.startsWith('data:')
        ? dataUrl
        : 'data:font/ttf;base64,$dataUrl',
    if (variable) 'weights': '100 900',
  };
}

List<int> chromeRect(Rect r) => [
  r.left.round(),
  r.top.round(),
  r.width.round(),
  r.height.round(),
];

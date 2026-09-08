import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/theme/theme_preset.dart';

/// Snapshot of the WebView theme inputs collected from the parent
/// [ChatWebViewWidget]. Pure data — the builder does not reach into
/// the widget tree on its own, which makes the same builder usable
/// in widget tests without a full [MaterialApp] ancestor.
class ChatWebViewThemeInput {
  const ChatWebViewThemeInput({
    required this.elementOpacity,
    required this.elementBlur,
    required this.chatFontSize,
    required this.chatLayout,
    required this.bgDim,
    required this.uiFontWeight,
    required this.userMessageFontWeight,
    required this.charMessageFontWeight,
    required this.userBubbleRadius,
    required this.charBubbleRadius,
    required this.showUserAvatar,
    required this.showCharAvatar,
    required this.showUserName,
    required this.showCharName,
    this.userBubbleGradient,
    this.charBubbleGradient,
    this.textBgOpacity = 0.0,
  });

  final double elementOpacity;
  final double elementBlur;
  final double chatFontSize;
  final String? chatLayout;
  final double bgDim;
  final int uiFontWeight;
  final int userMessageFontWeight;
  final int charMessageFontWeight;
  final double userBubbleRadius;
  final double charBubbleRadius;
  final bool showUserAvatar;
  final bool showCharAvatar;
  final bool showUserName;
  final bool showCharName;

  /// When non-null, the bubble is painted with this 2-stop gradient instead
  /// of the solid `*Bubble` color.
  final BubbleGradient? userBubbleGradient;
  final BubbleGradient? charBubbleGradient;

  /// Desktop-only: opacity of the semi-transparent backdrop painted behind
  /// each message body in layout-default. 0.0 = fully transparent (default).
  final double textBgOpacity;
}

/// Builds the `Map<String, String>` that [ChatBridgeController.applyTheme]
/// expects. Pure functions on top of a [BuildContext] and an input
/// snapshot. Extracted from `chat_webview_widget.dart` so the widget
/// can call [build] without owning the color helpers.
class ChatWebViewThemeBuilder {
  const ChatWebViewThemeBuilder._();

  /// Build the theme map for the current `BuildContext` and the
  /// widget's theme-related fields.
  static Map<String, String> build(
    BuildContext context,
    ChatWebViewThemeInput input,
  ) {
    final glaze = context.colors;
    final cs = context.cs;
    final primary = cs.primary;
    final opacity = input.elementOpacity.clamp(0.0, 1.0);
    return {
      'bg-color': _colorHex(cs.surface),
      'text-color': _colorHex(cs.onSurface),
      'ui-bg-rgb': _colorRgb(cs.surface),
      'vk-blue-rgb': _colorRgb(primary),
      'primary-rgb': _colorRgb(primary),
      'user-bubble-color-rgb': _colorRgb(glaze.userBubble),
      'char-bubble-color-rgb': _colorRgb(glaze.charBubble),
      // Full bubble background: either a solid rgba (element-opacity applied) or
      // a 2-stop linear gradient. Always emitted so toggling gradient → solid
      // overwrites the previously-set CSS variable.
      'user-bubble-bg':
          _bubbleBg(input.userBubbleGradient, glaze.userBubble, opacity),
      'char-bubble-bg':
          _bubbleBg(input.charBubbleGradient, glaze.charBubble, opacity),
      'user-text-color': _colorHex(glaze.userText ?? cs.onSurface),
      'char-text-color': _colorHex(glaze.charText ?? cs.onSurface),
      'user-quote-color': _colorHex(glaze.userQuote ?? cs.primary),
      'char-quote-color': _colorHex(glaze.charQuote ?? cs.primary),
      'user-italic-color': _colorHex(glaze.userItalic ?? cs.primary),
      'char-italic-color': _colorHex(glaze.charItalic ?? cs.primary),
      'primary-color': _colorHex(primary),
      'error-color': _colorHex(cs.error),
      'element-opacity': input.elementOpacity
          .clamp(0.0, 1.0)
          .toStringAsFixed(2),
      'element-blur': '${input.elementBlur.clamp(0.0, 64.0).round()}px',
      'font-size': '${input.chatFontSize}px',
      'chat-font-size': '${input.chatFontSize}px',
      'chat-layout': input.chatLayout ?? 'default',
      'bg-dim': input.bgDim.clamp(0.0, 1.0).toStringAsFixed(2),
      'ui-font-weight': '${input.uiFontWeight.clamp(100, 900)}',
      'user-font-weight': '${input.userMessageFontWeight.clamp(100, 900)}',
      'char-font-weight': '${input.charMessageFontWeight.clamp(100, 900)}',
      'user-bubble-radius': '${input.userBubbleRadius.clamp(0.0, 48.0)}px',
      'char-bubble-radius': '${input.charBubbleRadius.clamp(0.0, 48.0)}px',
      'show-user-avatar': input.showUserAvatar ? '1' : '0',
      'show-char-avatar': input.showCharAvatar ? '1' : '0',
      'show-user-name': input.showUserName ? '1' : '0',
      'show-char-name': input.showCharName ? '1' : '0',
      'text-bg-opacity': input.textBgOpacity.clamp(0.0, 1.0).toStringAsFixed(2),
      // Padding is non-zero only when the backdrop is actually visible.
      'text-bg-padding': input.textBgOpacity > 0.0 ? '8px 10px' : '0px',
    };
  }

  /// Build the CSS background value for a bubble. Solid → `rgba(r,g,b,op)`;
  /// gradient → `linear-gradient(<angle>deg, rgba(...), rgba(...))`, with the
  /// element opacity baked into every stop.
  static String _bubbleBg(BubbleGradient? g, Color solid, double op) {
    final opStr = op.toStringAsFixed(2);
    if (g == null) {
      return 'rgba(${_colorRgb(solid)}, $opStr)';
    }
    final c1 = 'rgba(${_colorRgb(g.color1)}, $opStr)';
    final c2 = 'rgba(${_colorRgb(g.color2)}, $opStr)';
    return 'linear-gradient(${g.angle.round()}deg, $c1, $c2)';
  }

  static String _colorRgb(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return '$r, $g, $b';
  }

  static String _colorHex(Color c) {
    final a = c.a;
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    if (a >= 0.99) {
      return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}';
    }
    final alphaR = (r * a + 255 * (1 - a)).round().clamp(0, 255);
    final alphaG = (g * a + 255 * (1 - a)).round().clamp(0, 255);
    final alphaB = (b * a + 0 * (1 - a)).round().clamp(0, 255);
    return '#${alphaR.toRadixString(16).padLeft(2, '0')}'
        '${alphaG.toRadixString(16).padLeft(2, '0')}'
        '${alphaB.toRadixString(16).padLeft(2, '0')}';
  }
}

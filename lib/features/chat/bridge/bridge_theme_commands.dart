import 'dart:convert';

import 'chat_bridge_controller.dart';

/// Outgoing theme-related commands: applyTheme, font, background
/// image/noise, performance mode. These all touch the WebView's CSS
/// variables and rendering pipeline.
class ThemeBridgeCommands {
  final ChatBridgeController _host;

  ThemeBridgeCommands(this._host);

  Future<void> setBackgroundNoise(double opacity, double intensity) {
    return _host.evalJs(
      'window.bridge?.setBackgroundNoise(${opacity.toStringAsFixed(3)}, ${intensity.toStringAsFixed(3)})',
    );
  }

  /// Background darkening is not passed here — it rides on the `bg-dim`
  /// theme variable ([applyTheme]), which paints a black overlay over the
  /// in-WebView background copy instead of making it translucent.
  Future<void> setBackgroundImage(String? src, int blur) {
    if (src == null || src.isEmpty) {
      return _host.evalJs('window.bridge?.setBackgroundImage(null, 0)');
    }
    String? url;
    if (src.startsWith('data:') ||
        src.startsWith('http://') ||
        src.startsWith('https://') ||
        src.startsWith('file://')) {
      url = _host.resolveLocalFileUrl(src);
    } else {
      url = _host.resolveLocalFileUrl(src);
    }
    if (url == null) {
      return _host.evalJs('window.bridge?.setBackgroundImage(null, 0)');
    }
    // Pass through JSON encoder — data URIs can be megabytes long and
    // may contain characters that the lightweight escape helper doesn't
    // handle.
    final encoded = jsonEncode(url);
    return _host.evalJs(
      'window.bridge?.setBackgroundImage($encoded, $blur)',
    );
  }

  Future<void> setChatFont({
    String? fontName,
    String? fontDataUrl,
    required double fontSize,
    required double letterSpacing,
  }) {
    final name = fontName != null ? '"${_host.escape(fontName)}"' : 'null';
    final url = fontDataUrl != null ? '"${_host.escape(fontDataUrl)}"' : 'null';
    return _host.evalJs(
      'window.bridge?.setChatFont($name, $url, ${fontSize.toStringAsFixed(1)}, ${letterSpacing.toStringAsFixed(2)})',
    );
  }

  Future<void> applyTheme(Map<String, String> theme) {
    final normalizedTheme = Map<String, String>.from(theme);
    if (normalizedTheme.containsKey('chat-layout')) {
      normalizedTheme['chat-layout'] = _host.normalizeLayout(
        normalizedTheme['chat-layout'],
      );
    }
    final json = jsonEncode(normalizedTheme);
    return _host.callJs('applyTheme', json);
  }

  Future<void> setPerformanceMode(bool enabled) {
    return _host.evalJs('window.bridge?.setPerformanceMode($enabled)');
  }
}

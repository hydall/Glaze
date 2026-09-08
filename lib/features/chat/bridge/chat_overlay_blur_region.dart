import 'dart:convert';
import 'dart:ui';

/// A rounded-rect area of a Flutter glass element (header pill, chat input
/// pill, circle buttons) that overlays the chat WebView.
///
/// Flutter's `BackdropFilter` cannot sample the natively-composited
/// `InAppWebView` pixels, so the "glass blur" of overlaying widgets is
/// reproduced in two synced layers keyed by these regions:
///  * inside the WebView — fixed `backdrop-filter` strips blur the messages
///    scrolling underneath (see `setOverlayBlurRegions` in
///    `assets/chat_webview/bridge/chat_bridge_controller.js`);
///  * below the WebView — a `BackdropFilter` sandwich in
///    `ChatWebViewSurface` blurs the (Flutter-side, global) background.
///
/// Coordinates are in the WebView's local space, which equals CSS pixels:
/// the chat WebView is always full-screen (`resizeToAvoidBottomInset:
/// false`) and both Flutter logical px and CSS px are device-independent.
class ChatOverlayBlurRegion {
  ChatOverlayBlurRegion({
    required this.id,
    required Rect rect,
    required double radius,
  }) : rect = Rect.fromLTWH(
         _quantize(rect.left),
         _quantize(rect.top),
         _quantize(rect.width),
         _quantize(rect.height),
       ),
       radius = _quantize(radius);

  final String id;
  final Rect rect;
  final double radius;

  /// Snap to 0.1 px so repeated measurements of an unmoved element compare
  /// equal and don't re-trigger the bridge sync on float jitter.
  static double _quantize(double v) => (v * 10).roundToDouble() / 10;

  Map<String, Object> toJson() => {
    'id': id,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'r': radius,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatOverlayBlurRegion &&
      other.id == id &&
      other.rect == rect &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(id, rect, radius);
}

/// JSON array literal for `window.bridge.setOverlayBlurRegions(...)` —
/// valid as a direct JS expression argument.
String chatOverlayBlurRegionsToJs(List<ChatOverlayBlurRegion> regions) {
  return jsonEncode([for (final r in regions) r.toJson()]);
}

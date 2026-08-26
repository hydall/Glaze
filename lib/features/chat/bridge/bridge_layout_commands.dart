import 'dart:convert';

import 'chat_bridge_controller.dart';
import 'chat_overlay_blur_region.dart';

/// Outgoing layout/UX commands: padding, search, edit, selection,
/// message settings. These are WebView-level controls that don't
/// affect message content directly.
class LayoutBridgeCommands {
  final ChatBridgeController _host;

  LayoutBridgeCommands(this._host);

  /// [scroll] brings the active match into view. Pass `false` for a refresh
  /// pass that only has to re-number the highlights after the messages
  /// changed — scrolling there would yank the reader away from the message
  /// they just edited.
  Future<void> setSearch({
    required String query,
    int activeIndex = -1,
    bool scroll = true,
  }) {
    return _host.evalJs(
      'window.bridge?.setSearch("${_host.escape(query)}", $activeIndex, '
      '$scroll)',
    );
  }

  /// [px] is the bottom inset measured from the bottom edge of the WebView box
  /// (input bar + keyboard/drawer + leftover safe area). [viewportHeight] is
  /// that box's height, which lets the page detect how much of the inset its
  /// own viewport already absorbed when the soft keyboard shrank it — the page
  /// turns only the remainder into padding. Pass 0 to make the whole inset
  /// padding (the pre-measurement behaviour).
  Future<void> setBottomPadding(double px, {double viewportHeight = 0}) {
    return _host.evalJs(
      'window.bridge?.setBottomPadding('
      '${px.toStringAsFixed(1)}, ${viewportHeight.toStringAsFixed(1)})',
    );
  }

  Future<void> setTopPadding(double px) {
    return _host.evalJs(
      'window.bridge?.setTopPadding(${px.toStringAsFixed(1)})',
    );
  }

  /// Syncs the rects of Flutter glass overlays (header, input pill, ...) so
  /// the WebView can blur the messages scrolling underneath them — Flutter's
  /// own BackdropFilter cannot sample the platform view's pixels.
  Future<void> setOverlayBlurRegions(List<ChatOverlayBlurRegion> regions) {
    final json = chatOverlayBlurRegionsToJs(regions);
    return _host.evalJs('window.bridge?.setOverlayBlurRegions($json)');
  }

  Future<void> startEdit(String messageId) {
    return _host.evalJs(
      'window.bridge?.startEdit("${_host.escape(messageId)}")',
    );
  }

  Future<void> stopEdit(String messageId) {
    return _host.evalJs(
      'window.bridge?.stopEdit("${_host.escape(messageId)}")',
    );
  }

  Future<void> setMessageSettings({
    required bool batterySaver,
    required bool hideMessageId,
    required bool hideGenerationTime,
    required bool hideTokenCount,
    required bool disableSwipeRegeneration,
    required bool studioEnabled,
  }) {
    final json = jsonEncode({
      'batterySaver': batterySaver,
      'hideMessageId': hideMessageId,
      'hideGenerationTime': hideGenerationTime,
      'hideTokenCount': hideTokenCount,
      'disableSwipeRegeneration': disableSwipeRegeneration,
      'studioEnabled': studioEnabled,
    });
    return _host.callJs('setMessageSettings', json);
  }

  Future<void> setSelectionMode(bool enabled) {
    return _host.evalJs('window.bridge?.setSelectionMode($enabled)');
  }

  Future<void> toggleMessageSelection(String id) {
    return _host.evalJs(
      'window.bridge?.renderer?.toggleMessageSelection("${_host.escape(id)}")',
    );
  }

  /// Replays a Windows precision-touchpad pan as a scroll inside the page.
  ///
  /// Flutter's win32 embedder reports precision-touchpad scrolling as
  /// pan/zoom pointer events (`PointerPanZoom*`), not as `PointerScrollEvent`,
  /// and `flutter_inappwebview_windows` only forwards the latter to WebView2 —
  /// so a touchpad produces no `wheel` event in the page at all
  /// (flutter_inappwebview #2503 / #2511, both closed as not planned). The
  /// Flutter side captures the pan and hands it back here.
  ///
  /// [dx]/[dy] are scroll deltas in CSS pixels (already sign-flipped to
  /// wheel semantics: positive [dy] scrolls the content down). [x]/[y] are
  /// the pointer's client coordinates, used to pick the element under the
  /// cursor so nested scrollers (edit textarea, panels) behave as they do
  /// with a real wheel.
  Future<void> trackpadScroll({
    required double dx,
    required double dy,
    required double x,
    required double y,
  }) {
    return _host.evalJs(
      'window.bridge?.trackpadScroll('
      '${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)}, '
      '${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})',
    );
  }
}

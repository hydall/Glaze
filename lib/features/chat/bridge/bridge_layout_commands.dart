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
    bool translationEnabled = false,
  }) {
    final json = jsonEncode({
      'batterySaver': batterySaver,
      'hideMessageId': hideMessageId,
      'hideGenerationTime': hideGenerationTime,
      'hideTokenCount': hideTokenCount,
      'disableSwipeRegeneration': disableSwipeRegeneration,
      'studioEnabled': studioEnabled,
      'translationEnabled': translationEnabled,
    });
    return _host.callJs('setMessageSettings', json);
  }

  Future<void> setSelectionMode(bool enabled) {
    return _host.evalJs('window.bridge?.setSelectionMode($enabled)');
  }

  /// Selects (or, when the run is already selected, deselects) every message
  /// above the last tapped one.
  Future<void> selectMessagesAbove() {
    return _host.evalJs('window.bridge?.selectMessagesAbove()');
  }

  /// Same as [selectMessagesAbove], for everything below the last tapped
  /// message.
  Future<void> selectMessagesBelow() {
    return _host.evalJs('window.bridge?.selectMessagesBelow()');
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
  /// with a real wheel. The page evens the frame-by-frame deltas out and
  /// follows them a frame or two behind, since the embedder's sums carry the
  /// pad's sample jitter.
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

  /// The fingers touched the pad: a flick the page still glides from stops.
  Future<void> trackpadScrollStart() {
    return _host.evalJs('window.bridge?.trackpadScrollStart()');
  }

  /// The fingers left the pad at [vx]/[vy] CSS pixels per second (wheel
  /// sign): the page carries the motion on and lets it die away, the glide a
  /// Flutter list gives a flick. Nothing in the embedder's pan stream does
  /// that for a WebView.
  Future<void> trackpadScrollEnd({required double vx, required double vy}) {
    return _host.evalJs(
      'window.bridge?.trackpadScrollEnd('
      '${vx.toStringAsFixed(1)}, ${vy.toStringAsFixed(1)})',
    );
  }

  /// Replays a Windows mouse-wheel notch as a smooth scroll inside the page.
  ///
  /// `flutter_inappwebview_windows` does forward the notch to WebView2, but
  /// hands it Flutter's delta — logical pixels, divided by the device pixel
  /// ratio — as wheel units, 120 to a notch, so the page sees a fraction of a
  /// notch and jumps by it. The Flutter side captures the notch as well,
  /// converts it back to the CSS pixels a browser would scroll and hands it
  /// here; the page spreads it over the frames that follow and, once
  /// [relayNativeWheel] is on, drops the plugin's copy.
  ///
  /// Same units and sign as [trackpadScroll].
  Future<void> wheelScroll({
    required double dx,
    required double dy,
    required double x,
    required double y,
  }) {
    return _host.evalJs(
      'window.bridge?.wheelScroll('
      '${dx.toStringAsFixed(2)}, ${dy.toStringAsFixed(2)}, '
      '${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})',
    );
  }

  /// Tells the page that the mouse wheel arrives through [wheelScroll] from
  /// now on, so the trusted `wheel` event the plugin forwards for the same
  /// notch is to be ignored. Off by default: every other platform keeps its
  /// native wheel.
  Future<void> relayNativeWheel(bool on) {
    return _host.evalJs('window.bridge?.relayNativeWheel($on)');
  }
}

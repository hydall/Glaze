import 'dart:convert';

import 'chat_bridge_controller.dart';
import 'chat_overlay_blur_region.dart';

/// Outgoing layout/UX commands: padding, search, edit, selection,
/// message settings. These are WebView-level controls that don't
/// affect message content directly.
class LayoutBridgeCommands {
  final ChatBridgeController _host;

  LayoutBridgeCommands(this._host);

  Future<void> setSearch({required String query, int activeIndex = -1}) {
    return _host.evalJs(
      'window.bridge?.setSearch("${_host.escape(query)}", $activeIndex)',
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
}

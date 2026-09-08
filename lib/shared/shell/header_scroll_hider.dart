import 'package:flutter/widgets.dart';

/// Drives hide-on-scroll for a floating header, ported from the chat header's
/// algorithm (`initHeaderScroll` in
/// `assets/chat_webview/bridge/chat_bridge_controller.js`). Unlike
/// [UserScrollNotification.direction] — which flips the instant a drag starts
/// — this requires a few pixels of actual movement and ignores rubber-band
/// overscroll at the list's edges.
class HeaderScrollHider {
  double _lastPixels = 0;
  bool _hidden = false;
  bool _rebaseline = false;

  bool get hidden => _hidden;

  /// Drops the tracked state back to "header visible" and re-baselines the
  /// scroll position, so the next notification only records where the list is
  /// instead of reading the jump as a gesture.
  ///
  /// Must be called whenever the header is shown out of band — a screen
  /// opening, a tab switch, a nav re-tap. Two things break otherwise: this
  /// hider keeps believing the header is hidden and swallows the next hide
  /// (it only emits on transitions), and a view that comes back at a different
  /// scroll offset registers the whole difference as one downward scroll and
  /// hides the header again immediately.
  void reset() {
    _hidden = false;
    _lastPixels = 0;
    _rebaseline = true;
  }

  /// Feed every [ScrollNotification] from the list here. Calls [onChanged]
  /// with the new hidden state when it flips. Ignores horizontal scrollables.
  void handle(ScrollNotification notification, ValueChanged<bool> onChanged) {
    if (notification.metrics.axis != Axis.vertical) return;
    if (notification is! ScrollUpdateNotification &&
        notification is! OverscrollNotification) {
      return;
    }

    final metrics = notification.metrics;
    final pixels = metrics.pixels;

    if (_rebaseline) {
      _rebaseline = false;
      _lastPixels = pixels <= metrics.minScrollExtent
          ? metrics.minScrollExtent
          : pixels;
      return;
    }

    if (pixels < metrics.minScrollExtent || pixels > metrics.maxScrollExtent) {
      _lastPixels = pixels <= metrics.minScrollExtent
          ? metrics.minScrollExtent
          : pixels;
      return;
    }

    if (pixels > _lastPixels + 3 && pixels > 50) {
      if (!_hidden) {
        _hidden = true;
        onChanged(true);
      }
    } else if (pixels < _lastPixels - 3) {
      if (_hidden) {
        _hidden = false;
        onChanged(false);
      }
    }
    _lastPixels = pixels <= metrics.minScrollExtent
        ? metrics.minScrollExtent
        : pixels;
  }
}

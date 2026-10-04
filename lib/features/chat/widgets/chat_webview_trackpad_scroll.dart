import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/chat_bridge_registry.dart';

/// Turns Flutter trackpad pan events into wheel-convention scroll deltas,
/// coalesced to at most one emission per frame.
///
/// Pan updates arrive faster than the display refreshes and every emission is
/// a platform-channel round trip into the WebView, so the deltas are summed
/// and flushed from a post-frame callback.
class TrackpadScrollSink {
  TrackpadScrollSink(this.onScroll);

  /// Receives the accumulated delta in wheel sign convention (positive [dy]
  /// scrolls the content down) and the cursor position of the latest event.
  final void Function(double dx, double dy, Offset position) onScroll;

  double _pendingDx = 0;
  double _pendingDy = 0;
  Offset _position = Offset.zero;
  bool _flushScheduled = false;
  bool _disposed = false;

  @visibleForTesting
  bool get hasPendingScroll => _pendingDx != 0 || _pendingDy != 0;

  void start(PointerPanZoomStartEvent event) {
    _position = event.localPosition;
  }

  void update(PointerPanZoomUpdateEvent event) {
    _position = event.localPosition;
    // `panDelta` is finger movement; a wheel delta points the other way
    // (fingers moving up scroll the content down).
    _pendingDx -= event.panDelta.dx;
    _pendingDy -= event.panDelta.dy;
    _scheduleFlush();
  }

  void end(PointerPanZoomEndEvent event) {
    // Flush whatever the last frame did not carry so a short flick is not
    // silently dropped.
    _scheduleFlush();
  }

  void dispose() {
    _disposed = true;
  }

  void _scheduleFlush() {
    if (_disposed || _flushScheduled) return;
    _flushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      flush();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @visibleForTesting
  void flush() {
    final dx = _pendingDx;
    final dy = _pendingDy;
    _pendingDx = 0;
    _pendingDy = 0;
    if (_disposed || (dx == 0 && dy == 0)) return;
    onScroll(dx, dy, _position);
  }
}

/// Makes precision-touchpad scrolling work over the chat WebView on Windows.
///
/// Since Flutter 3.3 the win32 embedder reports precision-touchpad scrolling
/// as pan/zoom pointer events (`PointerPanZoomStart/Update/End`) rather than
/// the `PointerScrollEvent` a mouse wheel produces.
/// `flutter_inappwebview_windows` forwards only the latter to WebView2, so a
/// touchpad generates no `wheel` event inside the page and the chat simply
/// does not scroll — while a mouse wheel works fine (flutter_inappwebview
/// #2503 / #2511, both closed as not planned upstream).
///
/// This wrapper captures the pan Flutter *does* deliver and replays it in the
/// page through `bridge.trackpadScroll()`, which dispatches a synthetic wheel
/// at the cursor so the page's existing wheel handlers do the scrolling.
///
/// On every other platform the child is returned untouched: Android/iOS scroll
/// by touch, and macOS hosts a real native WKWebView that handles its own
/// trackpad input.
class ChatWebViewTrackpadScroll extends ConsumerStatefulWidget {
  const ChatWebViewTrackpadScroll({
    super.key,
    required this.charId,
    required this.child,
  });

  final String charId;
  final Widget child;

  /// Whether the pan-capture layer is needed on the current platform.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  ConsumerState<ChatWebViewTrackpadScroll> createState() =>
      _ChatWebViewTrackpadScrollState();
}

class _ChatWebViewTrackpadScrollState
    extends ConsumerState<ChatWebViewTrackpadScroll> {
  late final TrackpadScrollSink _sink = TrackpadScrollSink(_sendToWebView);

  /// Local logical pixels map 1:1 to the page's CSS pixels because WebView2 is
  /// sized to the widget's logical box, so the position needs no conversion.
  void _sendToWebView(double dx, double dy, Offset position) {
    if (!mounted) return;
    final bridge = ref.read(chatBridgeRegistryProvider(widget.charId));
    if (bridge == null) return;
    // Fire-and-forget: the next frame's pan must not wait on this round trip.
    unawaited(
      bridge.trackpadScroll(dx: dx, dy: dy, x: position.dx, y: position.dy),
    );
  }

  @override
  void dispose() {
    _sink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ChatWebViewTrackpadScroll.isSupported) return widget.child;
    return Listener(
      // Opaque rather than deferToChild: on Windows the WebView is composited
      // from a Texture, which is not hit-testable by itself, so deferring
      // would leave this Listener out of the hit-test path entirely. Opaque
      // only *adds* this render object to the result — children are still hit
      // first, so the WebView keeps receiving every event it does today.
      behavior: HitTestBehavior.opaque,
      onPointerPanZoomStart: _sink.start,
      onPointerPanZoomUpdate: _sink.update,
      onPointerPanZoomEnd: _sink.end,
      child: widget.child,
    );
  }
}

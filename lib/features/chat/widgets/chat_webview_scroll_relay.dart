import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_bridge_registry.dart';

/// Sums the scroll deltas of one event batch and flushes them together.
///
/// The embedder delivers a frame's pan updates — and the notches of a
/// free-spinning wheel — in one pointer packet, and every emission is a
/// platform-channel round trip into the WebView, so the deltas are summed and
/// flushed from a microtask at the end of the batch. Not from a post-frame
/// callback: that held every pan back by a frame, on top of the round trip
/// and the page's own frame, and the content trailed the finger.
///
/// For a pan it also keeps the speed of the fingers, the way a Flutter list's
/// drag does, and reports it when they leave the pad: the embedder's stream
/// ends there, and the page carries the motion on from that speed.
class ScrollRelaySink {
  ScrollRelaySink(this.onScroll, {this.onEnd});

  /// Receives the accumulated delta in wheel sign convention (positive [dy]
  /// scrolls the content down) and the cursor position of the latest event.
  final void Function(double dx, double dy, Offset position) onScroll;

  /// Receives the fingers' speed at lift-off in wheel sign convention,
  /// logical pixels per second, after the last delta of the pan went out.
  final void Function(Offset velocity)? onEnd;

  double _pendingDx = 0;
  double _pendingDy = 0;
  Offset _position = Offset.zero;
  Offset? _endVelocity;
  VelocityTracker? _tracker;
  bool _flushScheduled = false;
  bool _disposed = false;

  @visibleForTesting
  bool get hasPendingScroll => _pendingDx != 0 || _pendingDy != 0;

  void start(PointerPanZoomStartEvent event) {
    _position = event.localPosition;
    _tracker = VelocityTracker.withKind(PointerDeviceKind.trackpad)
      ..addPosition(event.timeStamp, Offset.zero);
  }

  void update(PointerPanZoomUpdateEvent event) {
    // `pan` is the fingers' travel since the start: what the speed is read
    // off, as ScrollableState reads it off a drag.
    _tracker?.addPosition(event.timeStamp, event.pan);
    // `panDelta` is finger movement; a wheel delta points the other way
    // (fingers moving up scroll the content down).
    add(-event.panDelta.dx, -event.panDelta.dy, event.localPosition);
  }

  void end(PointerPanZoomEndEvent event) {
    // Fingers moving up fling the content down: the same sign flip as the
    // deltas. Reported from the flush, after whatever the last frame did not
    // carry, so a short flick is neither dropped nor overtaken by its own
    // glide.
    final velocity = _tracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
    _tracker = null;
    _endVelocity = -velocity;
    _scheduleFlush();
  }

  /// Adds a delta already in wheel sign convention, seen at [position].
  void add(double dx, double dy, Offset position) {
    _position = position;
    _pendingDx += dx;
    _pendingDy += dy;
    _scheduleFlush();
  }

  void dispose() {
    _disposed = true;
  }

  void _scheduleFlush() {
    if (_disposed || _flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      flush();
    });
  }

  @visibleForTesting
  void flush() {
    final dx = _pendingDx;
    final dy = _pendingDy;
    final velocity = _endVelocity;
    _pendingDx = 0;
    _pendingDy = 0;
    _endVelocity = null;
    if (_disposed) return;
    if (dx != 0 || dy != 0) onScroll(dx, dy, _position);
    if (velocity != null) onEnd?.call(velocity);
  }
}

/// The CSS pixels a mouse-wheel notch scrolls in a browser on the same machine.
///
/// Flutter's win32 embedder sizes a notch the way Chromium does — the system's
/// lines per notch × 100/3 pixels — but reports it in logical pixels, divided
/// by the device pixel ratio. Multiplying back gives Chromium's figure: 100
/// CSS pixels per notch at the default three lines, whatever the display
/// scaling.
Offset cssPixelsForWheel(Offset scrollDelta, double devicePixelRatio) =>
    scrollDelta * devicePixelRatio;

/// Relays desktop scroll input over the chat WebView into the page on Windows.
///
/// Two inputs the page would otherwise get wrong or not at all:
///
/// - **Touchpad.** Since Flutter 3.3 the win32 embedder reports
///   precision-touchpad scrolling as pan/zoom pointer events
///   (`PointerPanZoomStart/Update/End`) rather than the `PointerScrollEvent` a
///   mouse wheel produces. `flutter_inappwebview_windows` forwards only the
///   latter to WebView2, so a touchpad generates no `wheel` event inside the
///   page and the chat simply does not scroll (flutter_inappwebview #2503 /
///   #2511, both closed as not planned upstream).
/// - **Mouse wheel.** The plugin does forward it, but passes Flutter's delta —
///   logical pixels, divided by the device pixel ratio — to WebView2 as wheel
///   units, 120 to a notch. The page then saw a fraction of a notch per notch
///   (0.43 at 125% scaling and two lines per notch) and jumped by it: a chat
///   that crawled a line at a time, with no animation.
///
/// This wrapper captures both and replays them in the page through the
/// bridge: a pan as `trackpadScroll()`, a frame's worth at a time, with the
/// fingers' speed at lift-off (`trackpadScrollEnd()`) so the page can carry
/// the motion on the way a Flutter list does — the embedder's stream carries
/// the pad's sample jitter and stops dead when the fingers leave, and the
/// page is what evens it out and glides; a notch as `wheelScroll()`,
/// converted back to the CSS pixels a browser would scroll
/// ([cssPixelsForWheel]) and animated there over the frames that follow. Once
/// the page is up it is told (`relayNativeWheel`) to drop the plugin's copy of
/// the wheel, or every notch would scroll twice.
///
/// On every other platform the child is returned untouched: Android/iOS scroll
/// by touch, and macOS hosts a real native WKWebView that handles its own
/// trackpad and wheel input.
class ChatWebViewScrollRelay extends ConsumerStatefulWidget {
  const ChatWebViewScrollRelay({
    super.key,
    required this.charId,
    required this.child,
  });

  final String charId;
  final Widget child;

  /// Whether the relay is needed on the current platform.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  ConsumerState<ChatWebViewScrollRelay> createState() =>
      _ChatWebViewScrollRelayState();
}

class _ChatWebViewScrollRelayState
    extends ConsumerState<ChatWebViewScrollRelay> {
  late final ScrollRelaySink _pans = ScrollRelaySink(
    _sendPan,
    onEnd: _sendPanEnd,
  );
  late final ScrollRelaySink _notches = ScrollRelaySink(_sendWheel);
  double _devicePixelRatio = 1;

  ChatBridgeController? get _bridge =>
      mounted ? ref.read(chatBridgeRegistryProvider(widget.charId)) : null;

  /// Local logical pixels map 1:1 to the page's CSS pixels because WebView2 is
  /// sized to the widget's logical box, so the position needs no conversion.
  void _sendPan(double dx, double dy, Offset position) {
    final bridge = _bridge;
    if (bridge == null) return;
    // Fire-and-forget: the next frame's pan must not wait on this round trip.
    unawaited(
      bridge.trackpadScroll(dx: dx, dy: dy, x: position.dx, y: position.dy),
    );
  }

  /// Fingers on the pad: whatever the page still glides from the last flick
  /// stops. Also what a touch during a glide reports, as a scroll-inertia
  /// cancel signal rather than a pan.
  void _sendPanStart() {
    final bridge = _bridge;
    if (bridge == null) return;
    unawaited(bridge.trackpadScrollStart());
  }

  void _sendPanEnd(Offset velocity) {
    final bridge = _bridge;
    if (bridge == null) return;
    unawaited(bridge.trackpadScrollEnd(vx: velocity.dx, vy: velocity.dy));
  }

  void _onPanStart(PointerPanZoomStartEvent event) {
    _pans.start(event);
    _sendPanStart();
  }

  void _sendWheel(double dx, double dy, Offset position) {
    final bridge = _bridge;
    if (bridge == null) return;
    unawaited(
      bridge.wheelScroll(dx: dx, dy: dy, x: position.dx, y: position.dy),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollInertiaCancelEvent) {
      _sendPanStart();
      return;
    }
    if (event is! PointerScrollEvent) return;
    final delta = cssPixelsForWheel(event.scrollDelta, _devicePixelRatio);
    _notches.add(delta.dx, delta.dy, event.localPosition);
  }

  @override
  void dispose() {
    _pans.dispose();
    _notches.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ChatWebViewScrollRelay.isSupported) return widget.child;
    _devicePixelRatio =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.of(context).devicePixelRatio;
    return Listener(
      // Opaque rather than deferToChild: on Windows the WebView is composited
      // from a Texture, which is not hit-testable by itself, so deferring
      // would leave this Listener out of the hit-test path entirely. Opaque
      // only *adds* this render object to the result — children are still hit
      // first, so the WebView keeps receiving every event it does today.
      behavior: HitTestBehavior.opaque,
      onPointerPanZoomStart: _onPanStart,
      onPointerPanZoomUpdate: _pans.update,
      onPointerPanZoomEnd: _pans.end,
      onPointerSignal: _onPointerSignal,
      child: widget.child,
    );
  }
}

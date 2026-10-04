// Windows precision-touchpad scrolling for the chat WebView.
//
// Flutter's win32 embedder delivers touchpad scrolling as PointerPanZoom*
// events, which flutter_inappwebview_windows never forwards to WebView2 — so
// without this layer the chat only scrolls with a mouse wheel. These tests
// guard the Flutter capture side and the JS replay side against regressions.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/widgets/chat_webview_trackpad_scroll.dart';

String _bridgeAsset(String name) =>
    File('assets/chat_webview/bridge/$name').readAsStringSync();

PointerPanZoomUpdateEvent _panUpdate(Offset panDelta, {Offset? position}) {
  return PointerPanZoomUpdateEvent(
    position: position ?? Offset.zero,
    pan: panDelta,
    panDelta: panDelta,
  );
}

void main() {
  group('TrackpadScrollSink', () {
    test('inverts pan into wheel sign convention', () {
      final emitted = <List<double>>[];
      final sink = TrackpadScrollSink(
        (dx, dy, position) => emitted.add([dx, dy]),
      );

      // Fingers moving up (negative dy) must scroll the content down, which is
      // a positive wheel delta — the same sign a mouse wheel produces.
      sink.update(_panUpdate(const Offset(0, -20)));
      sink.flush();

      expect(emitted, [
        [0.0, 20.0],
      ]);
    });

    test('accumulates several pan updates into one emission', () {
      final emitted = <List<double>>[];
      final sink = TrackpadScrollSink(
        (dx, dy, position) => emitted.add([dx, dy]),
      );

      sink.update(_panUpdate(const Offset(-3, -10)));
      sink.update(_panUpdate(const Offset(-2, -5)));
      sink.flush();

      expect(emitted, [
        [5.0, 15.0],
      ]);
    });

    test('flush clears the accumulator and emits nothing when idle', () {
      final emitted = <List<double>>[];
      final sink = TrackpadScrollSink(
        (dx, dy, position) => emitted.add([dx, dy]),
      );

      sink.update(_panUpdate(const Offset(0, -8)));
      expect(sink.hasPendingScroll, isTrue);
      sink.flush();
      expect(sink.hasPendingScroll, isFalse);

      sink.flush();
      expect(emitted, hasLength(1), reason: 'an idle flush must not emit');
    });

    test('reports the cursor position of the latest event', () {
      Offset? seen;
      final sink = TrackpadScrollSink((dx, dy, position) => seen = position);

      sink.start(
        PointerPanZoomStartEvent(position: const Offset(10, 20)),
      );
      sink.update(
        _panUpdate(const Offset(0, -4), position: const Offset(120, 340)),
      );
      sink.flush();

      expect(seen, const Offset(120, 340));
    });

    test('emits nothing after dispose', () {
      var calls = 0;
      final sink = TrackpadScrollSink((dx, dy, position) => calls++);

      sink.update(_panUpdate(const Offset(0, -8)));
      sink.dispose();
      sink.flush();

      expect(calls, 0);
    });

    testWidgets('coalesces a burst of pan updates to one call per frame', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());

      final emitted = <double>[];
      final sink = TrackpadScrollSink((dx, dy, position) => emitted.add(dy));

      sink.update(_panUpdate(const Offset(0, -5)));
      sink.update(_panUpdate(const Offset(0, -5)));
      sink.update(_panUpdate(const Offset(0, -5)));
      expect(emitted, isEmpty, reason: 'flush is deferred to the next frame');

      await tester.pump();

      expect(emitted, [15.0]);
    });
  });

  group('ChatWebViewTrackpadScroll', () {
    // testWidgets bodies reset the override themselves: the binding asserts
    // every foundation debug variable is unset when the body returns, which
    // happens before tearDown gets a chance to run.
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('is only needed on Windows', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          ChatWebViewTrackpadScroll.isSupported,
          platform == TargetPlatform.windows,
          reason: '$platform',
        );
      }
    });

    testWidgets('wraps the child in a pan-capturing Listener on Windows', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        const ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ChatWebViewTrackpadScroll(
              charId: 'char-1',
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      final listener = tester.widget<Listener>(
        find.descendant(
          of: find.byType(ChatWebViewTrackpadScroll),
          matching: find.byType(Listener),
        ),
      );
      expect(listener.onPointerPanZoomStart, isNotNull);
      expect(listener.onPointerPanZoomUpdate, isNotNull);
      expect(listener.onPointerPanZoomEnd, isNotNull);
      expect(listener.behavior, HitTestBehavior.opaque);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('adds no wrapper off Windows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        const ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ChatWebViewTrackpadScroll(
              charId: 'char-1',
              child: SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ChatWebViewTrackpadScroll),
          matching: find.byType(Listener),
        ),
        findsNothing,
      );

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('trackpad_scroll.js', () {
    late String trackpadJs;
    late String bridgeIndexJs;
    late String bridgeControllerJs;

    setUpAll(() {
      trackpadJs = _bridgeAsset('trackpad_scroll.js');
      bridgeIndexJs = _bridgeAsset('index.js');
      bridgeControllerJs = _bridgeAsset('chat_bridge_controller.js');
    });

    test('bridge exposes trackpadScroll to Flutter', () {
      expect(bridgeControllerJs, contains('trackpadScroll(dx, dy, x, y)'));
      expect(bridgeControllerJs, contains('new TrackpadScroll('));
    });

    test('undoes the page wheel scale so the pan tracks the finger 1:1', () {
      // The page's own wheel handlers scroll by `deltaY * 0.3`, so a delta
      // already expressed in CSS pixels has to be divided by the same factor
      // before it is replayed as a wheel event.
      expect(bridgeIndexJs, contains('container.scrollTop += e.deltaY * 0.3'));
      expect(trackpadJs, contains('export const WHEEL_PIXEL_SCALE = 0.3;'));
      expect(trackpadJs, contains('deltaX: dx / WHEEL_PIXEL_SCALE'));
      expect(trackpadJs, contains('deltaY: dy / WHEEL_PIXEL_SCALE'));
    });

    test('replays the pan as a cancelable pixel-mode wheel at the cursor', () {
      // Reusing the page's wheel handlers keeps one scroll path instead of a
      // second, touchpad-only one that could drift out of sync.
      expect(trackpadJs, contains("new WheelEvent('wheel'"));
      expect(trackpadJs, contains('deltaMode: 0'));
      expect(trackpadJs, contains('cancelable: true'));
      expect(trackpadJs, contains('bubbles: true'));
      expect(trackpadJs, contains('document.elementFromPoint(x, y)'));
    });

    test('performs the default scroll itself when nothing consumes it', () {
      // Synthetic events are untrusted, so the browser runs no default action
      // for them — an unhandled wheel has to be applied by hand.
      expect(trackpadJs, contains('if (consumed) return;'));
      expect(trackpadJs, contains('_scrollNearest'));
      expect(trackpadJs, contains('el.scrollTop += dy'));
      expect(trackpadJs, contains('el.scrollLeft += dx'));
    });

    test('falls back to the chat container when no scrollable is found', () {
      expect(trackpadJs, contains('container.scrollTop += dy'));
    });
  });
}

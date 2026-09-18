import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/chat_webview_settings.dart';

void main() {
  // The Android WebView implements `disableHorizontalScroll` /
  // `disableVerticalScroll` by rewriting the touch stream: with one axis
  // disabled it calls `event.setLocation()` on every ACTION_MOVE/UP/CANCEL and
  // pins that axis to its ACTION_DOWN value. The page then receives touches
  // that never move along it, which breaks every in-page gesture on that axis
  // — the message swipe handler reads a dx of 0 and locks the drag to a
  // vertical scroll, and wide code blocks and tables stop scrolling sideways.
  //
  // The document is already pinned in CSS (`html, body` are `position: fixed;
  // overflow: hidden`), so there is no native scroll range to suppress and
  // neither flag buys anything.
  group('chat WebView touch axes', () {
    late InAppWebViewSettings settings;

    setUp(() {
      // Both flags are set unconditionally, so any platform proves them — but
      // not Android, which `flutter test` reports by default. There
      // [chatWebViewInAppSettings] builds a [WebViewAssetLoader], whose path
      // handler is a platform-interface factory that asserts on a registered
      // native implementation the test host does not have.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      settings = chatWebViewInAppSettings();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('horizontal touch movement reaches the page', () {
      expect(
        settings.disableHorizontalScroll,
        isNot(true),
        reason:
            'Android pins the touch X to its ACTION_DOWN value, so message '
            'swipes and horizontal scrolling inside the page stop working.',
      );
    });

    test('vertical touch movement reaches the page', () {
      expect(
        settings.disableVerticalScroll,
        isNot(true),
        reason:
            'Android pins the touch Y to its ACTION_DOWN value, which takes '
            "#chat-container's own touch scrolling with it.",
      );
    });

    test('overscroll stays disabled', () {
      // The bounce/glow moves the whole page, carrying the fixed Flutter-glass
      // strips out from under the Flutter chrome. Unlike the axis flags, this
      // one does not touch the event stream.
      expect(settings.disallowOverScroll, isTrue);
    });
  });
}

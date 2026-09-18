import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/webview_bridge_probe.dart';

void main() {
  group('probeWebViewJsBridge', () {
    test('reports the page bridge as ready when the read says so', () async {
      expect(
        await probeWebViewJsBridge(
          () => Future<Object?>.value(true),
          timeout: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });

    test('reports not-ready for a false or missing answer', () async {
      expect(
        await probeWebViewJsBridge(
          () => Future<Object?>.value(false),
          timeout: const Duration(seconds: 1),
        ),
        isFalse,
      );
      expect(
        await probeWebViewJsBridge(
          () => Future<Object?>.value(null),
          timeout: const Duration(seconds: 1),
        ),
        isFalse,
      );
    });

    test('a read that never answers times out instead of hanging', () async {
      // The dead keep-alive WebView: it accepts the call and never answers.
      // Timing out is what turns the hang into a failed init attempt the
      // caller can rebuild from.
      await expectLater(
        probeWebViewJsBridge(
          () => Completer<Object?>().future,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('chat WebView bridge handshake', () {
    // The probe only has a real WebView to run against in production, so the
    // wiring is pinned on the source — the same approach the WebView lifecycle
    // tests use. What matters is that the fast path goes through the bounded
    // probe rather than a bare `await`, which is what parked init forever on a
    // dead page.
    late final String source = File(
      'lib/features/chat/widgets/chat_webview_widget.dart',
    ).readAsStringSync();

    test('the fast-path bridge read is bounded', () {
      final call = source.indexOf('probeWebViewJsBridge(');
      expect(call, isNonNegative, reason: 'the bounded probe is not in use');
      final read = source.indexOf(
        'bridge.evalJsWithResult(_kJsBridgeReadyProbe)',
        call,
      );
      expect(read, greaterThan(call));
      // The probe read is the probe helper's argument, not a bare await.
      expect(read - call, lessThan(160));
    });
  });
}

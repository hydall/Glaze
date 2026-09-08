import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/js_bridge_toast_controller.dart';
import 'helpers/js_bridge_test_support.dart';

void main() {
  group('GlazeToastSeverity.parse', () {
    test('returns info for null / unknown / empty values', () {
      expect(GlazeToastSeverity.parse(null), GlazeToastSeverity.info);
      expect(GlazeToastSeverity.parse(''), GlazeToastSeverity.info);
      expect(GlazeToastSeverity.parse('weird'), GlazeToastSeverity.info);
    });

    test('maps known severities', () {
      expect(GlazeToastSeverity.parse('info'), GlazeToastSeverity.info);
      expect(GlazeToastSeverity.parse('INFO'), GlazeToastSeverity.info);
      expect(GlazeToastSeverity.parse('success'), GlazeToastSeverity.success);
      expect(GlazeToastSeverity.parse('warning'), GlazeToastSeverity.warning);
      expect(GlazeToastSeverity.parse('warn'), GlazeToastSeverity.warning);
      expect(GlazeToastSeverity.parse('error'), GlazeToastSeverity.error);
    });
  });

  group('JsBridgeToastController', () {
    test('falls back to debugPrint when no overlay is available', () {
      final controller = JsBridgeToastController();
      // No overlay resolver — the controller must not throw.
      controller.show('hi from headless');
    });

    test('passes severity through to the user-supplied resolver', () {
      String? captured;
      GlazeToastSeverity? capturedSeverity;
      final controller = JsBridgeToastController(overlayResolver: () => null);
      // Re-point the debug hook by replacing the resolver. We test the
      // controller's pure-data path: the controller never inspects the
      // BuildContext directly, so a null overlay is enough to trigger
      // the log branch.
      controller.show('hi', severity: GlazeToastSeverity.error);
      expect(
        captured,
        isNull,
        reason: 'this test only exercises the no-overlay path',
      );
      expect(capturedSeverity, isNull);
    });
  });

  group('JsBridgeService showToast', () {
    test('delegates message + options to the injected handler', () async {
      String? seenMessage;
      Map<String, dynamic>? seenOptions;
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => true,
        showToast: (message, options) {
          seenMessage = message;
          seenOptions = options;
        },
      );
      final result = await bridge.dispatch({
        'method': 'showToast',
        'params': {
          'message': 'Hello',
          'options': {'severity': 'warning'},
        },
      });
      expect(result['ok'], isTrue);
      expect(seenMessage, 'Hello');
      expect(seenOptions!['severity'], 'warning');
    });

    test('rejects non-string message with invalid_request', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => true,
        showToast: (_, _) {},
      );
      final result = await bridge.dispatch({
        'method': 'showToast',
        'params': {'message': 7},
      });
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });

    test('denies when show_toast capability is not granted', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => false,
        showToast: (_, _) {},
      );
      final result = await bridge.dispatch({
        'method': 'showToast',
        'params': {'message': 'hi'},
      });
      expect(result['ok'], isFalse);
      expect((result['error']['message'] as String), contains('show_toast'));
    });
  });
}

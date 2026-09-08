import 'package:flutter_test/flutter_test.dart';

import 'helpers/js_bridge_test_support.dart';

void main() {
  group('JsBridgeService playAudio', () {
    test('delegates source + options to the injected handler', () async {
      String? seenSource;
      Map<String, dynamic>? seenOptions;
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => true,
        playAudio: (source, options) async {
          seenSource = source;
          seenOptions = options;
        },
      );
      final result = await bridge.dispatch({
        'method': 'playAudio',
        'params': {
          'source': 'click',
          'options': {'volume': 0.5, 'loop': false},
        },
      });
      expect(result['ok'], isTrue);
      expect(seenSource, 'click');
      expect(seenOptions, {'volume': 0.5, 'loop': false});
    });

    test('rejects non-string source with invalid_request', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => true,
        playAudio: (_, _) async {},
      );
      final result = await bridge.dispatch({
        'method': 'playAudio',
        'params': {'source': 7},
      });
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });

    test('denies when play_audio capability is not granted', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => false,
        playAudio: (_, _) async {},
      );
      final result = await bridge.dispatch({
        'method': 'playAudio',
        'params': {'source': 'click'},
      });
      expect(result['ok'], isFalse);
      expect((result['error']['message'] as String), contains('play_audio'));
    });

    test('returns unsupported_method when no handler is registered', () async {
      final bridge = TestJsBridge.create(permissionCheck: (_) => true);
      final result = await bridge.dispatch({
        'method': 'playAudio',
        'params': {'source': 'click'},
      });
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'unsupported_method');
    });
  });
}

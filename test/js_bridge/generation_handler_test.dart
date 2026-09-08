import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/js_bridge/handlers/generation_handler.dart';
import '../helpers/js_bridge_test_support.dart';

void main() {
  group('GenerationHandler', () {
    test('generateText validates preset before delegating', () async {
      final handler = GenerationHandler();
      final bridge = TestJsBridge.context(
        params: {
          'prompt': 'Hello',
          'options': {'preset': 'tiny'},
        },
        context: const {},
        permissionCheck: (_) => true,
        generateText: (_, _, _) => throw StateError('must not delegate'),
      );

      expect(() => handler.generateText(bridge), throwsA(isA<ArgumentError>()));
    });

    test('generateText delegates prompt, options, and context', () async {
      final handler = GenerationHandler();
      final bridge = TestJsBridge.context(
        params: {
          'prompt': 'Write one line',
          'options': {'preset': 'small'},
        },
        context: {'sessionId': 's1'},
        permissionCheck: (_) => true,
        generateText: (prompt, options, context) async {
          expect(prompt, 'Write one line');
          expect(options['preset'], 'small');
          expect(context['sessionId'], 's1');
          return 'ok';
        },
      );

      await expectLater(handler.generateText(bridge), completion('ok'));
    });

    test(
      'triggerGeneration resolves character id from context first',
      () async {
        final handler = GenerationHandler();
        final bridge = TestJsBridge.context(
          params: {'mode': 'auto'},
          context: {'characterId': 'explicit'},
          currentCharacterId: () => 'fallback',
          permissionCheck: (_) => true,
          triggerGeneration: (charId, params) {
            return {'charId': charId, 'mode': params['mode']};
          },
        );

        expect(handler.triggerGeneration(bridge), {
          'charId': 'explicit',
          'mode': 'auto',
        });
      },
    );

    test(
      'canonical dispatch default-denies without a permission check',
      () async {
        final bridge = TestJsBridge.create(
          generateText: (_, _, _) async => 'must not run',
        );

        final response = await bridge.dispatch({
          'method': 'generateText',
          'params': {'prompt': 'Hello'},
        });

        expect(response['ok'], isFalse);
        expect(response['error'], isA<Map<String, dynamic>>());
        expect(
          (response['error'] as Map<String, dynamic>)['code'],
          'bridge_error',
        );
        expect(
          (response['error'] as Map<String, dynamic>)['message'],
          contains('Permission denied: generate_text'),
        );
      },
    );
  });
}

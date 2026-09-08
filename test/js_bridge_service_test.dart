import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'helpers/js_bridge_test_support.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  late AppDatabase db;
  late CharacterRepo characterRepo;
  late ChatRepo chatRepo;
  late JsBridgeService bridge;

  setUp(() async {
    db = _testDb();
    characterRepo = CharacterRepo(db);
    chatRepo = ChatRepo(db);
    bridge = TestJsBridge.create(
      chatRepo: chatRepo,
      characterRepo: characterRepo,
      currentSessionId: () => 's1',
      currentCharacterId: () => 'c1',
      permissionCheck: (_) => true,
    );

    await characterRepo.put(Character(id: 'c1', name: 'Alice'));
    await chatRepo.put(
      const ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        sessionVars: {'sessionName': 'Main'},
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('JsBridgeService variables', () {
    test('sets, reads, and deletes chat variables by dot path', () async {
      await bridge.dispatch({
        'method': 'setVariables',
        'params': {'scope': 'chat', 'path': 'stats.hp', 'value': 42},
      });

      final read = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'chat', 'path': 'stats.hp'},
      });
      expect(read['ok'], isTrue);
      expect(read['result'], 42);

      final session = await chatRepo.getById('s1');
      expect(session!.sessionVars['sessionName'], 'Main');

      await bridge.dispatch({
        'method': 'deleteVariable',
        'params': {'scope': 'chat', 'path': 'stats.hp'},
      });

      final deleted = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'chat', 'path': 'stats.hp'},
      });
      expect(deleted['ok'], isTrue);
      expect(deleted['result'], isNull);
    });

    test('merges object writes into character variable scope', () async {
      await characterRepo.put(
        Character(
          id: 'c1',
          name: 'Alice',
          extensions: {
            'depth_prompt': {'prompt': 'keep'},
          },
        ),
      );

      await bridge.dispatch({
        'method': 'setVariables',
        'params': {
          'scope': 'character',
          'values': {
            'flags': {'met': true},
          },
        },
      });

      final read = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'character', 'path': 'flags.met'},
      });
      expect(read['ok'], isTrue);
      expect(read['result'], isTrue);

      final character = await characterRepo.getById('c1');
      expect(character!.extensions['depth_prompt'], {'prompt': 'keep'});
    });

    test('rejects non-json-compatible values', () async {
      final result = await bridge.dispatch({
        'method': 'setVariables',
        'params': {'scope': 'chat', 'path': 'bad', 'value': double.nan},
      });

      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });
  });

  group('JsBridgeService generateText', () {
    test('delegates prompt and options to injected handler', () async {
      final bridge = TestJsBridge.create(
        chatRepo: chatRepo,
        characterRepo: characterRepo,
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: (_) => true,
        generateText: (prompt, options, context) async {
          expect(prompt, 'Write a short line');
          expect(options['preset'], 'small');
          expect(context['sessionId'], 's1');
          return 'Generated line';
        },
      );

      final result = await bridge.dispatch({
        'method': 'generateText',
        'params': {
          'prompt': 'Write a short line',
          'options': {'preset': 'small'},
        },
        'context': {'sessionId': 's1'},
      });

      expect(result['ok'], isTrue);
      expect(result['result'], 'Generated line');
    });

    test('rejects unsupported preset names', () async {
      final result = await bridge.dispatch({
        'method': 'generateText',
        'params': {
          'prompt': 'Hello',
          'options': {'preset': 'tiny'},
        },
      });

      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });
  });

  group('JsBridgeService prompt injection', () {
    test('delegates injectPrompt to injected handler', () async {
      final bridge = TestJsBridge.create(
        currentSessionId: () => 's1',
        permissionCheck: (_) => true,
        injectPrompt: (id, content, options, context) {
          expect(id, 'mood');
          expect(content, 'Keep the scene tense.');
          expect(options['depth'], 1);
          expect(context['sessionId'], 's1');
          return {'id': id, 'depth': options['depth'], 'role': 'system'};
        },
      );

      final result = await bridge.dispatch({
        'method': 'injectPrompt',
        'params': {
          'id': 'mood',
          'content': 'Keep the scene tense.',
          'options': {'depth': 1},
        },
        'context': {'sessionId': 's1'},
      });

      expect(result['ok'], isTrue);
      expect(result['result'], {'id': 'mood', 'depth': 1, 'role': 'system'});
    });

    test('delegates uninjectPrompt to injected handler', () async {
      final bridge = TestJsBridge.create(
        currentSessionId: () => 's1',
        permissionCheck: (_) => true,
        uninjectPrompt: (id, context) {
          expect(id, 'mood');
          expect(context['sessionId'], 's1');
          return {'id': id, 'removed': true};
        },
      );

      final result = await bridge.dispatch({
        'method': 'uninjectPrompt',
        'params': {'id': 'mood'},
        'context': {'sessionId': 's1'},
      });

      expect(result['ok'], isTrue);
      expect(result['result'], {'id': 'mood', 'removed': true});
    });

    test('rejects empty injectPrompt content', () async {
      final result = await bridge.dispatch({
        'method': 'injectPrompt',
        'params': {'id': 'mood', 'content': '   '},
      });

      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });
  });

  group('JsBridgeService triggerGeneration', () {
    test('delegates to injected handler with resolved charId', () async {
      final bridge = TestJsBridge.create(
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: (_) => true,
        triggerGeneration: (charId, params) async {
          expect(charId, 'c1');
          expect(params['mode'], 'continue');
          expect(params['reason'], 'tick');
          return {'accepted': true, 'mode': 'continue', 'reason': 'tick'};
        },
      );

      final result = await bridge.dispatch({
        'method': 'triggerGeneration',
        'params': {'mode': 'continue', 'reason': 'tick'},
      });

      expect(result['ok'], isTrue);
      expect(result['result'], {
        'accepted': true,
        'mode': 'continue',
        'reason': 'tick',
      });
    });

    test('prefers context.characterId over currentCharacterId', () async {
      final bridge = TestJsBridge.create(
        currentCharacterId: () => 'fallback',
        permissionCheck: (_) => true,
        triggerGeneration: (charId, params) async {
          return {'accepted': true, 'charId': charId};
        },
      );

      final result = await bridge.dispatch({
        'method': 'triggerGeneration',
        'params': {'mode': 'auto'},
        'context': {'characterId': 'explicit'},
      });

      expect(result['ok'], isTrue);
      expect(result['result'], {'accepted': true, 'charId': 'explicit'});
    });

    test(
      'rejects non-string params when the typed handler validates them',
      () async {
        // The validation contract lives in `TriggerGenerationHandler`; the
        // bridge service itself is a thin dispatcher that propagates
        // exceptions. We simulate the typed handler throwing an
        // ArgumentError (mirroring real behavior) and check the bridge
        // converts it into `invalid_request`.
        final bridge = TestJsBridge.create(
          currentCharacterId: () => 'c1',
          permissionCheck: (_) => true,
          triggerGeneration: (charId, params) async {
            if (params['mode'] is! String && params['mode'] != null) {
              throw ArgumentError('triggerGeneration mode must be a string');
            }
            if (params['reason'] is! String && params['reason'] != null) {
              throw ArgumentError('triggerGeneration reason must be a string');
            }
            return {'accepted': true};
          },
        );

        final badMode = await bridge.dispatch({
          'method': 'triggerGeneration',
          'params': {'mode': 42},
        });
        expect(badMode['ok'], isFalse);
        expect(badMode['error']['code'], 'invalid_request');

        final badReason = await bridge.dispatch({
          'method': 'triggerGeneration',
          'params': {'mode': 'auto', 'reason': 7},
        });
        expect(badReason['ok'], isFalse);
        expect(badReason['error']['code'], 'invalid_request');
      },
    );

    test('returns bridge_error when no handler is registered', () async {
      final result = await bridge.dispatch({
        'method': 'triggerGeneration',
        'params': {'mode': 'auto'},
      });

      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'unsupported_method');
    });
  });
}

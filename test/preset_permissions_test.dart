import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/models/preset_permissions.dart';
import 'helpers/js_bridge_test_support.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  late AppDatabase db;
  late CharacterRepo characterRepo;
  late ChatRepo chatRepo;

  setUp(() async {
    db = _testDb();
    characterRepo = CharacterRepo(db);
    chatRepo = ChatRepo(db);
    await characterRepo.put(Character(id: 'c1', name: 'Alice'));
    await chatRepo.put(
      const ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        sessionVars: {},
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('PresetPermissions.isGranted / isGrantedById', () {
    test('defaults: everything deny except showToast', () {
      const p = PresetPermissions();
      expect(p.isGranted(GlazeCapability.showToast), isTrue);
      expect(p.isGranted(GlazeCapability.readChatVars), isFalse);
      expect(p.isGranted(GlazeCapability.writeChatVars), isFalse);
      expect(p.isGranted(GlazeCapability.generateText), isFalse);
      expect(p.isGranted(GlazeCapability.triggerGeneration), isFalse);
    });

    test('isGrantedById accepts the canonical capability id', () {
      const p = PresetPermissions(readChatVars: true, generateText: true);
      expect(p.isGrantedById('read_chat_vars'), isTrue);
      expect(p.isGrantedById('generate_text'), isTrue);
      expect(p.isGrantedById('write_chat_vars'), isFalse);
      expect(p.isGrantedById('not_a_cap'), isFalse);
    });

    test('copyWithField round-trips for every capability', () {
      const base = PresetPermissions();
      for (final cap in GlazeCapability.values) {
        final flipped = base.copyWithField(cap, true);
        expect(
          flipped.isGranted(cap),
          isTrue,
          reason: 'capability ${cap.id} should be true after flip',
        );
      }
    });
  });

  group('JsBridgeService permission gating', () {
    test(
      'denies setVariables when no permission check is registered',
      () async {
        final bridge = TestJsBridge.create(
          chatRepo: chatRepo,
          characterRepo: characterRepo,
          currentSessionId: () => 's1',
          currentCharacterId: () => 'c1',
        );
        final result = await bridge.dispatch({
          'method': 'setVariables',
          'params': {'scope': 'chat', 'path': 'hp', 'value': 1},
        });
        expect(result['ok'], isFalse);
        expect(result['error']['code'], 'bridge_error');
        expect(
          (result['error']['message'] as String).toLowerCase(),
          contains('permission denied'),
        );
      },
    );

    test('denies setVariables when permission check returns false', () async {
      final bridge = TestJsBridge.create(
        chatRepo: chatRepo,
        characterRepo: characterRepo,
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: (cap) => false,
      );
      final result = await bridge.dispatch({
        'method': 'setVariables',
        'params': {'scope': 'chat', 'path': 'hp', 'value': 1},
      });
      expect(result['ok'], isFalse);
      expect(
        (result['error']['message'] as String),
        contains('write_chat_vars'),
      );
    });

    test('allows setVariables when permission is granted', () async {
      final bridge = TestJsBridge.create(
        chatRepo: chatRepo,
        characterRepo: characterRepo,
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: (cap) =>
            cap == 'write_chat_vars' || cap == 'read_chat_vars',
      );
      final result = await bridge.dispatch({
        'method': 'setVariables',
        'params': {'scope': 'chat', 'path': 'hp', 'value': 7},
      });
      expect(result['ok'], isTrue);
      final read = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'chat', 'path': 'hp'},
      });
      expect(read['ok'], isTrue);
      expect(read['result'], 7);
    });

    test(
      'read requires read capability, write requires write capability',
      () async {
        final bridge = TestJsBridge.create(
          chatRepo: chatRepo,
          characterRepo: characterRepo,
          currentSessionId: () => 's1',
          currentCharacterId: () => 'c1',
          permissionCheck: (cap) => cap == 'write_chat_vars',
        );

        final readDenied = await bridge.dispatch({
          'method': 'getVariables',
          'params': {'scope': 'chat'},
        });
        expect(readDenied['ok'], isFalse);
        expect(
          (readDenied['error']['message'] as String),
          contains('read_chat_vars'),
        );

        final writeOk = await bridge.dispatch({
          'method': 'setVariables',
          'params': {
            'scope': 'chat',
            'values': {'hp': 9},
          },
        });
        expect(writeOk['ok'], isTrue);
      },
    );

    test('character scope is gated by its own capability id', () async {
      final bridge = TestJsBridge.create(
        chatRepo: chatRepo,
        characterRepo: characterRepo,
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: (cap) => cap == 'read_character_vars',
      );
      final result = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'character'},
      });
      expect(result['ok'], isTrue);
    });

    test('generateText is gated by generate_text capability', () async {
      final bridge = TestJsBridge.create(
        currentCharacterId: () => 'c1',
        permissionCheck: (cap) => cap == 'generate_text',
        generateText: (p, o, c) async => 'ok',
      );
      final allowed = await bridge.dispatch({
        'method': 'generateText',
        'params': {'prompt': 'hi'},
      });
      expect(allowed['ok'], isTrue);

      final deniedBridge = TestJsBridge.create(
        currentCharacterId: () => 'c1',
        permissionCheck: (cap) => false,
        generateText: (p, o, c) async => 'ok',
      );
      final denied = await deniedBridge.dispatch({
        'method': 'generateText',
        'params': {'prompt': 'hi'},
      });
      expect(denied['ok'], isFalse);
    });

    test('showToast is allowed by default', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (cap) => cap == 'show_toast',
      );
      final result = await bridge.dispatch({
        'method': 'showToast',
        'params': {'message': 'hi'},
      });
      expect(result['ok'], isTrue);
    });
  });
}

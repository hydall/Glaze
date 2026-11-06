// The tests put the chat mid-generation through the notifier's state.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_message_ops_controller.dart';

void main() {
  test(
    'session operations use the current Ref after provider rebuild',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });

      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c1', name: 'Test', currentSessionIndex: 0));
      for (var index = 0; index < 2; index++) {
        await container
            .read(chatRepoProvider)
            .put(
              ChatSession(
                id: 'c1_$index',
                characterId: 'c1',
                sessionIndex: index,
                messages: [
                  ChatMessage(
                    id: 'm_$index',
                    role: 'assistant',
                    content: 'Session $index',
                    timestamp: index,
                  ),
                ],
              ),
            );
      }

      await container.read(chatProvider('c1').future);
      await container.read(chatProvider('c1').notifier).switchSession(1);

      container.invalidate(chatProvider('c1'));
      await container.read(chatProvider('c1').future);

      final notifier = container.read(chatProvider('c1').notifier);
      await notifier.createNewSession();
      expect(
        container.read(chatProvider('c1')).requireValue.session?.sessionIndex,
        2,
      );

      await notifier.switchSession(0);
      expect(
        container.read(chatProvider('c1')).requireValue.session?.sessionIndex,
        0,
      );
    },
  );

  test(
    'family invalidation reloads rebound sessions after cache clear',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });
      final characters = container.read(characterRepoProvider);
      final chats = container.read(chatRepoProvider);
      await characters.put(const Character(id: 'mother', name: 'Mother'));
      await characters.put(const Character(id: 'variant', name: 'Variant'));
      final original = ChatSession(
        id: 'mother_0',
        characterId: 'mother',
        sessionIndex: 0,
        messages: const [
          ChatMessage(
            id: 'old',
            role: 'assistant',
            content: 'Old',
            timestamp: 0,
          ),
        ],
      );
      await chats.put(original);
      ChatSessionService.updateCache(original);
      expect(
        (await container.read(chatProvider('mother').future)).session?.id,
        'mother_0',
      );

      await chats.put(
        original.copyWith(
          characterId: 'variant',
          messages: const [
            ChatMessage(
              id: 'fresh',
              role: 'assistant',
              content: 'Imported',
              timestamp: 1,
            ),
          ],
        ),
      );
      ChatSessionService.clearCache();
      container.invalidate(chatProvider, asReload: true);

      final mother = await container.read(chatProvider('mother').future);
      final variant = await container.read(chatProvider('variant').future);
      expect(mother.session?.id, isNot('mother_0'));
      expect(variant.session?.id, 'mother_0');
      expect(variant.session?.messages.single.id, 'fresh');
    },
  );

  // Saving the author's note, the chat history screen and cloud sync all
  // invalidate the chat provider. The notifier lives on through the rebuild,
  // and so did the helpers it had built on the Ref of the build before: every
  // one of their operations then found that Ref unmounted and returned
  // without a word — editing, deleting, swiping, the draft and Stop "stopped
  // working" until the app was restarted.
  group('after a provider rebuild', () {
    Future<(ProviderContainer, _GatedChatRepo)> chat() async {
      // Editing reads the reader's regex scripts from the preferences.
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = _GatedChatRepo(db);
      final container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          chatRepoProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(() async {
        container.dispose();
        ChatSessionService.clearCache();
        await db.close();
      });
      await container
          .read(characterRepoProvider)
          .put(const Character(id: 'c1', name: 'Test', currentSessionIndex: 0));
      for (var index = 0; index < 2; index++) {
        await repo.put(
          ChatSession(
            id: 'c1_$index',
            characterId: 'c1',
            sessionIndex: index,
            messages: [
              ChatMessage(id: 'u$index', role: 'user', content: 'One'),
              ChatMessage(
                id: 'a$index',
                role: 'assistant',
                content: 'Two',
                swipes: const ['Two', 'Two again'],
                swipeId: 0,
              ),
              ChatMessage(id: 'x$index', role: 'user', content: 'Three'),
            ],
          ),
        );
      }
      return (container, repo);
    }

    test('edit, delete, swipe, draft and stop use the current Ref', () async {
      final (container, repo) = await chat();
      await container.read(chatProvider('c1').future);
      final before = container.read(chatProvider('c1').notifier);
      expect(
        await before.editMessage(0, 'One, edited'),
        MessageEditOutcome.saved,
      );

      container.invalidate(chatProvider('c1'));
      await container.read(chatProvider('c1').future);
      final notifier = container.read(chatProvider('c1').notifier);

      expect(
        await notifier.editMessage(0, 'One, edited again'),
        MessageEditOutcome.saved,
      );
      await notifier.deleteMessage(2);
      await notifier.changeSwipe(1, 1);
      await notifier.saveDraft('A draft');
      notifier.state = AsyncData(
        container
            .read(chatProvider('c1'))
            .requireValue
            .copyWith(isGenerating: true),
      );
      await notifier.abortGeneration();

      final stored = (await repo.getById('c1_0'))!;
      expect(stored.messages.map((m) => m.content), [
        'One, edited again',
        'Two again',
      ]);
      expect(stored.messages[1].swipeId, 1);
      expect(stored.draft, 'A draft');
      final state = container.read(chatProvider('c1')).requireValue;
      expect(state.isGenerating, isFalse);
      expect(state.messages.map((m) => m.content), [
        'One, edited again',
        'Two again',
      ]);
    });

    // The Ref is handed over, so a rebuild no longer ends an operation under
    // way; what it saved must still not be painted over a chat that moved on.
    test('a stop under way does not bring the chat it left back', () async {
      final (container, repo) = await chat();
      await container.read(chatProvider('c1').future);
      final notifier = container.read(chatProvider('c1').notifier);
      notifier.state = AsyncData(
        container
            .read(chatProvider('c1'))
            .requireValue
            .copyWith(isGenerating: true),
      );
      final gate = repo.holdNextRead('c1_0');
      final stop = notifier.abortGeneration();

      final characters = container.read(characterRepoProvider);
      await characters.put(
        (await characters.getById('c1'))!.copyWith(currentSessionIndex: 1),
      );
      ChatSessionService.clearCache();
      container.invalidate(chatProvider('c1'));
      expect(
        (await container.read(chatProvider('c1').future)).session?.id,
        'c1_1',
      );

      gate.complete();
      await stop;

      expect(
        container.read(chatProvider('c1')).requireValue.session?.id,
        'c1_1',
      );
    });
  });
}

/// A chat repository whose next read of one session waits to be let through:
/// a durable step still in flight while the provider is rebuilt.
class _GatedChatRepo extends ChatRepo {
  _GatedChatRepo(super.db);

  Completer<void>? _gate;
  String? _gatedId;

  Completer<void> holdNextRead(String sessionId) {
    _gatedId = sessionId;
    return _gate = Completer<void>();
  }

  @override
  Future<ChatSession?> getById(String sessionId) async {
    final gate = _gate;
    if (gate != null && sessionId == _gatedId) {
      _gate = null;
      await gate.future;
    }
    return super.getById(sessionId);
  }
}

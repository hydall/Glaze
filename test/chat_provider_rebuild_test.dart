import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';

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
}

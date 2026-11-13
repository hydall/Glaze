import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';

final _serviceProvider = Provider(ChatSessionService.new);

/// Opening a chat decodes its blob; a long roleplay's is tens of megabytes.
/// The session cache is there so that happens once, and loading neighbours
/// ahead of time is for the small ones.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late ChatSessionService service;

  ChatSession session(int index, {int messages = 1, int chars = 10}) =>
      ChatSession(
        id: 'char_$index',
        characterId: 'char',
        sessionIndex: index,
        messages: [
          for (var i = 0; i < messages; i++)
            ChatMessage(id: 'm$i', role: 'user', content: 'x' * chars),
        ],
      );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    service = container.read(_serviceProvider);
    ChatSessionService.clearCache();
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'char', name: 'C', currentSessionIndex: 0));
  });

  tearDown(() async {
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  test(
    'opening reads the row and fills the cache for the switch that follows',
    () async {
      await container.read(chatRepoProvider).put(session(0));

      final first = await service.findExistingSession('char');
      expect(first?.id, 'char_0');
      expect(ChatSessionService.cacheSize, 1);

      // Switching to it finds it in the cache.
      expect(
        identical(await service.switchToSession('char', 0), first),
        isTrue,
      );
    },
  );

  test('a write that bypasses the cache is seen on the next open', () async {
    final repo = container.read(chatRepoProvider);
    await repo.put(session(0));
    await service.findExistingSession('char');

    await repo.updateSessionVarsJson('char_0', (vars) => {...vars, 'k': 'v'});

    final reopened = await service.findExistingSession('char');
    expect(reopened?.sessionVars['k'], 'v');
  });

  test(
    'a small neighbour is loaded ahead; a long one is left on disk',
    () async {
      final repo = container.read(chatRepoProvider);
      await repo.put(session(0));
      await repo.put(session(1, messages: 4));
      // Past the prefetch limit: 3 MB of text.
      await repo.put(session(2, messages: 3, chars: 1024 * 1024));

      await service.switchToSession('char', 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // char_1 itself and its small neighbour char_0; not the 3 MB char_2.
      expect(ChatSessionService.cacheSize, 2);
      expect(
        await repo.messagesJsonLength('char_2'),
        greaterThan(3 * 1024 * 1024),
      );
      expect(await repo.messagesJsonLength('missing'), isNull);
    },
  );
}

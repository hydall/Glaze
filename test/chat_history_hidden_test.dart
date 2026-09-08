import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';

import 'helpers/test_container.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  test('chats of hidden characters are excluded until revealed', () async {
    final charRepo = CharacterRepo(db);
    final chatRepo = ChatRepo(db);

    await charRepo.put(
      Character(id: 'v', name: 'Visible', variantGroupId: 'v'),
    );
    await charRepo.put(
      Character(id: 'h', name: 'Hidden', variantGroupId: 'h', hidden: true),
    );

    await chatRepo.put(
      const ChatSession(
        id: 'sv',
        characterId: 'v',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'm1', role: 'assistant', content: 'hi', timestamp: 1),
        ],
      ),
    );
    await chatRepo.put(
      const ChatSession(
        id: 'sh',
        characterId: 'h',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'm2',
            role: 'assistant',
            content: 'secret',
            timestamp: 2,
          ),
        ],
      ),
    );

    final container = makeContainer(db);
    addTearDown(container.dispose);

    // Hidden by default: only the visible character's chat is listed.
    final defaultList = await container.read(chatHistoryProvider.future);
    expect(defaultList.map((s) => s.characterId), ['v']);

    // Reveal via the same 10-tap gesture the My Characters list uses.
    final reveal = container.read(revealHiddenCharactersProvider.notifier);
    for (var i = 0; i < kRevealHiddenTapCount; i++) {
      reveal.registerCharactersTabTap();
    }
    expect(container.read(revealHiddenCharactersProvider), isTrue);

    // Now both chats surface.
    final revealedList = await container.read(chatHistoryProvider.future);
    expect(revealedList.map((s) => s.characterId).toSet(), {'v', 'h'});
  });

  test('rename preserves concurrently added session variables', () async {
    final chatRepo = ChatRepo(db);
    await chatRepo.put(
      const ChatSession(
        id: 'session',
        characterId: 'orphan',
        sessionIndex: 0,
        sessionVars: {'existing': 'value'},
      ),
    );
    final container = makeContainer(db);
    addTearDown(container.dispose);
    await container.read(chatHistoryProvider.future);

    await chatRepo.updateSessionVarsJson('session', (vars) {
      vars['concurrent'] = 'keep';
      return vars;
    });
    await container
        .read(chatHistoryProvider.notifier)
        .renameSession('session', 'Renamed');

    final durable = await chatRepo.getById('session');
    expect(durable?.sessionVars, {
      'existing': 'value',
      'concurrent': 'keep',
      'sessionName': 'Renamed',
    });
    expect(
      container.read(chatHistoryProvider).requireValue.single.sessionName,
      'Renamed',
    );
  });
}

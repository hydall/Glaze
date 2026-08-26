import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';

final _serviceProvider = Provider(ChatSessionService.new);

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late ChatSessionService service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    service = container.read(_serviceProvider);
    ChatSessionService.clearCache();

    await container
        .read(characterRepoProvider)
        .put(
          const Character(id: 'mother', name: 'Mother', currentSessionIndex: 0),
        );
    await container
        .read(characterRepoProvider)
        .put(
          const Character(
            id: 'variant',
            name: 'Variant',
            variantGroupId: 'mother',
            variantOrder: 1,
            currentSessionIndex: 0,
          ),
        );
    await container
        .read(chatRepoProvider)
        .put(
          ChatSession(
            id: 'mother_0',
            characterId: 'variant',
            sessionIndex: 0,
            messages: const [
              ChatMessage(
                id: 'old-message',
                role: 'assistant',
                content: 'Old variant session',
              ),
            ],
          ),
        );
    await container
        .read(cardEvolutionObservationRepoProvider)
        .insertObservation(
          const CardEvolutionObservation(
            id: 'old-observation',
            sessionId: 'mother_0',
            characterId: 'mother',
            runOrdinal: 1,
            semanticScopeKey: 'character.preference.tea',
            observedChange: 'Prefers tea',
            evidenceClusters: [
              ['old-message'],
            ],
            confidence: 0.8,
            status: 'active',
            firstSeenRun: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  test('new mother session preserves the rebound variant session', () async {
    expect(await service.findExistingSession('mother'), isNull);

    final created = await service.createInitialSession('mother');

    expect(created.id, 'mother_1');
    expect(created.characterId, 'mother');
    expect(created.sessionIndex, 1);

    final oldSession = await container
        .read(chatRepoProvider)
        .getById('mother_0');
    expect(oldSession?.characterId, 'variant');
    expect(oldSession?.messages.single.id, 'old-message');

    final observations = await container
        .read(cardEvolutionObservationRepoProvider)
        .getBySessionId('mother_0');
    expect(observations.map((row) => row.id), ['old-observation']);
    expect(
      await container
          .read(cardEvolutionObservationRepoProvider)
          .getBySessionId('mother_1'),
      isEmpty,
    );

    expect((await service.findExistingSession('mother'))?.id, 'mother_1');
    expect((await service.switchToSession('variant', 0)).id, 'mother_0');
    expect(
      (await container.read(characterRepoProvider).getById('mother'))
          ?.currentSessionIndex,
      1,
    );
  });

  test('explicit new-session creation also skips rebound ids', () async {
    final first = await service.createNewSession('mother');
    final second = await service.createNewSession('mother');

    expect(first.id, 'mother_1');
    expect(second.id, 'mother_2');
    expect(
      (await container.read(chatRepoProvider).getById('mother_0'))?.characterId,
      'variant',
    );
  });

  test('concurrent creation allocates distinct ids', () async {
    final sessions = await Future.wait([
      service.createNewSession('mother'),
      service.createNewSession('mother'),
    ]);

    expect(sessions.map((session) => session.id).toSet(), {
      'mother_1',
      'mother_2',
    });
    expect(
      (await container.read(chatRepoProvider).getById('mother_0'))?.characterId,
      'variant',
    );
    expect(
      (await container.read(characterRepoProvider).getById('mother'))
          ?.currentSessionIndex,
      2,
    );
  });
}

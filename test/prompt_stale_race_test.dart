import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/prompt_build_stale_exception.dart';
import 'package:glaze_flutter/core/llm/prompt_inputs_collector.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const character = Character(id: 'c', name: 'Character', description: 'old');
  const session = ChatSession(id: 's', characterId: 'c', sessionIndex: 0);

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final result = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(result.dispose);
    addTearDown(db.close);
    await result.read(characterRepoProvider).put(character);
    return result;
  }

  PromptInputsCollector collector(
    Ref ref, {
    required Future<void> Function() initialize,
    required PromptHistoryInjector inject,
  }) => PromptInputsCollector(
    ref,
    initializeApiConfigs: initialize,
    readActiveApiConfig: () => const ApiConfig(id: 'api'),
    injectHistory: inject,
    readRuntimePromptBlocks: (_) => const [],
  );

  test(
    'classic build does not enter effective-canon freshness checks',
    () async {
      final c = await container();
      final entered = Completer<void>();
      final release = Completer<void>();
      final provider = Provider((ref) {
        final inputs = collector(
          ref,
          initialize: () async {
            entered.complete();
            await release.future;
          },
          inject: ({required sessionId, required messages}) async => messages,
        );
        return PromptPayloadBuilder(
          ref,
          inputsCollector: inputs,
          initializeApiConfigs: () async {
            entered.complete();
            await release.future;
          },
          readActiveApiConfig: () => const ApiConfig(id: 'api'),
          injectHistory: ({required sessionId, required messages}) async =>
              messages,
          readRuntimePromptBlocks: (_) => const [],
        );
      });

      final future = c
          .read(provider)
          .buildFromSession(
            charId: 'c',
            session: session,
            skipVectorSearch: true,
          );
      await entered.future;
      await c
          .read(characterRepoProvider)
          .put(character.copyWith(description: 'new'));
      release.complete();
      final payload = await future;
      expect(payload.character.description, 'old');
      expect(payload.effectiveCanonProjection, isNull);
    },
  );

  test(
    'prefetched context rejects transition and manual-control changes during history await',
    () async {
      final c = await container();
      final context = await c
          .read(effectiveCanonContextLoaderProvider)
          .load(sessionId: session.id, sourceCharacter: character);
      final entered = Completer<void>();
      final release = Completer<void>();
      final provider = Provider((ref) {
        final inputs = collector(
          ref,
          initialize: () async {},
          inject: ({required sessionId, required messages}) async {
            entered.complete();
            await release.future;
            return messages;
          },
        );
        return PromptPayloadBuilder(
          ref,
          inputsCollector: inputs,
          initializeApiConfigs: () async {},
          readActiveApiConfig: () => const ApiConfig(id: 'api'),
          injectHistory: ({required sessionId, required messages}) async {
            entered.complete();
            await release.future;
            return messages;
          },
          readRuntimePromptBlocks: (_) => const [],
        );
      });
      final future = c
          .read(provider)
          .buildFromPreFetched(
            charId: 'c',
            session: session,
            character: character,
            effectiveCanonContext: context,
            chatApi: const ApiConfig(id: 'api'),
            includeEffectiveCanon: true,
            preset: null,
            persona: null,
            lorebooks: const [],
          );
      await entered.future;
      await c
          .read(appliedCanonTransitionRepoProvider)
          .insert(
            AppliedCanonTransitionRecord(
              id: 'transition',
              characterId: 'c',
              chatSessionId: 's',
              rewriteOperationId: 'op',
              revision: context.effectiveRevision.number,
              revisionHash: context.effectiveRevision.hash,
              semanticScopeKey: 'npc:alice',
              canonicalClaim: 'Alice changed',
              promotionDestination: 'card',
              affectedTrackerKeys: const ['npc:alice.state'],
              transitionJson: '{}',
            ),
          );
      await c
          .read(trackerRepoProvider)
          .upsert(
            const Tracker(
              sessionId: 's',
              name: 'canon_override:npc:alice.state',
              value: 'manual',
              scope: 'ledger',
              updatedAt: 1,
            ),
          );
      release.complete();
      await expectLater(future, throwsA(isA<PromptBuildStaleException>()));
    },
  );

  test('classic collector ignores effective-canon changes', () async {
    final c = await container();
    final entered = Completer<void>();
    final release = Completer<void>();
    final provider = Provider(
      (ref) => collector(
        ref,
        initialize: () async {
          entered.complete();
          await release.future;
        },
        inject: ({required sessionId, required messages}) async => messages,
      ),
    );
    final future = c
        .read(provider)
        .collectInputs(charId: 'c', session: session);
    await entered.future;
    await c
        .read(characterKnowledgeFactRepoProvider)
        .insertTentative(
          const CharacterKnowledgeFact(
            id: 'fact',
            chatSessionId: 's',
            knowerKey: 'user',
            subjectKey: 'alice',
            factClass: CharacterKnowledgeFactClass.knowledge,
            predicate: 'knows',
            object: 'truth',
            epistemicState: CharacterKnowledgeEpistemicState.confirmed,
            sourceMessageId: 'm',
            sourceSwipeId: 0,
            sourceAgentSwipeId: 0,
          ),
        );
    await c
        .read(trackerSnapshotRepoProvider)
        .upsertTrackers(
          sessionId: 's',
          messageId: 'm',
          swipeId: 0,
          agentSwipeId: 0,
          committed: true,
          trackers: const [
            Tracker(
              sessionId: 's',
              name: 'world:weather',
              value: 'rain',
              scope: 'ledger',
            ),
          ],
        );
    release.complete();
    final inputs = await future;
    expect(inputs.effectiveCanonProjection, isNull);
    expect(inputs.character.description, 'old');
  });
}

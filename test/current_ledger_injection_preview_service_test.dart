import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_raw_tracker_state.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/features/chat/services/current_ledger_injection_preview_service.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chats;
  late CharacterRepo characters;
  late CharacterKnowledgeFactRepo facts;
  late CharacterRevisionRepo revisions;
  late CurrentLedgerInjectionPreviewService service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chats = ChatRepo(db);
    characters = CharacterRepo(db);
    facts = CharacterKnowledgeFactRepo(db);
    revisions = CharacterRevisionRepo(db);
    final character = Character(id: 'c', name: 'Alice');
    final session = ChatSession(
      id: 's',
      characterId: 'c',
      sessionIndex: 0,
      messages: const [
        ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: 'Alice revealed the hidden map.',
        ),
      ],
    );
    await characters.put(character);
    await chats.put(session);
    await facts.insertTentative(
      const CharacterKnowledgeFact(
        id: 'f1',
        chatSessionId: 's',
        knowerKey: 'alice',
        knowerName: 'Alice',
        subjectKey: 'map',
        subjectName: 'map',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'location',
        object: 'hidden',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'm1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      ),
    );
    await facts.activateAnchor(
      sessionId: 's',
      messageId: 'm1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    final loader = EffectiveCanonContextLoader(
      db: db,
      characterRepo: characters,
      characterRevisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: facts,
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      loadRawTrackerState: (_) async =>
          LedgerRawTrackerState(committedTrackers: [], manualControls: []),
    );
    service = CurrentLedgerInjectionPreviewService(
      chats,
      characters,
      loader,
      (_) async => StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 's', enabled: true),
        preset: const StudioPreset(id: 'preset'),
        pipelineSettings: const PipelineSettings(),
        apiConfigs: const [],
        activeApiConfig: null,
      ),
      (_, messages) async => messages,
      (_, _) => 'User',
    );
  });

  tearDown(() => db.close());

  test(
    'compares legacy and gap filler against the current visible window',
    () async {
      final preview = await service.load(
        sessionId: 's',
        expectedCharacterId: 'c',
      );

      expect(preview.configuredMode, LedgerPromptInjectionMode.legacy);
      expect(preview.visibleMessageIds, contains('m1'));
      expect(preview.legacy.value.filteredProjection.facts, hasLength(1));
      expect(preview.gapFiller.value.filteredProjection.facts, isEmpty);
      expect(
        preview.gapFiller.value.diagnostics.single.reason.name,
        'visibleSourceEvidence',
      );
    },
  );

  test(
    'preview is read-only and does not create character revisions',
    () async {
      expect(await revisions.getForCharacter('c'), isEmpty);

      await service.load(sessionId: 's');

      expect(await revisions.getForCharacter('c'), isEmpty);
    },
  );
}

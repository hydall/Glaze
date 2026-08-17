// ignore_for_file: lines_longer_than_80_chars

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_export_parser.dart';
import 'package:glaze_flutter/core/llm/knowledge_cleanup_parser.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_prompt.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/prompt/ledger_tracker_loader.dart';
import 'package:glaze_flutter/core/llm/prompt_payload_builder.dart'
    show kCompileStudioSessionStateForTest;
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/knowledge_cleanup.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

AppDatabase _db() => AppDatabase.forTesting(NativeDatabase.memory());

final _ledgerTrackerLoaderProvider = Provider<LedgerTrackerLoader>(
  (ref) => LedgerTrackerLoader(ref),
);

const _validJson = '''
{
  "sceneState": {
    "time": "00:48",
    "date": "16-01-2077",
    "location": "Watson streets",
    "immediateThread": "Lucy and Danvi are riding.",
    "presentEntities": [
      { "name": "Lucyna Kushinada", "status": "present", "confidence": "high" }
    ],
    "activeTensions": []
  },
  "entities": [
    {
      "name": "Lucyna Kushinada",
      "aliases": ["Lucy"],
      "type": "npc",
      "relationshipToUser": "fragile alliance",
      "attitudeToUser": "wary but familiar",
      "knowledge": ["Danvi knows her role in David's fate"],
      "boundaries": [],
      "cardOverrides": ["Do not treat Danvi as a random newcomer to Lucy."]
    }
  ],
  "arcState": [
    {
      "id": "david_fate",
      "title": "David's fate revelation",
      "status": "completed",
      "summary": "Danvi knows Lucy's role in David's fate.",
      "doNotReopen": true,
      "cardOverride": "Treat David's fate as resolved backstory.",
      "entities": ["Lucyna Kushinada", "Danvi"]
    }
  ],
  "ops": [
    {
      "op": "set",
      "key": "npc:Lucyna Kushinada.relationship_to_user",
      "value": "fragile alliance",
      "evidence": "Lucy accepted a shared ride.",
      "eventState": "completed"
    },
    {
      "op": "set",
      "key": "relationship:Lucyna Kushinada:Danvi.trust",
      "value": "fragile but established",
      "evidence": "Lucy accepted a shared ride.",
      "eventState": "completed"
    },
    {
      "op": "set",
      "key": "arc:david_fate.status",
      "value": "completed",
      "evidence": "Arc resolved this turn.",
      "eventState": "completed"
    }
  ]
}
''';

const _rawResponse =
    '''
<studio_ledger>
Lucy accepted a fragile alliance with Danvi.
</studio_ledger>

<glaze_memory_export>
$_validJson
</glaze_memory_export>
''';

List<Tracker> _makeTrackers(
  String sessionId,
  Map<String, String> nameValues, {
  String scope = 'ledger',
}) {
  return nameValues.entries
      .map(
        (e) => Tracker(
          sessionId: sessionId,
          name: e.key,
          value: e.value,
          scope: scope,
        ),
      )
      .toList();
}

List<ChatMessage> _conversation(int assistantCount) {
  final messages = <ChatMessage>[
    const ChatMessage(
      id: 'a0',
      role: 'assistant',
      content: 'Opening assistant message',
    ),
  ];
  for (var i = 1; i <= assistantCount; i++) {
    messages.add(ChatMessage(id: 'u$i', role: 'user', content: 'User turn $i'));
    messages.add(
      ChatMessage(id: 'a$i', role: 'assistant', content: 'Assistant turn $i'),
    );
  }
  return messages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  const parser = StudioLedgerExportParser();

  group('StudioLedgerPrompt', () {
    test('injects full values only for relevant existing state', () {
      final prompt = const StudioLedgerPrompt().build(
        finalAssistantText: 'Lucy checks the door.',
        recentHistoryText: 'Danvi asks Lucy about the plan.',
        currentTrackers: _makeTrackers('s', {
          'world:time': '00:48',
          'scene.present_entities': 'Lucy, Danvi',
          'npc:Lucy.attitude_to_user': 'wary but familiar',
          'npc:Rebecca.attitude_to_user': 'friendly',
          'arc:door_plan.status': 'active',
        }),
        recentMemoryEntries: const [],
      );

      expect(prompt, contains('world:time: 00:48'));
      expect(prompt, contains('npc:Lucy.attitude_to_user: wary but familiar'));
      final currentState = RegExp(
        r'<current_state>([\s\S]*?)</current_state>',
      ).firstMatch(prompt)!.group(1)!;
      expect(currentState, isNot(contains('npc:Rebecca.attitude_to_user')));
      expect(prompt, contains('<existing_keys>'));
      expect(prompt, contains('npc:Rebecca.attitude_to_user'));
      expect(prompt, contains('from <current_state> or <existing_keys>'));
      expect(prompt, contains('"knowledgeFacts"'));
      expect(prompt, isNot(contains('durableFacts')));
      expect(prompt, isNot(contains('Max value length')));
      expect(prompt, contains('Identity resolution overrides exact-key reuse'));
      expect(prompt, contains('delete npc:Name.location'));
      expect(prompt, contains('never use it as a backlog'));
      expect(prompt, contains('accepted assistant prose as evidence'));
    });

    test('rejects append histories and legacy knowledge tracker keys', () {
      const raw = '''
<glaze_memory_export>
{"ops":[
  {"op":"append_unique","key":"npc:Lucy.boundaries","value":"new"},
  {"op":"set","key":"npc:Lucy.knowledge","value":"history blob"}
]}
</glaze_memory_export>
''';

      final result = parser.parse(raw);
      expect(result.export, isNull);
      expect(result.rejectionReason, contains('all ops rejected'));
      // Which ops were dropped is the only way to tell a prompt-shape problem
      // from a model regression, so the reasons must survive the parse.
      expect(result.rejectedOps, hasLength(2));
      expect(result.rejectedOps.join('\n'), contains('append_unique'));
      expect(result.rejectedOps.join('\n'), contains('npc:Lucy.knowledge'));
    });

    test('legacy per-turn compatibility profile is parser-compatible', () {
      final prompt = const StudioLedgerPrompt().buildLegacyTurnOnly(
        finalAssistantText: 'Lucy closes the door.',
        recentHistoryText: 'User: Leave now.',
        currentTrackers: const [],
        recentMemoryEntries: const [],
      );

      expect(prompt, contains('<glaze_memory_export>'));
      expect(prompt, contains('{"ops":[],"knowledgeFacts":[]}'));
      expect(prompt, contains('Allowed ops: set, delete'));
      expect(prompt, isNot(contains('rename_entity')));
      expect(prompt, isNot(contains('accepted assistant prose as evidence')));
    });
  });

  group('Ledger reconciliation', () {
    test('manual plan ends at the requested assistant and stays bounded', () {
      final messages = <ChatMessage>[
        const ChatMessage(id: 'a0', role: 'assistant', content: 'Opening'),
        for (var i = 1; i <= 12; i++) ...[
          ChatMessage(id: 'u$i', role: 'user', content: 'User $i'),
          ChatMessage(id: 'a$i', role: 'assistant', content: 'Assistant $i'),
        ],
      ];

      final plan = const LedgerReconciliationPlanner().planForEndpoint(
        messages: messages,
        endAssistantMessageId: 'a12',
      );

      expect(plan, isNotNull);
      expect(plan!.endMessage.id, 'a12');
      expect(plan.messages, hasLength(20));
      expect(plan.startMessageId, 'u3');
    });

    const planner = LedgerReconciliationPlanner();

    test('runs after each five new assistants and excludes the trigger', () {
      final messages = [
        ..._conversation(5),
        const ChatMessage(id: 'u6', role: 'user', content: 'User turn 6'),
        const ChatMessage(
          id: 'a6',
          role: 'assistant',
          content: 'Assistant turn 6',
        ),
      ];
      final plan = planner.plan(
        messages: messages,
        currentAssistantMessageId: 'a6',
      );
      expect(plan, isNotNull);
      expect(plan!.endMessage.id, 'a5');
      expect(plan.messageIds, [
        'a0',
        'u1',
        'a1',
        'u2',
        'a2',
        'u3',
        'a3',
        'u4',
        'a4',
        'u5',
        'a5',
      ]);

      final checkpoint = LedgerReconciliationCheckpoint(
        sessionId: 's',
        startMessageId: plan.startMessageId,
        endMessageId: plan.endMessage.id,
        endSwipeId: plan.endMessage.swipeId,
        endAgentSwipeId: plan.endMessage.agentSwipeId,
        messageIds: plan.messageIds,
        rangeHash: plan.rangeHash,
      );
      expect(
        planner.plan(
          messages: messages,
          currentAssistantMessageId: 'a6',
          checkpoint: checkpoint,
        ),
        isNull,
      );
      final nextMessages = [
        ..._conversation(10),
        const ChatMessage(id: 'u11', role: 'user', content: 'User turn 11'),
        const ChatMessage(
          id: 'a11',
          role: 'assistant',
          content: 'Assistant turn 11',
        ),
      ];
      final next = planner.plan(
        messages: nextMessages,
        currentAssistantMessageId: 'a11',
        previousEndMessageId: 'a5',
        checkpoint: checkpoint,
      );
      expect(next, isNotNull);
      expect(next!.endMessage.id, 'a10');
      expect(next.messageIds, isNot(contains('a11')));
      expect(next.messages, hasLength(18));
      expect(next.startMessageId, 'u2');
      // Rolling context remains intentionally overlapping, but chunk 1 is
      // never split merely to fill the two remaining message slots.
      expect(next.messageIds, contains('a5'));
      expect(next.messageIds, isNot(contains('a0')));
      expect(
        planner.plan(
          messages: [
            ..._conversation(6),
            const ChatMessage(id: 'a7', role: 'assistant', content: 'Current'),
          ],
          currentAssistantMessageId: 'a7',
          checkpoint: checkpoint,
        ),
        isNull,
      );
    });

    test('changed accepted content invalidates the range fingerprint', () {
      final messages = [
        ..._conversation(5),
        const ChatMessage(id: 'u6', role: 'user', content: 'User turn 6'),
        const ChatMessage(
          id: 'a6',
          role: 'assistant',
          content: 'Assistant turn 6',
        ),
      ];
      final original = planner.plan(
        messages: messages,
        currentAssistantMessageId: 'a6',
      )!;
      final checkpoint = LedgerReconciliationCheckpoint(
        sessionId: 's',
        startMessageId: original.startMessageId,
        endMessageId: original.endMessage.id,
        endSwipeId: original.endMessage.swipeId,
        endAgentSwipeId: original.endMessage.agentSwipeId,
        messageIds: original.messageIds,
        rangeHash: original.rangeHash,
      );
      final changed = [...messages];
      changed[10] = changed[10].copyWith(content: 'Changed accepted swipe');
      expect(
        planner.plan(
          messages: changed,
          currentAssistantMessageId: 'a6',
          checkpoint: checkpoint,
        ),
        isNotNull,
      );
    });

    test('hidden assistant messages do not advance cadence', () {
      final messages = [
        ..._conversation(5),
        const ChatMessage(
          id: 'hidden',
          role: 'assistant',
          content: 'Internal',
          isHidden: true,
        ),
        const ChatMessage(id: 'u6', role: 'user', content: 'User turn 6'),
        const ChatMessage(
          id: 'a6',
          role: 'assistant',
          content: 'Assistant turn 6',
        ),
      ];
      final plan = planner.plan(
        messages: messages,
        currentAssistantMessageId: 'a6',
      );
      expect(plan, isNotNull);
      expect(plan!.endMessage.id, 'a5');
      expect(plan.messageIds, isNot(contains('hidden')));
    });

    test('review range is bounded to twenty physical messages', () {
      final messages = _conversation(11);
      final plan = planner.plan(
        messages: messages,
        currentAssistantMessageId: 'a11',
        previousEndMessageId: 'a5',
      )!;
      expect(plan.messages, hasLength(18));
      expect(plan.startMessageId, 'u2');
      expect(plan.endMessage.id, 'a10');
    });

    test(
      'prompt includes stale placeholder state outside direct name match',
      () {
        final messages = [
          ..._conversation(5),
          const ChatMessage(id: 'u6', role: 'user', content: 'User turn 6'),
          const ChatMessage(
            id: 'a6',
            role: 'assistant',
            content: 'Assistant turn 6',
          ),
        ];
        final plan = planner.plan(
          messages: messages,
          currentAssistantMessageId: 'a6',
        )!;
        final prompt = const StudioLedgerReconciliationPrompt().build(
          systemPrompt: 'DB PROMPT',
          plan: plan,
          trackers: _makeTrackers('s', {
            'npc:Unidentified Netrunner.location': 'Afterlife bar',
            'npc:Rebecca.location': 'Elsewhere',
          }),
        );
        expect(prompt, contains('DB PROMPT'));
        expect(prompt, contains('npc:Unidentified Netrunner.location'));
        expect(prompt, contains('npc:Rebecca.location'));
        final state = RegExp(
          r'<committed_state>([\s\S]*?)</committed_state>',
        ).firstMatch(prompt)!.group(1)!;
        expect(state, contains('npc:Rebecca.location'));
      },
    );

    test('candidate keys include mentioned entity siblings and provenance', () {
      final messages = [
        const ChatMessage(id: 'a0', role: 'assistant', content: 'Opening.'),
        const ChatMessage(id: 'u1', role: 'user', content: 'Where is Lucy?'),
        const ChatMessage(id: 'a1', role: 'assistant', content: 'Lucy waits.'),
      ];
      final plan = const LedgerReconciliationPlanner().planForEndpoint(
        messages: messages,
        endAssistantMessageId: 'a1',
      )!;
      final trackers = [
        ..._makeTrackers('s', {
          'npc:Lucy.location': 'bar',
          'npc:Lucy.current_goal': 'wait',
          'npc:Rebecca.location': 'street',
        }),
        const Tracker(
          sessionId: 's',
          name: 'arc:old_debt.status',
          value: 'active',
          scope: 'ledger',
          provenance: 'source=studio_ledger|message=a1|swipe=0|agentSwipe=0',
        ),
      ];

      final candidates = const StudioLedgerReconciliationPrompt()
          .candidateTrackers(
            trackers: trackers,
            plan: plan,
            chat: 'Where is Lucy? Lucy waits.',
          );

      expect(
        candidates.map((tracker) => tracker.name),
        containsAll([
          'npc:Lucy.location',
          'npc:Lucy.current_goal',
          'arc:old_debt.status',
        ]),
      );
    });

    test('candidate keys and values share a hard bounded set', () {
      final messages = [
        const ChatMessage(id: 'a0', role: 'assistant', content: 'Opening.'),
        const ChatMessage(id: 'u1', role: 'user', content: 'Continue.'),
        const ChatMessage(id: 'a1', role: 'assistant', content: 'Continued.'),
      ];
      final plan = const LedgerReconciliationPlanner().planForEndpoint(
        messages: messages,
        endAssistantMessageId: 'a1',
      )!;
      final trackers = [
        for (var i = 0; i < 150; i++)
          Tracker(
            sessionId: 's',
            name: 'npc:Person$i.location',
            value: 'Location $i',
            scope: 'ledger',
          ),
      ];

      final prompt = const StudioLedgerReconciliationPrompt().build(
        systemPrompt: 'PROMPT',
        plan: plan,
        trackers: trackers,
      );
      final state = RegExp(
        r'<committed_state>([\s\S]*?)</committed_state>',
      ).firstMatch(prompt)!.group(1)!;
      final keys = RegExp(
        r'<existing_keys>([\s\S]*?)</existing_keys>',
      ).firstMatch(prompt)!.group(1)!;
      final stateNames = state
          .trim()
          .split('\n')
          .map((line) => line.substring(0, line.lastIndexOf(': ')))
          .toSet();
      final keyNames = keys.trim().split('\n').toSet();

      expect(stateNames, hasLength(100));
      expect(keyNames, stateNames);
    });

    test('exact duplicate cleanup preserves facts for different knowers', () {
      const base = CharacterKnowledgeFact(
        id: 'older',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:leon',
        factClass: CharacterKnowledgeFactClass.knowledge,
        scopeKey: 'event:silence',
        predicate: 'observed',
        object: 'Leon was silenced.',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
        lifecycle: CharacterKnowledgeFactLifecycle.active,
        updatedAt: 1,
      );
      final facts = [
        base,
        base.copyWith(id: 'newer', sourceMessageId: 'a2', updatedAt: 2),
        base.copyWith(
          id: 'other-witness',
          knowerKey: 'entity:sylvie',
          sourceMessageId: 'a2',
          updatedAt: 2,
        ),
      ];

      final ops = exactDuplicateKnowledgeRetractions(facts);

      expect(ops.map((op) => op.factId), ['older']);
    });

    test('exact duplicate cleanup does not merge epistemic states', () {
      const observed = CharacterKnowledgeFact(
        id: 'observed',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:leon',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'location',
        object: 'West gate',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
        lifecycle: CharacterKnowledgeFactLifecycle.active,
      );

      expect(
        exactDuplicateKnowledgeRetractions([
          observed,
          observed.copyWith(
            id: 'heard',
            epistemicState: CharacterKnowledgeEpistemicState.heardClaim,
          ),
        ]),
        isEmpty,
      );
    });

    test('stale knowledge cleanup retracts rejected swipe provenance', () {
      const fact = CharacterKnowledgeFact(
        id: 'stale',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:marta',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'identity',
        object: 'Marta owns the tavern.',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );
      const accepted = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Accepted reroll',
        swipeId: 1,
        agentSwipeId: 0,
      );

      final ops = staleKnowledgeAnchorRetractions(
        [
          fact,
          fact.copyWith(id: 'current', sourceSwipeId: 1),
          fact.copyWith(id: 'outside-range', sourceMessageId: 'a0'),
        ],
        const [accepted],
      );

      expect(ops.map((op) => op.factId), ['stale']);
    });

    test(
      'checkpoint is invalidated by delete and copied only with full range',
      () async {
        final db = _db();
        final repo = LedgerReconciliationCheckpointRepo(db);
        addTearDown(db.close);
        const checkpoint = LedgerReconciliationCheckpoint(
          sessionId: 'source',
          startMessageId: 'm1',
          endMessageId: 'm3',
          endSwipeId: 0,
          endAgentSwipeId: 0,
          messageIds: ['m1', 'm2', 'm3'],
          rangeHash: 'hash',
        );
        await repo.upsert(checkpoint);
        await repo.copyForSessionBranch(
          fromSessionId: 'source',
          toSessionId: 'partial',
          messageIds: {'m2', 'm3'},
        );
        await repo.copyForSessionBranch(
          fromSessionId: 'source',
          toSessionId: 'full',
          messageIds: {'m1', 'm2', 'm3', 'm4'},
        );
        expect(await repo.get('partial'), isNull);
        expect(await repo.get('full'), isNotNull);

        await repo.deleteForMessages('source', {'m2'});
        expect(await repo.get('source'), isNull);
      },
    );

    test('knowledge cleanup accepts only offered bounded operations', () {
      const offered = CharacterKnowledgeFact(
        id: 'fact-1',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:unidentified_netrunner',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'identity',
        object: 'Unknown netrunner',
        epistemicState: CharacterKnowledgeEpistemicState.inferred,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );
      const output = '''
<glaze_knowledge_cleanup>
{"ops":[
  {"op":"retract","factId":"fact-1"},
  {"op":"retract","factId":"guessed-id"},
  {"op":"rename_entity","fromKey":"entity:unidentified_netrunner","toKey":"entity:lucy","canonicalName":"Lucy"}
]}
</glaze_knowledge_cleanup>
''';

      final ops = const KnowledgeCleanupParser().parse(
        output: output,
        offeredFacts: const [offered],
        reviewText: 'Regina identifies the netrunner as Lucy.',
      );

      expect(ops, hasLength(2));
      expect(ops.first.type, KnowledgeCleanupOpType.retract);
      expect(ops.first.factId, 'fact-1');
      expect(ops.last.type, KnowledgeCleanupOpType.renameEntity);
      expect(ops.last.toKey, 'entity:lucy');
    });

    test('knowledge cleanup rejects unsafe identity migration', () {
      const named = CharacterKnowledgeFact(
        id: 'fact-1',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:rebecca',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'identity',
        object: 'Rebecca',
        epistemicState: CharacterKnowledgeEpistemicState.confirmed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );
      const output = '''
<glaze_knowledge_cleanup>
{"ops":[
  {"op":"rename_entity","fromKey":"entity:rebecca","toKey":"entity:lucy","canonicalName":"Lucy"},
  {"op":"rename_entity","fromKey":"entity:unknown_woman","toKey":"entity:lucy","canonicalName":"Lucy"}
]}
</glaze_knowledge_cleanup>
''';

      final ops = const KnowledgeCleanupParser().parse(
        output: output,
        offeredFacts: const [named],
        reviewText: 'Rebecca remains at the bar.',
      );

      expect(ops, isEmpty);
    });

    test('knowledge cleanup accepts a resolved descriptive alias', () {
      const offered = CharacterKnowledgeFact(
        id: 'fact-1',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:woman_in_yellow_jacket',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'location',
        object: 'Afterlife',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );
      const output = '''
<glaze_knowledge_cleanup>
{"ops":[
  {"op":"rename_entity","fromKey":"entity:woman_in_yellow_jacket","toKey":"entity:lucy","canonicalName":"Lucy"}
]}
</glaze_knowledge_cleanup>
''';

      final ops = const KnowledgeCleanupParser().parse(
        output: output,
        offeredFacts: const [offered],
        reviewText: 'The woman in the yellow jacket is identified as Lucy.',
      );

      expect(ops, hasLength(1));
      expect(ops.single.type, KnowledgeCleanupOpType.renameEntity);
      expect(ops.single.fromKey, 'entity:woman_in_yellow_jacket');
      expect(ops.single.toKey, 'entity:lucy');
    });

    test('prompt offers relevant inferred and placeholder facts', () {
      final messages = [
        ..._conversation(5),
        const ChatMessage(id: 'u6', role: 'user', content: 'User turn 6'),
        const ChatMessage(
          id: 'a6',
          role: 'assistant',
          content: 'Assistant turn 6',
        ),
      ];
      final plan = planner.plan(
        messages: messages,
        currentAssistantMessageId: 'a6',
      )!;
      const placeholder = CharacterKnowledgeFact(
        id: 'placeholder',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:unknown_woman',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'location',
        object: 'Afterlife',
        epistemicState: CharacterKnowledgeEpistemicState.observed,
        sourceMessageId: 'a1',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );
      const inferred = CharacterKnowledgeFact(
        id: 'inferred',
        chatSessionId: 's',
        knowerKey: 'entity:helga',
        subjectKey: 'entity:rebecca',
        factClass: CharacterKnowledgeFactClass.knowledge,
        predicate: 'motive',
        object: 'Secret motive',
        epistemicState: CharacterKnowledgeEpistemicState.inferred,
        sourceMessageId: 'a2',
        sourceSwipeId: 0,
        sourceAgentSwipeId: 0,
      );

      final prompt = const StudioLedgerReconciliationPrompt().build(
        systemPrompt: 'DB PROMPT',
        plan: plan,
        trackers: const [],
        knowledgeFacts: const [placeholder, inferred],
      );

      expect(prompt, contains('"id":"placeholder"'));
      expect(prompt, contains('"id":"inferred"'));
      expect(prompt, contains('<glaze_knowledge_cleanup>'));
    });
  });

  // ── Parser tests
  group('StudioLedgerExportParser', () {
    // Test 1
    test('extracts valid JSON from <glaze_memory_export>', () {
      final result = parser.parse(_rawResponse);
      expect(result.export, isNotNull);
      expect(result.export!.ops, hasLength(3));
      expect(result.visibleLedger, contains('fragile alliance'));
      expect(result.wasRejected, isFalse);
    });

    test('extracts valid JSON wrapped in markdown fence', () {
      const raw =
          '''
<glaze_memory_export>
```json
$_validJson
```
</glaze_memory_export>
''';
      final result = parser.parse(raw);
      expect(result.export, isNotNull);
      expect(result.export!.ops, hasLength(3));
      expect(result.wasRejected, isFalse);
    });

    test('keeps valid atomic facts while dropping malformed siblings', () {
      const raw = '''
<glaze_memory_export>
{
  "ops": [],
  "knowledgeFacts": [
    {
      "knowerKey": "entity:lucy",
      "knowerName": "Lucy",
      "subjectKey": "entity:danvi",
      "subjectName": "Danvi",
      "factClass": "relationship",
      "scopeKey": "relationship:danvi",
      "predicate": "trusts",
      "object": "Trusts Danvi with personal risk.",
      "epistemicState": "confirmed",
      "confidence": 1.4,
      "importance": 0.8,
      "entities": ["Lucy", "Danvi"],
      "topics": ["trust"]
    },
    {
      "knowerKey": "entity:lucy",
      "subjectKey": "entity:danvi",
      "predicate": "",
      "object": "Missing predicate",
      "confidence": 0.5,
      "importance": 0.5
    }
  ]
}
</glaze_memory_export>''';

      final result = parser.parse(raw);

      expect(result.export, isNotNull);
      expect(result.export!.knowledgeFacts, hasLength(1));
      expect(result.export!.knowledgeFacts.single.factClass, 'relationship');
      expect(result.export!.knowledgeFacts.single.confidence, 1.0);
    });

    // Test 2
    test('malformed JSON does not crash; returns null export', () {
      const bad = '<glaze_memory_export>{ not json </glaze_memory_export>';
      final result = parser.parse(bad);
      expect(result.export, isNull);
      expect(result.wasRejected, isTrue);
      expect(result.failure, LedgerParseFailure.incompleteJson);
    });

    test('distinguishes missing, malformed, and semantic rejection', () {
      expect(
        parser.parse('no block').failure,
        LedgerParseFailure.missingExport,
      );
      expect(
        parser
            .parse('<glaze_memory_export>{not json}</glaze_memory_export>')
            .failure,
        LedgerParseFailure.malformedJson,
      );
      expect(
        parser
            .parse(
              '<glaze_memory_export>{"ops":[{"op":"bad"}]}</glaze_memory_export>',
            )
            .failure,
        LedgerParseFailure.semanticSchema,
      );
    });

    test('normalizes non-string LLM fields before generated parsing', () {
      const raw = '''
<studio_ledger>
Ledger text.
</studio_ledger>
<glaze_memory_export>
{
  "sceneState": {
    "time": ["night", "late"],
    "location": {"name":"Watson"},
    "immediateThread": ["Lucy waits", "Danvi answers"],
    "presentEntities": ["Lucy", {"name":"Danvi", "reason":["driver", "speaker"]}],
    "activeTensions": [{"tension":"distrust"}]
  },
  "entities": [
    {
      "name": "Lucy",
      "knowledge": [{"fact":"Danvi knows"}]
    }
  ],
  "ops": [
    {
      "op": "set",
      "key": "npc:Lucy.boundaries",
      "value": ["Danvi knows", "Lucy reacted"],
      "evidence": {"source":"assistant"},
      "eventState": "completed"
    }
  ]
}
</glaze_memory_export>
''';

      final result = parser.parse(raw);

      expect(result.export, isNotNull);
      expect(result.export!.ops.single.value, 'Danvi knows; Lucy reacted');
      expect(result.export!.sceneState!.time, 'night; late');
      expect(result.export!.sceneState!.presentEntities, hasLength(2));
    });

    test('missing export block returns null export', () {
      final result = parser.parse('Just some text with no export block.');
      expect(result.export, isNull);
      expect(result.hasExport, isFalse);
    });

    test('rejects unknown op code', () {
      const badOp = '''
<glaze_memory_export>
{
  "ops": [
    {
      "op": "explode",
      "key": "npc:Lucy.mood",
      "value": "happy",
      "evidence": "test",
      "eventState": "completed"
    }
  ]
}
</glaze_memory_export>
''';
      final result = parser.parse(badOp);
      expect(result.export, isNull);
      expect(result.wasRejected, isTrue);
    });

    test('rejects unknown namespace prefix', () {
      const badNs = '''
<glaze_memory_export>
{
  "ops": [
    {
      "op": "set",
      "key": "hack:system.root",
      "value": "pwned",
      "evidence": "test",
      "eventState": "completed"
    }
  ]
}
</glaze_memory_export>
''';
      final result = parser.parse(badNs);
      expect(result.export, isNull);
      expect(result.wasRejected, isTrue);
    });

    test('rejects model-owned tracker and arc state for the focal user', () {
      const raw = '''
<glaze_memory_export>
{
  "ops": [
    {"op":"set","key":"npc:Danvi.current_goal","value":"Protect Chloe","evidence":"Model inference","eventState":"planned"},
    {"op":"set","key":"arc:Danvi.status","value":"active","evidence":"Model inference","eventState":"planned"},
    {"op":"set","key":"relationship:Chloe:Danvi.trust","value":"cautious","evidence":"They spoke","eventState":"completed"}
  ]
}
</glaze_memory_export>''';

      final result = parser.parse(raw, focalUserName: 'Danvi');

      expect(result.export, isNotNull);
      expect(result.export!.ops, hasLength(1));
      expect(result.export!.ops.single.key, 'relationship:Chloe:Danvi.trust');
    });

    test(
      'rejects literal user macro state even without a resolved persona',
      () {
        const raw = '''
<glaze_memory_export>
{"ops":[{"op":"set","key":"npc:{{user}}.current_goal","value":"Fix everything","evidence":"Model inference","eventState":"planned"}]}
</glaze_memory_export>''';

        final result = parser.parse(raw);

        expect(result.export, isNull);
        expect(result.failure, LedgerParseFailure.semanticSchema);
      },
    );

    test('allows focal-user knowledge only as explicit information access', () {
      const raw = '''
<glaze_memory_export>
{
  "ops": [],
  "knowledgeFacts": [
    {
      "knowerKey":"entity:danvi",
      "knowerName":"Danvi",
      "subjectKey":"entity:chloe",
      "subjectName":"Chloe",
      "factClass":"knowledge",
      "scopeKey":"knowledge:chloe:doping_policy",
      "predicate":"heard_doping_policy",
      "object":"Chloe explained the doping policy.",
      "epistemicState":"heard_claim",
      "confidence":0.9,
      "importance":0.6
    },
    {
      "knowerKey":"entity:danvi",
      "knowerName":"Danvi",
      "subjectKey":"entity:chloe",
      "subjectName":"Chloe",
      "factClass":"goal",
      "scopeKey":"goal:danvi",
      "predicate":"wants_to_help",
      "object":"Danvi wants to solve Chloe's problem.",
      "epistemicState":"inferred",
      "confidence":0.7,
      "importance":0.7
    }
  ]
}
</glaze_memory_export>''';

      final result = parser.parse(raw, focalUserName: 'Danvi');

      expect(result.export, isNotNull);
      expect(result.export!.knowledgeFacts, hasLength(1));
      expect(
        result.export!.knowledgeFacts.single.predicate,
        'heard_doping_policy',
      );
    });

    test('rejects oversized current-state values', () {
      final longVal = 'x' * 4000;
      final longOpBlock =
          '<glaze_memory_export>\n'
          '{"ops":[{"op":"set","key":"npc:Lucy.boundaries","value":"$longVal",'
          '"evidence":"test","eventState":"completed"}]}\n'
          '</glaze_memory_export>';
      final result = parser.parse(longOpBlock);
      expect(result.wasRejected, isTrue);
      expect(result.export, isNull);
    });

    test('ignores empty export (no ops or knowledge facts)', () {
      const empty = '''
<glaze_memory_export>
{
  "ops": []
}
</glaze_memory_export>
''';
      final result = parser.parse(empty);
      expect(result.export, isNull);
    });
  });

  // ── TrackerRepo ledger tests ───────────────────────────────────────────────
  group('TrackerRepo — ledger canon state', () {
    late AppDatabase db;
    late TrackerRepo repo;

    setUp(() {
      db = _db();
      repo = TrackerRepo(db);
    });

    tearDown(() async => db.close());

    // Test 5
    test('entity state writes npc:* tracker rows', () async {
      await repo.upsertValue(
        'sess1',
        'npc:Lucyna Kushinada.relationship_to_user',
        'fragile alliance',
        scope: 'ledger',
      );
      final row = await repo.get(
        'sess1',
        'npc:Lucyna Kushinada.relationship_to_user',
      );
      expect(row, isNotNull);
      expect(row!.value, 'fragile alliance');
      expect(row.scope, 'ledger');
    });

    // Test 6
    test(
      'relationship state upsert: only ONE row per key (last write wins)',
      () async {
        const key = 'relationship:Danvi:Lucyna Kushinada.relationship';
        await repo.upsertValue(
          'sess1',
          key,
          'fragile alliance',
          scope: 'ledger',
        );
        await repo.upsertValue('sess1', key, 'cautious trust', scope: 'ledger');

        final all = await repo.getBySessionAndScope('sess1', 'ledger');
        final matches = all.where((t) => t.name == key).toList();
        expect(matches, hasLength(1));
        expect(matches.first.value, 'cautious trust');
      },
    );

    // Test 7
    test('arc state upsert: last write wins', () async {
      const key = 'arc:david_fate.status';
      await repo.upsertValue('sess1', key, 'active', scope: 'ledger');
      await repo.upsertValue('sess1', key, 'completed', scope: 'ledger');

      final row = await repo.get('sess1', key);
      expect(row!.value, 'completed');
    });

    // Test 15
    test('canon_lock:* row blocks ledger updates for that key', () async {
      // Write lock.
      await repo.upsertValue(
        'sess1',
        'canon_lock:npc:Lucy.attitude',
        'true',
        scope: 'ledger',
      );
      // Simulate _applyOp lock check.
      final lock = await repo.get('sess1', 'canon_lock:npc:Lucy.attitude');
      final isLocked =
          lock != null && lock.value.trim().toLowerCase() == 'true';
      expect(isLocked, isTrue);

      // Respect lock: do NOT write the value.
      if (!isLocked) {
        await repo.upsertValue(
          'sess1',
          'npc:Lucy.attitude',
          'hostile',
          scope: 'ledger',
        );
      }

      final val = await repo.get('sess1', 'npc:Lucy.attitude');
      expect(val, isNull);
    });

    // Test 16 — override via compiled state
    test(
      'canon_override outranks model-written canon in prompt assembly',
      () async {
        // Write model canon.
        await repo.upsertValue(
          'sess1',
          'npc:Lucy.mood',
          'wary',
          scope: 'ledger',
        );
        // Write user override.
        await repo.upsertValue(
          'sess1',
          'canon_override:npc:Lucy.mood',
          'hostile; user-corrected',
          scope: 'ledger',
        );

        final all = await repo.getBySessionAndScope('sess1', 'ledger');
        final compiled = kCompileStudioSessionStateForTest(all, 'sess1');
        expect(compiled, isNotNull);
        expect(compiled, contains('hostile; user-corrected'));
        expect(compiled, isNot(contains('wary')));
      },
    );
  });

  // ── MemoryBookRepo sync ingress tests ───────────────────────────────────────
  group('MemoryBookRepo — sync ingress', () {
    late AppDatabase db;
    late MemoryBookRepo repo;
    late ProviderContainer container;

    setUp(() {
      db = _db();
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      repo = container.read(memoryBookRepoProvider);
      addTearDown(container.dispose);
      addTearDown(() => db.close());
    });

    test('sync ingress drops retired agentic entries and drafts', () async {
      const sessionId = 'sess_sync_ingress';
      await repo.put(
        const MemoryBook(
          id: 'memorybook_sess_sync_ingress',
          sessionId: sessionId,
          entries: [
            MemoryEntry(id: 'agent-entry', source: 'agentic'),
            MemoryEntry(id: 'range-entry', source: 'scan'),
          ],
          pendingDrafts: [
            MemoryDraft(id: 'agent-draft', source: 'agentic'),
            MemoryDraft(id: 'scan-draft', source: 'scan'),
          ],
        ),
      );

      final loaded = await repo.getBySessionId(sessionId);
      expect(loaded!.entries.map((entry) => entry.id), ['range-entry']);
      expect(loaded.pendingDrafts.map((draft) => draft.id), ['scan-draft']);
    });
  });

  // ── TrackerSnapshot rollback tests ───────────────────────────────────────
  group('TrackerSnapshotRepo — Studio Canon rollback safety', () {
    late AppDatabase db;
    late TrackerSnapshotRepo snapshotRepo;
    late TrackerRepo trackerRepo;

    setUp(() {
      db = _db();
      snapshotRepo = TrackerSnapshotRepo(db);
      trackerRepo = TrackerRepo(db);
    });

    tearDown(() async => db.close());

    // Test 13
    test(
      'uncommitted regenerated swipe state is not effective canon',
      () async {
        const sessionId = 'sess_snap';

        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: 'msg_old',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(sessionId, {
            'arc:david_fate.status': 'completed',
          }),
          committed: true,
        );

        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: 'msg_regen',
          swipeId: 1,
          agentSwipeId: 0,
          trackers: _makeTrackers(sessionId, {
            'arc:david_fate.status': 'active',
          }),
        );

        final effective = await snapshotRepo.getLatestCommitted(sessionId);
        expect(effective, isNotNull);
        expect(effective!.messageId, 'msg_old');
        expect(effective.trackers.single.value, 'completed');
      },
    );

    // Test 14
    test(
      'deleted source message falls back to previous committed canon',
      () async {
        const sessionId = 'sess_delete';

        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: 'msg_1',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(sessionId, {'npc:Lucy.attitude': 'wary'}),
          committed: true,
        );
        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: 'msg_2',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(sessionId, {'npc:Lucy.attitude': 'trusting'}),
          committed: true,
        );

        await trackerRepo.replaceForSession(
          sessionId,
          _makeTrackers(sessionId, {'npc:Lucy.attitude': 'trusting'}),
        );
        await snapshotRepo.deleteForMessage(sessionId, 'msg_2');
        final fallback = await snapshotRepo.getLatestCommitted(sessionId);
        await trackerRepo.replaceForSession(sessionId, fallback!.trackers);

        final live = await trackerRepo.get(sessionId, 'npc:Lucy.attitude');
        expect(fallback.messageId, 'msg_1');
        expect(live!.value, 'wary');
      },
    );

    test('branch preserves snapshot chronology', () async {
      const source = 'source';
      const branch = 'branch';
      await snapshotRepo.upsert(
        TrackerSnapshot(
          sessionId: source,
          messageId: 'msg_old',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(source, {'scene.state': 'old'}),
          committed: true,
          createdAt: 100,
        ),
      );
      await snapshotRepo.upsert(
        TrackerSnapshot(
          sessionId: source,
          messageId: 'msg_new',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(source, {'scene.state': 'new'}),
          committed: true,
          createdAt: 200,
        ),
      );

      await snapshotRepo.copyForSessionBranch(
        fromSessionId: source,
        toSessionId: branch,
        messageIds: const {'msg_old', 'msg_new'},
      );

      final copied = await snapshotRepo.getBySessionId(branch);
      expect(copied.map((snapshot) => snapshot.createdAt), [200, 100]);
      expect(
        (await snapshotRepo.getLatestCommitted(branch))!.messageId,
        'msg_new',
      );
    });
  });

  // ── Ledger prompt tracker authority ─────────────────────────────────────
  group('LedgerTrackerLoader — prompt authority', () {
    late AppDatabase db;
    late ProviderContainer container;
    late TrackerRepo trackerRepo;
    late TrackerSnapshotRepo snapshotRepo;
    late LedgerTrackerLoader loader;

    setUp(() {
      db = _db();
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      trackerRepo = container.read(trackerRepoProvider);
      snapshotRepo = container.read(trackerSnapshotRepoProvider);
      loader = container.read(_ledgerTrackerLoaderProvider);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('next Ledger prompt excludes a tentative snapshot', () async {
      const sessionId = 'sess_ledger_prompt_authority';
      const key = 'npc:Lucy.attitude_to_user';

      await snapshotRepo.upsertTrackers(
        sessionId: sessionId,
        messageId: 'accepted_turn',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: _makeTrackers(sessionId, {key: 'wary'}),
        committed: true,
      );
      await trackerRepo.upsertValue(
        sessionId,
        key,
        'tentative trust',
        scope: 'ledger',
      );
      await snapshotRepo.upsertTrackers(
        sessionId: sessionId,
        messageId: 'tentative_turn',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: _makeTrackers(sessionId, {key: 'tentative trust'}),
      );

      final prompt = const StudioLedgerPrompt().build(
        finalAssistantText: 'Lucy watches the door.',
        recentHistoryText: '',
        currentTrackers: await loader.loadEffectiveLedgerTrackers(sessionId),
        recentMemoryEntries: const [],
      );

      expect(prompt, contains('$key: wary'));
      expect(prompt, isNot(contains('tentative trust')));
    });

    test(
      'tentative state becomes a Ledger prompt base only after commit',
      () async {
        const sessionId = 'sess_ledger_prompt_commit';
        const key = 'npc:Lucy.attitude_to_user';

        await trackerRepo.upsertValue(
          sessionId,
          key,
          'tentative trust',
          scope: 'ledger',
        );
        await snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: 'tentative_turn',
          swipeId: 0,
          agentSwipeId: 0,
          trackers: _makeTrackers(sessionId, {key: 'tentative trust'}),
        );

        final beforeCommit = const StudioLedgerPrompt().build(
          finalAssistantText: 'Lucy watches the door.',
          recentHistoryText: '',
          currentTrackers: await loader.loadEffectiveLedgerTrackers(sessionId),
          recentMemoryEntries: const [],
        );
        expect(beforeCommit, isNot(contains('tentative trust')));

        await snapshotRepo.commit(
          sessionId: sessionId,
          messageId: 'tentative_turn',
          swipeId: 0,
          agentSwipeId: 0,
        );

        final afterCommit = const StudioLedgerPrompt().build(
          finalAssistantText: 'Lucy watches the door.',
          recentHistoryText: '',
          currentTrackers: await loader.loadEffectiveLedgerTrackers(sessionId),
          recentMemoryEntries: const [],
        );
        expect(afterCommit, contains('$key: tentative trust'));
      },
    );

    test('live manual override supersedes the committed prompt base', () async {
      const sessionId = 'sess_ledger_prompt_override';
      const key = 'npc:Lucy.attitude_to_user';

      await snapshotRepo.upsertTrackers(
        sessionId: sessionId,
        messageId: 'accepted_turn',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: _makeTrackers(sessionId, {key: 'wary'}),
        committed: true,
      );
      await trackerRepo.upsertValue(
        sessionId,
        'canon_override:$key',
        'hostile; user-corrected',
        scope: 'ledger',
      );

      final prompt = const StudioLedgerPrompt().build(
        finalAssistantText: 'Lucy watches the door.',
        recentHistoryText: '',
        currentTrackers: await loader.loadEffectiveLedgerTrackers(sessionId),
        recentMemoryEntries: const [],
      );

      expect(prompt, contains('$key: hostile; user-corrected'));
      expect(prompt, isNot(contains('$key: wary')));
    });
  });

  // ── _compileStudioSessionState tests ─────────────────────────────────────
  group('kCompileStudioSessionStateForTest', () {
    // Test 10
    test('prompt contains session-canon-overrides-card-baseline rule', () {
      final trackers = _makeTrackers('s1', {
        'npc:Lucy.relationship_to_user': 'fragile alliance',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1');
      expect(compiled, isNotNull);
      expect(compiled, contains('override character-card baseline'));
    });

    test('npc entity appears with its field', () {
      final trackers = _makeTrackers('s1', {
        'npc:Lucyna Kushinada.relationship_to_user': 'fragile alliance',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('Lucyna Kushinada'));
      expect(compiled, contains('fragile alliance'));
    });

    test('canon_override:* value overwrites ledger value in output', () {
      final trackers = _makeTrackers('s1', {
        'npc:Lucy.mood': 'neutral',
        'canon_override:npc:Lucy.mood': 'elated; user edit',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('elated; user edit'));
      expect(compiled, isNot(contains('neutral')));
    });

    test('completed arc is rendered under Resolved arcs', () {
      final trackers = _makeTrackers('s1', {
        'arc:david_fate.status': 'completed',
        'arc:david_fate.title': "David's fate revelation",
        'arc:david_fate.summary': "Danvi knows Lucy's role.",
        'arc:david_fate.do_not_reopen': 'true',
        'arc:david_fate.card_override': 'Treat as backstory.',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('Resolved arcs'));
      expect(compiled, contains("David's fate revelation"));
      expect(compiled, contains('Do not reopen as active conflict.'));
    });

    test('scene fields appear under Scene section', () {
      final trackers = _makeTrackers('s1', {
        'scene.present_entities': 'Lucyna Kushinada',
        'scene.location': 'Watson streets',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('Scene'));
      expect(compiled, contains('Lucyna Kushinada'));
    });

    test('mention filter injects mentioned entity and omits unrelated NPC', () {
      final trackers = _makeTrackers('s1', {
        'npc:Lucy.relationship_to_user': 'fragile alliance',
        'npc:Rebecca.relationship_to_user': 'not in scene',
        'world:location': 'Watson streets',
      });
      final compiled = kCompileStudioSessionStateForTest(
        trackers,
        's1',
        latestUserText: 'Lucy looks back at Danvi.',
      )!;
      expect(compiled, contains('Lucy'));
      expect(compiled, contains('fragile alliance'));
      expect(compiled, isNot(contains('Rebecca')));
      // World state remains injected even when NPC rows are filtered.
      expect(compiled, contains('Watson streets'));
    });

    test('present and absent entities render explicit presence rules', () {
      final trackers = _makeTrackers('s1', {
        'scene.present_entities': 'Lucyna Kushinada',
        'scene.absent_backstory_entities': 'David Martinez',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('Present now'));
      expect(compiled, contains('Lucyna Kushinada'));
      expect(compiled, contains('Absent/backstory only'));
      expect(compiled, contains('David Martinez'));
      expect(compiled, contains('Do not give dialogue or physical actions'));
    });

    test('dedupes duplicate canon lines inside studio state block', () {
      final trackers = _makeTrackers('s1', {
        'npc:Lucy.a': 'same fact',
        'npc:Lucy.b': 'same fact',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect('same fact'.allMatches(compiled).length, 1);
    });

    test('returns null when all values are empty', () {
      final trackers = _makeTrackers('s1', {'npc:Lucy.mood': ''});
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1');
      expect(compiled, isNull);
    });

    test('returns null when trackers list is empty', () {
      final compiled = kCompileStudioSessionStateForTest([], 's1');
      expect(compiled, isNull);
    });

    test('world state appears under World section', () {
      final trackers = _makeTrackers('s1', {
        'world:calendar_system': 'Neo-calendar 2077',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('World'));
      expect(compiled, contains('Neo-calendar 2077'));
    });

    test('budget cap preserves XML close tag and trims by complete lines', () {
      final trackers = _makeTrackers('s1', {
        for (var i = 0; i < 220; i++)
          'world:fact_$i': 'long canon fact ${'x' * 80} $i',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled.length, lessThanOrEqualTo(6000));
      expect(compiled, endsWith('</studio_session_state>'));
      expect(compiled, contains('[trimmed lower-priority canon details]'));
    });

    test('relationship pair appears in Relationships section', () {
      final trackers = _makeTrackers('s1', {
        'relationship:Danvi:Lucy.attitude': 'wary admiration',
      });
      final compiled = kCompileStudioSessionStateForTest(trackers, 's1')!;
      expect(compiled, contains('Relationships'));
      expect(compiled, contains('wary admiration'));
    });
  });

  // ── Ledger failure isolation ───────────────────────────────────────────────
  group('Ledger failure isolation', () {
    test('malformed export does not throw; returns null gracefully', () {
      expect(() => parser.parse('garbage \$\$\$'), returnsNormally);
      final r = parser.parse('garbage \$\$\$');
      expect(r.export, isNull);
    });

    test('valid JSON with only sceneState (no ops) returns null export', () {
      const noOps = '''
<glaze_memory_export>
{
  "ops": [],
  "sceneState": {"time": "12:00", "date": "01-01-2077",
    "location": "bar", "immediateThread": "idle",
    "presentEntities": [], "activeTensions": []}
}
</glaze_memory_export>
''';
      final r = parser.parse(noOps);
      expect(r.export, isNull);
    });
  });
}

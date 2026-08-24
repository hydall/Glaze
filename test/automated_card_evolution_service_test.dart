import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() => fixture.db.close());

  test('empty chat history makes zero executor calls', () async {
    await fixture.db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[]' WHERE session_id = 'session'",
    );
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'notEligible');
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('disabled automation makes zero claim or executor calls', () async {
    var calls = 0;
    final service = AutomatedCardEvolutionService(
      repo: fixture.repo,
      resolveModel: () async => throw StateError('must not resolve'),
      isEnabled: () => false,
      executor:
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
          }) async {
            calls++;
            return _ok(fixture.cardBatchOutput);
          },
    );

    expect((await service.runOneBatch('session')).kind, 'disabled');
    expect(calls, 0);
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('successful output persists a pending proposal', () async {
    var calls = 0;
    final result = await fixture
        .service((token, prompt) async {
          calls++;
          expect(token, isNotNull);
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'persisted');
    expect(calls, 1);
    expect(
      (await fixture.db.select(fixture.db.rewriteJobs).getSingle()).status,
      'pending',
    );
    expect(
      await fixture.db.select(fixture.db.cardEvolutionProposalRuns).get(),
      hasLength(1),
    );
    final claim = await fixture.db
        .select(fixture.db.cardEvolutionClaims)
        .getSingle();
    expect(claim.leaseExpiresAt - claim.createdAt, 600);
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(1));
    expect(
      operations
          .map(
            (operation) =>
                jsonDecode(operation.operationJson)['field'] as String,
          )
          .toSet(),
      {CardRewriteField.description.wireName},
    );
    await fixture.expectCanonRowsUnchanged();
  });

  test('model failure leaves no proposal', () async {
    final result = await fixture
        .service(
          (_, _) async => const AuxCallOutcome(
            status: AgentOperationStatus.httpError,
            attempts: [
              AgentOperationAttempt(
                attempt: 1,
                statusCode: 503,
                status: 'http_5xx',
                error: 'upstream unavailable',
                startedAtMs: 1,
                elapsedMs: 2,
              ),
            ],
          ),
        )
        .runOneBatch('session');
    expect(result.kind, 'cardModelFailed');
    expect(
      result.detail,
      '1 attempt(s), http_5xx HTTP 503: upstream unavailable',
    );
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .getSingle();
    expect(debug.stage, 'card');
    expect(debug.status, 'httpError');
    expect(debug.output, isNull);
    expect(debug.attemptsJson, contains('upstream unavailable'));
    await fixture.expectNoProposalOrCanonWrites();
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
  });

  test('malformed parser output gets exactly one repair attempt', () async {
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok('not json');
        })
        .runOneBatch('session');
    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionDebugRuns).getSingle())
          .output,
      'not json',
    );
    await fixture.expectNoProposalOrCanonWrites();
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
  });

  test('malformed JSON can recover on the single repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(calls == 1 ? '{"operations":[' : fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('no JSON object was found'));
    expect(prompts.last, contains('exactly one valid JSON object'));
  });

  test('expired claim does not start a repair call', () async {
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          await fixture.db.customStatement(
            "UPDATE card_evolution_claims SET lease_expires_at = 0 WHERE session_id = 'session'",
          );
          return _ok('not json');
        })
        .runOneBatch('session');

    expect(result.kind, 'leaseLost');
    expect(calls, 1);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('invalid scope gets one constrained repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    ((operation['patches'] as List).single as Map)['scopeKey'] =
        'relationship:alice';
    (operation['transition'] as Map)['scopeKey'] = 'relationship:alice';

    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(
            calls == 1 ? jsonEncode(invalid) : fixture.cardBatchOutput,
          );
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('# Required correction'));
    expect(prompts.last, contains('unparsable patch scopeKey'));
    expect(
      (await fixture.db.select(fixture.db.cardEvolutionDebugRuns).getSingle())
          .output,
      fixture.cardBatchOutput,
    );
  });

  test('invalid scope is rejected after exactly one repair attempt', () async {
    var calls = 0;
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    ((operation['patches'] as List).single as Map)['scopeKey'] =
        'relationship:alice';
    (operation['transition'] as Map)['scopeKey'] = 'relationship:alice';

    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(jsonEncode(invalid));
        })
        .runOneBatch('session');

    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('changed macro tokens get one constrained repair attempt', () async {
    var calls = 0;
    final prompts = <String>[];
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    final patch = (operation['patches'] as List).single as Map;
    patch['value'] = '${patch['value']} {{user}}';

    final result = await fixture
        .service((_, prompt) async {
          calls++;
          prompts.add(prompt);
          return _ok(
            calls == 1 ? jsonEncode(invalid) : fixture.cardBatchOutput,
          );
        })
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 2);
    expect(prompts.last, contains('# Required correction'));
    expect(prompts.last, contains('macro-token multiset'));
    expect(prompts.last, contains('Never add, remove, rename'));
  });

  test('changed macro tokens are rejected after one repair attempt', () async {
    var calls = 0;
    final invalid = jsonDecode(fixture.cardBatchOutput) as Map<String, dynamic>;
    final operation = (invalid['operations'] as List).single as Map;
    final patch = (operation['patches'] as List).single as Map;
    patch['value'] = '${patch['value']} {{user}}';

    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(jsonEncode(invalid));
        })
        .runOneBatch('session');

    expect(result.kind, 'invalidCardOutput');
    expect(calls, 2);
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('cancellation reaches dedicated token and leaves no proposal', () async {
    final started = Completer<CancelToken>();
    final release = Completer<AuxCallOutcome>();
    final service = fixture.service((token, _) {
      started.complete(token!);
      return release.future;
    });
    final future = service.runOneBatch('session');
    final token = await started.future;
    service.cancelSession('session');
    expect(token.isCancelled, isTrue);
    release.complete(
      const AuxCallOutcome(status: AgentOperationStatus.aborted),
    );
    expect((await future).kind, 'cancelled');
    await fixture.expectNoProposalOrCanonWrites();
    expect(
      await fixture.db.select(fixture.db.cardEvolutionClaims).get(),
      isEmpty,
    );
  });

  test('canon changes after generation block proposal', () async {
    var changedCanon = false;
    final result = await fixture
        .service((_, prompt) async {
          if (!changedCanon) {
            changedCanon = true;
            await fixture.db.customStatement(
              "INSERT INTO tracker_rows (session_id, name, value, scope, provenance, updated_at) VALUES ('session', 'canon_lock:npc:alice', 'locked', 'ledger', 'manual', 2)",
            );
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');
    expect(result.kind, 'staleEvidence');
    await fixture.expectNoProposalOrCanonWrites();
  });

  test('injected lorebook entries use a separate second call', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    var calls = 0;
    String? lorebookPrompt;
    final result = await fixture
        .service((_, prompt) async {
          calls++;
          if (prompt.contains('Glaze lorebook rewriter')) {
            lorebookPrompt = prompt;
            return _ok(fixture.lorebookBatchOutput);
          }
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(calls, 2);
    expect(result.kind, 'persisted');
    expect(lorebookPrompt, contains('"description":"Alice is cautious."'));
    expect(lorebookPrompt, contains('# Proposed card operations (read-only)'));
    expect(lorebookPrompt, contains('increasingly trusting'));
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(2));
    expect(
      operations.map(
        (operation) => jsonDecode(operation.operationJson)['target'],
      ),
      contains('lorebook'),
    );
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .get();
    expect(debug.map((row) => row.stage), containsAll(['card', 'lorebook']));
  });

  test('accepts injected lorebook entries up to 60000 characters', () async {
    final content = List.filled(59999, 'x').join();
    await _seedManifest(fixture.db, 'a2', content);
    String? lorebookPrompt;
    final service = fixture.service((token, prompt) async {
      if (prompt.contains('Glaze lorebook rewriter')) {
        lorebookPrompt = prompt;
        return _ok(fixture.lorebookBatchOutput);
      }
      return _ok(fixture.cardBatchOutput);
    });

    await service.runOneBatch('session');

    expect(lorebookPrompt, isNotNull);
    expect(lorebookPrompt, contains(content));
  });

  test('uses the configured writer idle timeout', () async {
    int? receivedTimeout;
    final result = await fixture
        .service(
          (_, _) async => _ok(fixture.cardBatchOutput),
          timeoutMs: 180000,
          onTimeout: (timeoutMs) => receivedTimeout = timeoutMs,
        )
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(receivedTimeout, 180000);
  });

  test('uses a 40k response budget for each writer call', () async {
    int? receivedMaxTokens;
    final result = await fixture
        .service(
          (_, _) async => _ok(fixture.cardBatchOutput),
          onMaxTokens: (maxTokens) => receivedMaxTokens = maxTokens,
        )
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(receivedMaxTokens, 40000);
  });

  test('disabled lorebook evolution skips its second model call', () async {
    await _seedManifest(fixture.db, 'a1', 'entry one');
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        }, isLorebookEvolutionEnabled: () => false)
        .runOneBatch('session');

    expect(result.kind, 'persisted');
    expect(calls, 1);
    final operations = await fixture.db
        .select(fixture.db.rewriteOperations)
        .get();
    expect(operations, hasLength(1));
    final debug = await fixture.db
        .select(fixture.db.cardEvolutionDebugRuns)
        .get();
    expect(debug.map((row) => row.stage), ['card']);
  });

  test('empty card field is excluded from evolution operations', () async {
    await fixture.db.customStatement(
      "UPDATE characters SET description = '' WHERE char_id = 'character'",
    );
    var calls = 0;
    final result = await fixture
        .service((_, _) async {
          calls++;
          return _ok(fixture.cardBatchOutput);
        })
        .runOneBatch('session');

    expect(result.kind, 'emptyModelProposal');
    expect(calls, 0);
    await fixture.expectNoProposalOrCanonWrites();
  });
}

typedef _Executor =
    Future<AuxCallOutcome> Function(CancelToken? token, String prompt);

final class _Fixture {
  _Fixture(this.db, this.repo, this.revisionCount);

  final AppDatabase db;
  final CardEvolutionRepo repo;
  final int revisionCount;

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final revisions = CharacterRevisionRepo(db);
    const character = Character(
      id: 'character',
      name: 'Card',
      description: 'Alice is cautious.',
    );
    await characters.put(character);
    final hash = CardCanonicalizer.sha256(character);
    await revisions.insert(
      CharacterRevisionRecord(
        characterId: 'character',
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: jsonEncode(character.toJson()),
        createdAt: 1,
      ),
    );
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES (?, ?, 0, ?)',
      ['session', 'character', jsonEncode(_messages)],
    );
    final reader = EffectiveCanonReadRepository(
      db: db,
      characterRepo: characters,
      revisionRepo: revisions,
      baselineRepo: CharacterSessionBaselineRepo(db),
      factRepo: CharacterKnowledgeFactRepo(db),
      transitionRepo: AppliedCanonTransitionRepo(db),
      transitionFactRefRepo: CanonTransitionFactRefRepo(db),
    );
    final jobs = ManualRewriteJobRepo(
      db: db,
      rawTrackerStateReader: LedgerRawTrackerStateReader(db),
    );
    final repo = CardEvolutionRepo(db: db, canonReader: reader, jobRepo: jobs);
    return _Fixture(db, repo, 1);
  }

  String get cardBatchOutput => jsonEncode({
    'operations': [
      {
        'field': CardRewriteField.description.wireName,
        'patches': [
          {
            'scopeKey': 'npc:alice',
            'anchor': 'Alice is cautious.',
            'anchorSha256': CardCanonicalizer.scalarSha256(
              'Alice is cautious.',
            ),
            'value': 'Alice is increasingly trusting.',
          },
        ],
        'transition': {
          'id': 'transition',
          'scopeKey': 'npc:alice',
          'canonicalClaim': 'Alice is increasingly trusting.',
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      },
    ],
  });

  String get lorebookBatchOutput => jsonEncode({
    'operations': [
      {
        'lorebookId': 'book-a1',
        'entryId': 'entry-a1',
        'baseContent': 'entry one',
        'expectedContentHash': CardCanonicalizer.scalarSha256('entry one'),
        'patches': [
          {
            'anchor': 'entry one',
            'anchorSha256': CardCanonicalizer.scalarSha256('entry one'),
            'value': 'entry one updated',
          },
        ],
      },
    ],
  });

  AutomatedCardEvolutionService service(
    _Executor executor, {
    bool Function()? isLorebookEvolutionEnabled,
    int timeoutMs = 180000,
    void Function(int timeoutMs)? onTimeout,
    void Function(int maxTokens)? onMaxTokens,
  }) => AutomatedCardEvolutionService(
    repo: repo,
    resolveModel: () async => const AuxApiConfig(
      endpoint: 'https://rewrite.example',
      apiKey: 'key',
      model: 'model',
      protocol: 'openai',
    ),
    executor:
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) {
          onTimeout?.call(timeoutMs);
          onMaxTokens?.call(maxTokens);
          return executor(cancelToken, prompt);
        },
    isLorebookEvolutionEnabled: isLorebookEvolutionEnabled,
    timeoutMs: timeoutMs,
  );

  Future<void> expectNoProposalOrCanonWrites() async {
    expect(await db.select(db.rewriteJobs).get(), isEmpty);
    expect(await db.select(db.cardEvolutionProposalRuns).get(), isEmpty);
    await expectCanonRowsUnchanged();
  }

  Future<void> expectCanonRowsUnchanged() async {
    expect(
      await db.select(db.characterRevisionRows).get(),
      hasLength(revisionCount),
    );
    expect(await db.select(db.characterSessionBaselineRows).get(), isEmpty);
  }
}

const _messages = [
  {'id': 'a1', 'role': 'assistant', 'content': 'assistant 1'},
  {'id': 'u1', 'role': 'user', 'content': 'user 1'},
  {'id': 'a2', 'role': 'assistant', 'content': 'assistant 2'},
  {'id': 'u2', 'role': 'user', 'content': 'user 2'},
];

Future<void> _seedManifest(
  AppDatabase db,
  String messageId,
  String content,
) async {
  final entry = ExactLorebookManifestEntry.fromMergedEntry(
    entry: LorebookEntry(
      id: 'entry-$messageId',
      lorebookId: 'book-$messageId',
      content: content,
      position: 'worldInfoBefore',
    ),
    source: 'keyword',
    classification: 'worldInfoBefore',
    injectionIndex: 0,
    renderedContent: content,
  );
  final manifest = ExactLorebookManifest(
    entries: [entry],
    promptProvenance: const ExactLorebookPromptProvenance(
      characterId: 'character',
      sessionId: 'session',
      presetSnapshotHash: 'preset',
    ),
    providerMessagesHash: 'prompt-$messageId',
  );
  final identity = LorebookUseGenerationIdentity(
    sessionId: 'session',
    messageId: messageId,
    swipeId: 0,
    agentSwipeId: 0,
  );
  final repo = LorebookUseManifestRepo(db);
  await repo.insertGenerationManifest(
    identity: identity,
    manifest: LorebookUseManifestInput(
      manifestJson: manifest.canonicalJson,
      manifestHash: manifest.canonicalHash,
      manifestSchemaVersion: 1,
      finalPromptHash: manifest.providerMessagesHash,
      presetSnapshotHash: manifest.promptProvenance.presetSnapshotHash,
    ),
    createdAt: 1,
    entries: [
      LorebookUseManifestEntryInput(
        lorebookId: entry.lorebookId,
        entryId: entry.entryId,
        entryOrder: 0,
        evidenceJson: jsonEncode(entry.toJson()),
      ),
    ],
  );
}

AuxCallOutcome _ok(String text) =>
    AuxCallOutcome(status: AgentOperationStatus.ok, text: text);

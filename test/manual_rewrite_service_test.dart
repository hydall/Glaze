import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/card_rewrite_slot_resolver.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_session_baseline.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/core/services/card_rewriter/manual_rewrite_service.dart';

void main() {
  late AppDatabase db;
  late CharacterRepo characters;
  late CharacterRevisionRepo revisions;
  late CharacterSessionBaselineRepo baselines;
  late CharacterKnowledgeFactRepo facts;
  late AppliedCanonTransitionRepo transitions;
  late CanonTransitionFactRefRepo refs;
  late ManualRewriteJobRepo jobRepo;
  late EffectiveCanonContextLoader loader;
  late _FakeExecutor executor;

  const character = Character(id: 'c', name: 'Card', description: 'old text');

  /// Builds one valid writer-lane response: a single anchored patch on the
  /// description field plus its global canon transition.
  String validOutput({String anchor = 'old text', String value = 'new text'}) =>
      jsonEncode({
        'field': 'description',
        'patches': [
          {
            'scopeKey': 'npc:alice',
            'anchor': anchor,
            'anchorSha256': CardCanonicalizer.scalarSha256(anchor),
            'value': value,
          },
        ],
        'transition': {
          'id': 'transition-1',
          'scopeKey': 'npc:alice',
          'canonicalClaim': value,
          'promotionDestination': 'card',
          'affectedTrackerKeys': <String>[],
          'factIds': <String>[],
          'chatSessionId': null,
        },
      });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    characters = CharacterRepo(db);
    revisions = CharacterRevisionRepo(db);
    baselines = CharacterSessionBaselineRepo(db);
    facts = CharacterKnowledgeFactRepo(db);
    transitions = AppliedCanonTransitionRepo(db);
    refs = CanonTransitionFactRefRepo(db);
    final rawReader = LedgerRawTrackerStateReader(db);
    jobRepo = ManualRewriteJobRepo(db: db, rawTrackerStateReader: rawReader);
    loader = EffectiveCanonContextLoader(
      db: db,
      characterRepo: characters,
      characterRevisionRepo: revisions,
      baselineRepo: baselines,
      factRepo: facts,
      transitionRepo: transitions,
      transitionFactRefRepo: refs,
      loadRawTrackerState: rawReader.read,
    );
    executor = _FakeExecutor(defaultText: validOutput());
    await characters.put(character);
  });
  tearDown(() => db.close());

  ManualRewriteService service({
    CardRewriteModelResolver? modelResolver,
    Future<void> Function(int verifyAttempt)? verifyStampRaceHook,
    Future<void> Function()? beforePersistHook,
  }) => ManualRewriteService(
    db: db,
    jobRepo: jobRepo,
    characterRepo: characters,
    canonLoader: loader,
    resolveModel:
        modelResolver ??
        () async => const AuxApiConfig(
          endpoint: 'https://rewrite.example',
          apiKey: 'rewrite-key',
          model: 'rewrite-model',
          protocol: 'openai',
        ),
    executor: executor.call,
    verifyStampRaceHook: verifyStampRaceHook,
    beforePersistHook: beforePersistHook,
  );

  Future<RewriteJobRow> job(String id) =>
      (db.select(db.rewriteJobs)..where((t) => t.id.equals(id))).getSingle();

  test(
    'happy path: generating → pending with stamped basis and one op',
    () async {
      final result = await service().run(
        requestKey: 'rk-happy',
        chatSessionId: 's',
        characterId: 'c',
        field: CardRewriteField.description,
        instruction: 'Make it crisper',
      );

      // Job settled to pending; exactly one transport call happened.
      expect(result.status, 'pending');
      expect(result.version, 2);
      expect(executor.calls, 1);

      // Prompt content sanity: target field, budgets, the literal instruction,
      // and the canonical card snapshot containing the current field text.
      final prompt = executor.lastPrompt!;
      expect(prompt, contains('# Target field'));
      expect(prompt, contains('- field: description'));
      expect(prompt, contains('Make it crisper'));
      expect(prompt, contains('# Canonical character card snapshot'));
      expect(prompt, contains('old text'));
      expect(executor.lastConfig?.model, 'rewrite-model');
      expect(executor.lastCancelToken?.isCancelled, isFalse);
      expect(executor.lastCaptureContext?.stage, 'card.manual_writer');
      expect(executor.lastCaptureContext?.sessionId, 's');
      expect(executor.lastCaptureContext?.pipelineRunId, result.id);
      expect(executor.lastCaptureContext?.logicalCallId, result.id);

      // Basis revision/hash + canon stamp were written inside the verify txn.
      final row = await job(result.id);
      final context = await loader.load(
        sessionId: 's',
        sourceCharacter: character,
      );
      expect(row.basisRevision, 1);
      expect(row.basisRevisionHash, CardCanonicalizer.sha256(character));
      expect(row.canonStamp, context.stamp.identity);
      expect(row.canonStamp, isNotEmpty);

      // One reviewable operation, revision 1 snapshot, advisory-valid.
      final ops = await db.select(db.rewriteOperations).get();
      expect(ops, hasLength(1));
      final op = ops.single;
      expect(op.rewriteJobId, row.id);
      expect(op.status, 'reviewable');
      expect(op.decision, 'pending');
      expect(op.validationStatus, 'valid');
      expect(op.currentRevision, 1);

      final decoded = ManualRewriteOperationSnapshotCodec.tryDecode(
        jsonDecode(op.operationJson),
      );
      expect(decoded, isNotNull);
      expect(decoded!.field, CardRewriteField.description);
      expect(decoded.patches.single.anchor, 'old text');
      expect(decoded.patches.single.value, 'new text');
      expect(decoded.transition.chatSessionId, isNull);

      final revisionRows = await db.select(db.rewriteOperationRevisions).get();
      expect(revisionRows, hasLength(1));
      expect(revisionRows.single.snapshotJson, op.operationJson);

      // HARD: the writer lane never writes canon rows; the single character
      // revision is the runtime loader's one permitted lineage reconcile, and
      // the character itself is untouched.
      expect((await characters.getById('c'))!.description, 'old text');
      final lineage = await revisions.getForCharacter('c');
      expect(lineage, hasLength(1));
      expect(lineage.single.revisionHash, CardCanonicalizer.sha256(character));
      expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
      expect(await db.select(db.canonTransitionFactRefs).get(), isEmpty);
      expect(await db.select(db.characterKnowledgeFactRows).get(), isEmpty);
    },
  );

  test('model not configured fails before any transport call', () async {
    final result =
        await service(
          modelResolver: () async => CardRewriteSlotResolver.resolve(
            apiConfigs: const [
              ApiConfig(
                id: 'active',
                endpoint: 'https://chat.example',
                model: 'm',
              ),
            ],
            // No dedicated rewrite slot configured: nothing to resolve against,
            // and NO silent fallback to the active chat config.
            apiConfigId: '',
          ),
        ).run(
          chatSessionId: 's',
          characterId: 'c',
          field: CardRewriteField.description,
          instruction: 'rewrite',
        );

    expect(result.status, 'failed');
    expect(result.statusReason, ManualRewriteService.reasonModelNotConfigured);
    expect(executor.calls, 0);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
  });

  test('unmatched slot id fails explicitly, never falling back', () async {
    final result =
        await service(
          modelResolver: () async => CardRewriteSlotResolver.resolve(
            apiConfigs: const [
              ApiConfig(
                id: 'active',
                endpoint: 'https://chat.example',
                model: 'm',
              ),
            ],
            apiConfigId: 'rewrite',
          ),
        ).run(
          chatSessionId: 's',
          characterId: 'c',
          field: CardRewriteField.description,
          instruction: 'rewrite',
        );

    expect(result.status, 'failed');
    expect(result.statusReason, ManualRewriteService.reasonModelNotConfigured);
    expect(executor.calls, 0);
  });

  test(
    'baseline decision requirement fails before any transport call',
    () async {
      // Two revisions: baseline pins/at rev1, source has moved to rev2 under
      // the ask-on-change policy.
      await loader.load(sessionId: 's', sourceCharacter: character);
      final edited = character.copyWith(description: 'second draft');
      await characters.put(edited);
      await loader.load(sessionId: 's', sourceCharacter: edited);
      await baselines.ensureBaseline(
        CharacterSessionBaseline(
          chatSessionId: 's',
          characterId: 'c',
          baselineCardJson: jsonEncode(character.toJson()),
          baselineHash: CardCanonicalizer.sha256(character),
          sourceHashLastSeen: CardCanonicalizer.sha256(character),
          cardUpdatePolicy: CharacterCardUpdatePolicy.askOnChange,
        ),
      );

      final result = await service().run(
        chatSessionId: 's',
        characterId: 'c',
        field: CardRewriteField.description,
        instruction: 'rewrite',
      );

      expect(result.status, 'failed');
      expect(
        result.statusReason,
        ManualRewriteService.reasonBaselineDecisionRequired,
      );
      expect(executor.calls, 0);
      expect(await db.select(db.rewriteOperations).get(), isEmpty);
    },
  );

  test(
    'canon moved between load and stamp rebinds once and succeeds',
    () async {
      var moved = false;
      final svc = service(
        verifyStampRaceHook: (verifyAttempt) async {
          if (moved) return;
          moved = true;
          final edited = character.copyWith(description: 'moved text');
          await characters.put(edited);
          // Reconciling through the runtime loader is what a concurrent
          // canon write path does; the verify stamp must reject the old
          // identity and the retry must re-load the new lineage.
          await loader.load(sessionId: 's', sourceCharacter: edited);
        },
      );
      executor.impl =
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
          }) async => okOutcome(validOutput(anchor: 'moved text'));

      final result = await svc.run(
        chatSessionId: 's',
        characterId: 'c',
        field: CardRewriteField.description,
        instruction: 'rewrite',
      );

      expect(result.status, 'pending');
      expect(executor.calls, 1);
      // The prompt was rebuilt from the rebound canon, not the stale load.
      expect(executor.lastPrompt, contains('moved text'));
      expect(executor.lastPrompt, isNot(contains('old text')));
      final row = await job(result.id);
      expect(row.basisRevision, 2);
      final op = (await db.select(db.rewriteOperations).get()).single;
      expect(op.validationStatus, 'valid');
      expect(
        ManualRewriteOperationSnapshotCodec.tryDecode(
          jsonDecode(op.operationJson),
        )!.patches.single.value,
        'new text',
      );
    },
  );

  test('canon moving on every verify attempt fails canonMoved', () async {
    var attempt = 0;
    final svc = service(
      verifyStampRaceHook: (verifyAttempt) async {
        final edited = character.copyWith(
          description: 'moved ${attempt++} ($verifyAttempt)',
        );
        await characters.put(edited);
        await loader.load(sessionId: 's', sourceCharacter: edited);
      },
    );

    final result = await svc.run(
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );

    expect(result.status, 'failed');
    expect(result.statusReason, ManualRewriteService.reasonCanonMoved);
    expect(executor.calls, 0);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    // Both verify attempts happened (one original + one rebound).
    expect(attempt, 2);
  });

  test('cancel before dispatch lands cancelled with zero transport', () async {
    final created = await jobRepo.createOrGet(
      requestKey: 'rk-pre-cancel',
      chatSessionId: 's',
      characterId: 'c',
      requestJson: '{}',
    );
    expect(created.kind, 'created');

    final svc = service();
    final cancelled = await svc.cancelJob(created.job.id);
    expect(cancelled?.status, 'cancelled');
    expect(cancelled?.statusReason, 'userCancelled');

    final result = await svc.run(
      requestKey: 'rk-pre-cancel',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );

    // The keyed cancelled job is returned as-is; no generation is restarted.
    expect(result.id, created.job.id);
    expect(result.status, 'cancelled');
    expect(executor.calls, 0);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
  });

  test('cancel mid-flight is a terminal win with zero operations', () async {
    final created = await jobRepo.createOrGet(
      requestKey: 'rk-mid-cancel',
      chatSessionId: 's',
      characterId: 'c',
      requestJson: '{}',
    );
    expect(created.kind, 'created');

    final started = Completer<void>();
    final release = Completer<void>();
    executor.impl =
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) async {
          started.complete();
          await release.future;
          if (cancelToken?.isCancelled == true) {
            return const AuxCallOutcome(
              status: AgentOperationStatus.aborted,
              attempts: [
                AgentOperationAttempt(
                  attempt: 1,
                  statusCode: 0,
                  status: 'cancelled',
                  error: 'cancelled',
                  startedAtMs: 0,
                  elapsedMs: 1,
                ),
              ],
              totalElapsedMs: 1,
            );
          }
          return okOutcome(validOutput());
        };

    final svc = service();
    final future = svc.run(
      requestKey: 'rk-mid-cancel',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );
    await started.future;

    final cancelled = await svc.cancelJob(created.job.id);
    expect(cancelled?.status, 'cancelled');
    expect(cancelled?.statusReason, 'userCancelled');
    release.complete();

    final result = await future;
    // The user's cancel transition landed; the run respects it and persists
    // nothing.
    expect(result.id, created.job.id);
    expect(result.status, 'cancelled');
    expect(result.statusReason, 'userCancelled');
    expect(executor.calls, 1);
    expect(executor.lastCancelToken?.isCancelled, isTrue);
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
    expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
    expect(await db.select(db.rewriteEvidenceRows).get(), isEmpty);
    // No cancellation-related provenance writes either.
    expect(await db.select(db.appliedCanonTransitionRows).get(), isEmpty);
    expect((await characters.getById('c'))!.description, 'old text');
  });

  test(
    'malformed LLM output fails invalidOutput with zero operations',
    () async {
      executor.impl =
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
          }) async => okOutcome('Sorry, I cannot rewrite that.');

      final result = await service().run(
        chatSessionId: 's',
        characterId: 'c',
        field: CardRewriteField.description,
        instruction: 'rewrite',
      );

      expect(result.status, 'failed');
      expect(result.statusReason, startsWith('invalidOutput'));
      expect(result.statusReason, contains('noJsonPayload'));
      expect(await db.select(db.rewriteOperations).get(), isEmpty);
    },
  );

  test(
    'empty patch list is invalidOutput, never a zero-op pending job',
    () async {
      executor.impl =
          ({
            required config,
            required prompt,
            required maxTokens,
            required temperature,
            required timeoutMs,
            cancelToken,
          }) async => okOutcome(
            jsonEncode({
              'field': 'description',
              'patches': <Object?>[],
              'transition': {
                'id': 'transition-1',
                'scopeKey': 'npc:alice',
                'canonicalClaim': 'noop',
                'promotionDestination': 'card',
                'affectedTrackerKeys': <String>[],
                'factIds': <String>[],
                'chatSessionId': null,
              },
            }),
          );

      final result = await service().run(
        chatSessionId: 's',
        characterId: 'c',
        field: CardRewriteField.description,
        instruction: 'rewrite',
      );

      expect(result.status, 'failed');
      expect(result.statusReason, startsWith('invalidOutput'));
      expect(result.statusReason, contains('emptyPatches'));
      expect(await db.select(db.rewriteOperations).get(), isEmpty);
    },
  );

  test(
    'mutation between call and persist fails staleCanon with zero ops',
    () async {
      // The card is edited (but NOT reconciled) after the transport call
      // returns and before the freshness gate runs.
      final result =
          await service(
            beforePersistHook: () async {
              await characters.put(
                character.copyWith(description: 'moved text'),
              );
            },
          ).run(
            chatSessionId: 's',
            characterId: 'c',
            field: CardRewriteField.description,
            instruction: 'rewrite',
          );

      expect(result.status, 'failed');
      expect(result.statusReason, ManualRewriteService.reasonStaleCanon);
      expect(executor.calls, 1);
      expect(await db.select(db.rewriteOperations).get(), isEmpty);
      expect(await db.select(db.rewriteOperationRevisions).get(), isEmpty);
      expect(await revisions.getForCharacter('c'), hasLength(1));
    },
  );

  test('transport timeout maps to a trimmed failed reason', () async {
    executor.impl =
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) async => const AuxCallOutcome(
          status: AgentOperationStatus.timeout,
          attempts: [
            AgentOperationAttempt(
              attempt: 3,
              statusCode: 0,
              status: 'timeout',
              error: 'Aux timed out after retries',
              startedAtMs: 0,
              elapsedMs: 1000,
            ),
          ],
          totalElapsedMs: 1000,
        );

    final result = await service().run(
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );

    expect(result.status, 'failed');
    expect(result.statusReason, startsWith('timeout'));
    expect(result.statusReason, contains('Aux timed out after retries'));
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
  });

  test('HTTP error maps to a trimmed failed reason', () async {
    executor.impl =
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) async => const AuxCallOutcome(
          status: AgentOperationStatus.httpError,
          attempts: [
            AgentOperationAttempt(
              attempt: 1,
              statusCode: 502,
              status: 'http_5xx',
              error: 'Bad Gateway',
              startedAtMs: 0,
              elapsedMs: 10,
            ),
          ],
          totalElapsedMs: 10,
        );

    final result = await service().run(
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );

    expect(result.status, 'failed');
    expect(result.statusReason, startsWith('httpError'));
    expect(await db.select(db.rewriteOperations).get(), isEmpty);
  });

  test('idempotent createOrGet double-run returns the same job', () async {
    final svc = service();
    final first = await svc.run(
      requestKey: 'rk-idem',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );
    expect(first.status, 'pending');

    final second = await svc.run(
      requestKey: 'rk-idem',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'a different instruction',
    );

    expect(second.id, first.id);
    expect(second.status, 'pending');
    // No second transport call, no second operation.
    expect(executor.calls, 1);
    expect(await db.select(db.rewriteOperations).get(), hasLength(1));
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
  });

  test('a new service instance adopts a stranded generating job', () async {
    final created = await jobRepo.createOrGet(
      requestKey: 'rk-restart-adopt',
      chatSessionId: 's',
      characterId: 'c',
      requestJson: jsonEncode({
        'field': CardRewriteField.description.wireName,
        'instruction': 'rewrite after restart',
      }),
    );
    expect(created.job.status, 'generating');

    final result = await service().run(
      requestKey: 'rk-restart-adopt',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite after restart',
    );

    expect(result.id, created.job.id);
    expect(result.status, 'pending');
    expect(executor.calls, 1);
    expect(await db.select(db.rewriteJobs).get(), hasLength(1));
    expect(await db.select(db.rewriteOperations).get(), hasLength(1));
  });

  test('a concurrent in-flight run attaches instead of duplicating', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    executor.impl =
        ({
          required config,
          required prompt,
          required maxTokens,
          required temperature,
          required timeoutMs,
          cancelToken,
        }) async {
          started.complete();
          await release.future;
          return okOutcome(validOutput());
        };

    final svc = service();
    final first = svc.run(
      requestKey: 'rk-attach',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );
    await started.future;
    final second = svc.run(
      requestKey: 'rk-attach',
      chatSessionId: 's',
      characterId: 'c',
      field: CardRewriteField.description,
      instruction: 'rewrite',
    );
    release.complete();

    final firstResult = await first;
    final secondResult = await second;
    expect(secondResult.id, firstResult.id);
    expect(secondResult.status, 'pending');
    expect(executor.calls, 1);
    expect(await db.select(db.rewriteOperations).get(), hasLength(1));
  });

  group('CardRewriteSlotResolver', () {
    const configs = [
      ApiConfig(
        id: 'rewrite-slot',
        endpoint: 'https://rewrite.example',
        apiKey: 'slot-key',
        model: 'slot-model',
        protocol: 'openai',
      ),
      ApiConfig(
        id: 'active-chat',
        endpoint: 'https://chat.example',
        apiKey: 'chat-key',
        model: 'chat-model',
      ),
    ];

    test('resolves the matched slot and applies the model override', () {
      final config = CardRewriteSlotResolver.resolve(
        apiConfigs: configs,
        apiConfigId: 'rewrite-slot',
        modelOverride: 'override-model',
      );
      expect(config.endpoint, 'https://rewrite.example');
      expect(config.apiKey, 'slot-key');
      expect(config.model, 'override-model');
    });

    test('empty or unmatched slot id fails explicit, no chat fallback', () {
      expect(
        () => CardRewriteSlotResolver.resolve(
          apiConfigs: configs,
          apiConfigId: '',
        ),
        throwsA(isA<CardRewriteModelNotConfigured>()),
      );
      expect(
        () => CardRewriteSlotResolver.resolve(
          apiConfigs: configs,
          apiConfigId: 'missing',
        ),
        throwsA(isA<CardRewriteModelNotConfigured>()),
      );
    });
  });
}

/// Builds an ok [AuxCallOutcome] carrying [text].
AuxCallOutcome okOutcome(String text) => AuxCallOutcome(
  status: AgentOperationStatus.ok,
  text: text,
  attempts: const [
    AgentOperationAttempt(
      attempt: 1,
      statusCode: 200,
      status: 'ok',
      startedAtMs: 0,
      elapsedMs: 1,
    ),
  ],
  totalElapsedMs: 1,
);

/// Sits at the service's transport seam (`CardRewriteLlmExecutor`).
class _FakeExecutor {
  _FakeExecutor({required this.defaultText});

  final String defaultText;

  int calls = 0;
  AuxApiConfig? lastConfig;
  String? lastPrompt;
  CancelToken? lastCancelToken;
  LlmCaptureContext? lastCaptureContext;

  Future<AuxCallOutcome> Function({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
  })?
  impl;

  Future<AuxCallOutcome> call({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) {
    calls++;
    lastConfig = config;
    lastPrompt = prompt;
    lastCancelToken = cancelToken;
    lastCaptureContext = captureContext;
    final handler = impl;
    if (handler != null) {
      return handler(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
      );
    }
    return Future.value(okOutcome(defaultText));
  }
}

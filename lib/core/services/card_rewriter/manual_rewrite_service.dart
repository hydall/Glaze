import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/card_rewrite_slot_resolver.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_operation_parser.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewrite_prompt_builder.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/id_generator.dart';
import 'package:glaze_flutter/core/utils/time_helpers.dart';

/// Resolves the dedicated card-rewrite model slot to an [AuxApiConfig].
/// Implementations must be fail-explicit: throw [CardRewriteModelNotConfigured]
/// when the slot is unconfigured. There is NO silent fallback to the active
/// chat config.
typedef CardRewriteModelResolver = Future<AuxApiConfig> Function();

/// The writer-lane transport seam. Production delegates to
/// [AuxLlmClient.callOnceWithLog]; tests fake it at this boundary.
typedef CardRewriteLlmExecutor =
    Future<AuxCallOutcome> Function({
      required AuxApiConfig config,
      required String prompt,
      required int maxTokens,
      required double temperature,
      required int timeoutMs,
      CancelToken? cancelToken,
      LlmCaptureContext? captureContext,
    });

/// Internal verify+stamp outcome kinds for [ManualRewriteService].
typedef _VerifyStampOutcome = ({
  String kind,
  RewriteJobRow? job,
  String? stamp,
  String? message,
});

/// Phase-4B writer lane: manual card-rewrite LLM orchestration.
///
/// Owns the binding flow (see `.slim/deepwork/card-rewriter.md`):
/// 1. `jobRepo.createOrGet` (idempotent; an existing active job is returned /
///    attached, never re-run by a second caller).
/// 2. Runtime [EffectiveCanonContextLoader] load — the ONE place Phase 4 may
///    reconcile source lineage. `requiresBaselineDecision` fails the job with
///    `baselineDecisionRequired` before any transport call.
/// 3. Pure prompt via [CardRewriterPromptBuilder] from the assembled
///    effective character.
/// 4. Transactional verify+stamp: inside ONE Drift transaction, the PRIMARY
///    same-DB [EffectiveCanonReadRepository] (never `.runtime`) plus the pure
///    assembler re-derives the canon identity and compares it with the step-2
///    stamp; a match stamps basis revision/hash + `canon_stamp` onto the job,
///    a mismatch retries step 2 exactly once, then fails `canonMoved`.
/// 5. Dedicated rewrite model resolution via [CardRewriteModelResolver]
///    (fail-explicit; unconfigured fails `rewriteModelNotConfigured`), then a
///    job-scoped [CancelToken] is registered in the service-owned registry.
/// 6. `AuxLlmClient.callOnceWithLog` with explicit limits/timeout. Post-call,
///    BEFORE any persistence: job CAS re-read (still `generating`, version
///    unchanged — a cancel transition is a terminal win) plus the read-only
///    `isStillCurrentReadOnly` freshness check. Stale → `staleCanon`,
///    cancelled → `cancelled` (if the transition landed) / `aborted`.
/// 7. Outcome mapping: ok → strict parse → `persistGenerationResult`; the
///    parser contract rejects empty patch lists (`emptyPatches`), so there is
///    NO valid zero-operation proposal and `markPendingByPersist` is never
///    called. Malformed → `invalidOutput`; timeout/httpError/error → failed
///    with the trimmed status reason. Nothing ever throws past the job
///    boundary without a durable status.
///
/// HARD boundaries: this service never writes characters, character revisions,
/// canon transitions, fact references, facts, or trackers, and never imports
/// `ManualRewriteApplyRepo`. The only source-lineage write is delegated to the
/// runtime loader (step 2), exactly once per attempt.
class ManualRewriteService {
  ManualRewriteService({
    required this.db,
    required this.jobRepo,
    required this.characterRepo,
    required this.canonLoader,
    required this.resolveModel,
    CardRewriteLlmExecutor? executor,
    this.maxTokens = 4096,
    this.temperature = 0.2,
    this.timeoutMs = 60000,
    @visibleForTesting this.verifyStampRaceHook,
    @visibleForTesting this.beforePersistHook,
  }) : _executor = executor ?? _defaultExecutor,
       // Step 4 must use the PRIMARY same-DB read-repository constructor,
       // never `.runtime`. Composing it here from the loader's own
       // repositories makes that structural instead of a wiring convention.
       _canonReader = EffectiveCanonReadRepository(
         db: db,
         characterRepo: canonLoader.characterRepo,
         revisionRepo: canonLoader.characterRevisionRepo,
         baselineRepo: canonLoader.baselineRepo,
         factRepo: canonLoader.factRepo,
         transitionRepo: canonLoader.transitionRepo,
         transitionFactRefRepo: canonLoader.transitionFactRefRepo,
       ) {
    if (!identical(canonLoader.db, db)) {
      throw ArgumentError.value(
        canonLoader,
        'canonLoader',
        'must use the same AppDatabase',
      );
    }
    // Only the loader exposes its database; the job repo's same-DB invariant
    // is enforced by its own constructor against its raw tracker reader.
  }

  static Future<AuxCallOutcome> _defaultExecutor({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) => const AuxLlmClient().callOnceWithLog(
    config: config,
    prompt: prompt,
    maxTokens: maxTokens,
    temperature: temperature,
    timeoutMs: timeoutMs,
    cancelToken: cancelToken,
    captureContext: captureContext,
  );

  final AppDatabase db;
  final ManualRewriteJobRepo jobRepo;
  final CharacterRepo characterRepo;
  final EffectiveCanonContextLoader canonLoader;
  final EffectiveCanonReadRepository _canonReader;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;

  /// Test-only race hooks, isolated from production wiring (provider-based
  /// construction never passes them). Mirrors the apply repo's hooks.
  final Future<void> Function(int verifyAttempt)? verifyStampRaceHook;
  final Future<void> Function()? beforePersistHook;

  /// Writer-lane generation limits. Explicit per the contract; dedicated
  /// rewrite tuning settings are a later (post-4C) phase.
  final int maxTokens;
  final double temperature;
  final int timeoutMs;

  /// Durable failure reasons produced by this service.
  static const reasonBaselineDecisionRequired = 'baselineDecisionRequired';
  static const reasonCanonMoved = 'canonMoved';
  static const reasonModelNotConfigured = 'rewriteModelNotConfigured';
  static const reasonStaleCanon = 'staleCanon';
  static const reasonAborted = 'aborted';
  static const reasonCharacterNotFound = 'characterNotFound';

  /// Job-scoped cancel tokens, keyed by job id; populated only while the
  /// transport call is dispatchable. `cancelJob` aborts through this map.
  final Map<String, CancelToken> _cancelTokens = {};

  /// In-process generation runs keyed by job id, so a second [run] call for
  /// the same active job ATTACHES instead of starting a duplicate LLM call.
  final Map<String, Future<RewriteJobRow>> _inFlight = {};

  /// Runs the manual rewrite writer lane for one field of one character.
  ///
  /// Idempotent by [requestKey]: an existing job with the same key (or a
  /// conflicting active job for the session/character pair) is returned
  /// as-is; an existing still-`generating` job attaches to its in-flight run
  /// (or adopts it after a restart). Returns the final observed job row —
  /// callers never wait on raw transport state, only on durable job state.
  Future<RewriteJobRow> run({
    String? requestKey,
    required String chatSessionId,
    required String characterId,
    required CardRewriteField field,
    required String instruction,
  }) async {
    // 1. Idempotent create-or-get.
    final created = await jobRepo.createOrGet(
      requestKey: requestKey,
      chatSessionId: chatSessionId,
      characterId: characterId,
      requestJson: jsonEncode({
        'field': field.wireName,
        'instruction': instruction,
      }),
    );
    final job = created.job;
    // Another active job owns this session/character pair: return it; the
    // caller reviews or cancels it before starting this request.
    if (created.kind == 'activeJobConflict') return job;
    // Existing terminal/pending job with the same request key: idempotent
    // attach, no second generation.
    if (job.status != 'generating') return job;
    final inFlight = _inFlight[job.id];
    if (inFlight != null) return inFlight;
    final future = _generate(
      job: job,
      chatSessionId: chatSessionId,
      characterId: characterId,
      field: field,
      instruction: instruction,
    );
    _inFlight[job.id] = future;
    try {
      return await future;
    } finally {
      unawaited(_inFlight.remove(job.id));
    }
  }

  /// User cancellation: aborts the in-flight transport call for [jobId] (if
  /// any) AND lands the durable `cancelled` transition via the job repo's
  /// version-CAS, retrying briefly around concurrent version bumps. Returns
  /// the settled job row, or null when the job no longer exists.
  Future<RewriteJobRow?> cancelJob(String jobId) async {
    final token = _cancelTokens[jobId];
    if (token != null && !token.isCancelled) token.cancel('userCancelled');
    for (var round = 0; round < 3; round++) {
      final job = await _readJob(jobId);
      if (job == null) return null;
      if (job.status != 'generating' &&
          job.status != 'pending' &&
          job.status != 'failed') {
        return job; // terminal (or applied) — nothing to cancel.
      }
      final outcome = await jobRepo.cancel(
        jobId: jobId,
        expectedVersion: job.version,
      );
      if (outcome.isUpdated) return outcome.job;
      if (outcome.kind != 'staleVersion') return outcome.job ?? job;
    }
    return _readJob(jobId);
  }

  /// Cancels every in-flight token. Called on provider disposal; durable job
  /// rows stay `generating` and are adopted by the next [run].
  void dispose() {
    for (final token in _cancelTokens.values) {
      if (!token.isCancelled) token.cancel('serviceDisposed');
    }
    _cancelTokens.clear();
    _inFlight.clear();
  }

  Future<RewriteJobRow> _generate({
    required RewriteJobRow job,
    required String chatSessionId,
    required String characterId,
    required CardRewriteField field,
    required String instruction,
  }) async {
    final jobId = job.id;
    final dispatchVersion = job.version;
    CancelToken? cancelToken;
    try {
      // Steps 2–4 with exactly one canon rebound (retry of step 2).
      String? prompt;
      String? canonStamp;
      for (
        var verifyAttempt = 0;
        verifyAttempt < 2 && prompt == null;
        verifyAttempt++
      ) {
        // 2. Runtime loader load — the single Phase-4 lineage reconcile point.
        final source = await characterRepo.getById(characterId);
        if (source == null) {
          return _failDurably(
            jobId,
            dispatchVersion,
            reasonCharacterNotFound,
            job,
          );
        }
        final EffectiveCanonContext context;
        try {
          context = await canonLoader.load(
            sessionId: chatSessionId,
            sourceCharacter: source,
          );
        } on EffectiveCanonContextUnavailable catch (error) {
          return _failDurably(
            jobId,
            dispatchVersion,
            _trimmed('canonUnavailable: ${error.message}'),
            job,
          );
        }
        if (context.requiresBaselineDecision) {
          return _failDurably(
            jobId,
            dispatchVersion,
            reasonBaselineDecisionRequired,
            job,
          );
        }

        // 3. Pure prompt from the ASSEMBLED effective character.
        final candidatePrompt = CardRewriterPromptBuilder.build(
          character: context.character,
          field: field,
          instruction: instruction,
        );

        // 4. Transactional verify+stamp against the step-2 identity.
        await verifyStampRaceHook?.call(verifyAttempt);
        final verify = await _verifyAndStamp(
          jobId: jobId,
          jobVersion: dispatchVersion,
          sessionId: chatSessionId,
          characterId: characterId,
          expectedStampIdentity: context.stamp.identity,
        );
        switch (verify.kind) {
          case 'stamped':
            prompt = candidatePrompt;
            canonStamp = verify.stamp;
          case 'canonMoved' || 'assemblyUnavailable':
            // State moved between load and stamp (or became unreadable):
            // exactly one reload/rebind is permitted; if it also mismatches
            // the loop exits and the job fails canonMoved below.
            continue;
          case 'jobChanged':
            // A concurrent transition (e.g. cancel) won; it is a terminal win.
            return verify.job ?? job;
          default: // 'jobMissing'
            return job; // row deleted mid-run; nothing durable to write.
        }
      }
      if (prompt == null || canonStamp == null) {
        return _failDurably(jobId, dispatchVersion, reasonCanonMoved, job);
      }

      // 5. Dedicated rewrite model resolution — fail explicit, no chat
      // fallback. Unconfigured ⇒ failed('rewriteModelNotConfigured') and NO
      // transport call.
      final AuxApiConfig config;
      try {
        config = await resolveModel();
      } on CardRewriteModelNotConfigured {
        return _failDurably(
          jobId,
          dispatchVersion,
          reasonModelNotConfigured,
          job,
        );
      } catch (error) {
        return _failDurably(
          jobId,
          dispatchVersion,
          _trimmed('modelResolutionFailed: $error'),
          job,
        );
      }

      // Job-scoped cancellation: aborting this token is half of cancelJob;
      // the repo CAS is the other half.
      cancelToken = CancelToken();
      _cancelTokens[jobId] = cancelToken;

      // Pre-dispatch guard: a cancel landing between stamp and dispatch wins
      // without ever touching the transport.
      final preDispatch = await _readJob(jobId);
      if (preDispatch == null) return job;
      if (preDispatch.status != 'generating' ||
          preDispatch.version != dispatchVersion ||
          cancelToken.isCancelled) {
        return _settleCancellation(jobId, dispatchVersion, preDispatch);
      }

      // 6. Transport call via the shared auxiliary client seam.
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
        captureContext: LlmCaptureContext(
          stage: 'card.manual_writer',
          sessionId: chatSessionId,
          pipelineRunId: jobId,
          logicalCallId: jobId,
          relatedArtifactId: jobId,
        ),
      );

      // Post-call, BEFORE any persistence: CAS re-read + freshness check.
      await beforePersistHook?.call();
      final after = await _readJob(jobId);
      if (cancelToken.isCancelled ||
          outcome.status == AgentOperationStatus.aborted ||
          after == null ||
          after.status != 'generating' ||
          after.version != dispatchVersion) {
        if (after == null) return job;
        return _settleCancellation(jobId, dispatchVersion, after);
      }
      final freshSource = await characterRepo.getById(characterId);
      final stillCurrent =
          freshSource != null &&
          await canonLoader.isStillCurrentReadOnly(
            sessionId: chatSessionId,
            sourceCharacter: freshSource,
            stamp: EffectiveCanonContextStamp(canonStamp),
          );
      if (!stillCurrent) {
        return _failDurably(jobId, dispatchVersion, reasonStaleCanon, job);
      }

      // 7. Outcome mapping.
      if (!outcome.isOk || outcome.text == null) {
        return _failDurably(
          jobId,
          dispatchVersion,
          _statusReason(outcome),
          job,
        );
      }
      final parsed = CardRewriteOperationParser.parse(
        outcome.text!,
        expectedField: field,
      );
      final parserContext = outcome.selectedCaptureContext;
      if (parserContext != null) {
        await LlmCallEventCapture.record(
          LlmCallEvent.parserVerdict(
            context: parserContext,
            parserName: 'CardRewriteOperationParser',
            accepted: parsed.snapshot != null,
            code: parsed.rejection?.name ?? 'accepted',
            detail: parsed.detail,
          ),
        );
      }
      final snapshot = parsed.snapshot;
      if (snapshot == null) {
        // The parser rejects empty patch lists (`emptyPatches`), so it never
        // yields a valid zero-operation proposal: markPendingByPersist with
        // zero ops has no trigger here — empty output is invalidOutput.
        final rejection = parsed.rejection?.name ?? 'unknown';
        final detail = parsed.detail;
        return _failDurably(
          jobId,
          dispatchVersion,
          _trimmed(
            'invalidOutput: $rejection${detail == null ? '' : ' ($detail)'}',
          ),
          job,
        );
      }
      final persisted = await jobRepo.persistGenerationResult(
        jobId,
        expectedVersion: dispatchVersion,
        operations: [
          ManualRewriteOperationDraft(
            id: 'rewrite-op-${generateId()}',
            snapshotJson: ManualRewriteOperationSnapshotCodec.encode(snapshot),
          ),
        ],
      );
      if (persisted.isPersisted) return persisted.job!;
      // The repo's CAS interlock discarded the parsed result with zero rows
      // persisted — a concurrent cancel/fail won; report the durable winner.
      return persisted.job ?? await _readJob(jobId) ?? job;
    } catch (error) {
      // Never throw past the job boundary without a durable status.
      return _failDurably(
        jobId,
        dispatchVersion,
        _trimmed('error: $error'),
        job,
      );
    } finally {
      if (cancelToken != null) _cancelTokens.remove(jobId);
    }
  }

  /// Step 4: inside ONE transaction, re-derive the canon identity through the
  /// primary same-DB read repository + assembler, compare with [expectedStampIdentity],
  /// and — on equality — stamp basis revision/hash + `canon_stamp` onto the
  /// still-`generating` job with a version-CAS write.
  Future<_VerifyStampOutcome> _verifyAndStamp({
    required String jobId,
    required int jobVersion,
    required String sessionId,
    required String characterId,
    required String expectedStampIdentity,
  }) => db.transaction(() async {
    final jobs = db.rewriteJobs;
    final job = await (db.select(
      jobs,
    )..where((t) => t.id.equals(jobId))).getSingleOrNull();
    if (job == null) {
      return (kind: 'jobMissing', job: null, stamp: null, message: null);
    }
    if (job.status != 'generating' || job.version != jobVersion) {
      return (kind: 'jobChanged', job: job, stamp: null, message: null);
    }
    final EffectiveCanonAssemblyInput input;
    try {
      input = await _canonReader.readInTransaction(
        sessionId: sessionId,
        characterId: characterId,
      );
    } on StateError catch (error) {
      return (
        kind: 'assemblyUnavailable',
        job: job,
        stamp: null,
        message: error.message,
      );
    }
    final EffectiveCanonAssembly assembly;
    try {
      assembly = const EffectiveCanonAssembler().assemble(input);
    } on EffectiveCanonAssemblyUnavailable catch (error) {
      return (
        kind: 'assemblyUnavailable',
        job: job,
        stamp: null,
        message: error.message,
      );
    }
    if (assembly.identity != expectedStampIdentity) {
      return (kind: 'canonMoved', job: job, stamp: null, message: null);
    }
    final changed =
        await (db.update(jobs)..where(
              (t) =>
                  t.id.equals(jobId) &
                  t.version.equals(jobVersion) &
                  t.status.equals('generating'),
            ))
            .write(
              RewriteJobsCompanion(
                basisRevision: Value(assembly.effectiveRevision.number),
                basisRevisionHash: Value(assembly.effectiveRevision.hash),
                canonStamp: Value(assembly.identity),
                updatedAt: Value(currentTimestampSeconds()),
              ),
            );
    if (changed != 1) {
      final reread = await (db.select(
        jobs,
      )..where((t) => t.id.equals(jobId))).getSingleOrNull();
      return reread == null
          ? (kind: 'jobMissing', job: null, stamp: null, message: null)
          : (kind: 'jobChanged', job: reread, stamp: null, message: null);
    }
    final stamped = await (db.select(
      jobs,
    )..where((t) => t.id.equals(jobId))).getSingle();
    return (
      kind: 'stamped',
      job: stamped,
      stamp: assembly.identity,
      message: null,
    );
  });

  /// Cancellation settle: the user's `cancelled` transition is a terminal win
  /// and is respected as-is; when the abort came without a landed job cancel
  /// (token-only abort), the job moves durably to `failed('aborted')`.
  Future<RewriteJobRow> _settleCancellation(
    String jobId,
    int expectedVersion,
    RewriteJobRow lastKnown,
  ) async {
    var current = await _readJob(jobId);
    for (var round = 0; round < 3; round++) {
      final row = current;
      if (row == null) return lastKnown;
      if (row.status == 'cancelled') return row;
      if (row.status != 'generating') return row; // another lane settled it.
      final failed = await jobRepo.markFailed(
        jobId: jobId,
        expectedVersion: row.version,
        statusReason: reasonAborted,
      );
      if (failed.isUpdated) return failed.job!;
      if (failed.kind != 'staleVersion') return failed.job ?? row;
      current = await _readJob(jobId);
    }
    return current ?? lastKnown;
  }

  /// Durable failure with bounded stale-version retries. A concurrent
  /// `cancelled` transition keeps winning: `markFailed` CASes from
  /// `generating`, so the returned row then reflects the user's cancel.
  Future<RewriteJobRow> _failDurably(
    String jobId,
    int expectedVersion,
    String reason,
    RewriteJobRow lastKnown,
  ) async {
    var outcome = await jobRepo.markFailed(
      jobId: jobId,
      expectedVersion: expectedVersion,
      statusReason: reason,
    );
    for (var round = 0; round < 2 && outcome.kind == 'staleVersion'; round++) {
      final current = await _readJob(jobId);
      if (current == null) return lastKnown;
      outcome = await jobRepo.markFailed(
        jobId: jobId,
        expectedVersion: current.version,
        statusReason: reason,
      );
    }
    return outcome.job ?? await _readJob(jobId) ?? lastKnown;
  }

  Future<RewriteJobRow?> _readJob(String jobId) => (db.select(
    db.rewriteJobs,
  )..where((t) => t.id.equals(jobId))).getSingleOrNull();

  /// Maps a non-ok [AuxCallOutcome] to a trimmed durable status reason.
  static String _statusReason(AuxCallOutcome outcome) {
    final label = outcome.status.name; // timeout | httpError | error | ...
    final AgentOperationAttempt? last = outcome.attempts.isEmpty
        ? null
        : outcome.attempts.last;
    final detail =
        last?.error ??
        (last != null && last.statusCode != 0 ? 'HTTP ${last.statusCode}' : '');
    return _trimmed(detail.isEmpty ? label : '$label: $detail');
  }

  static String _trimmed(String value) {
    final collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= 240
        ? collapsed
        : '${collapsed.substring(0, 240)}…';
  }
}

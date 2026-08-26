import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/ledger_debug_run_repo.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/reconciliation_replacement_repo.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../models/knowledge_cleanup.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../models/studio_ledger_export.dart';
import '../utils/id_generator.dart';
import '../utils/cast_helpers.dart';
import '../utils/time_helpers.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import 'aux_llm_client.dart';
import 'ledger/ledger_canon_authority.dart';
import 'ledger/ledger_in_flight_registry.dart';
import 'ledger/ledger_op_applier.dart';
import 'ledger/ledger_output_recovery.dart';
import 'ledger/ledger_prompt_factory.dart';
import 'ledger/ledger_replacement_basis_resolver.dart';
import 'ledger/ledger_run_diagnostics.dart';
import 'ledger/ledger_run_result.dart';
import 'ledger/ledger_turn_committer.dart';
import 'ledger/ledger_turn_runner.dart';
import 'knowledge_cleanup_parser.dart';
import 'macro_engine.dart';
import 'studio_ledger_export_parser.dart';
import 'studio_ledger_reconciliation.dart';
import 'transport/llm_capture_context.dart';

export 'ledger/ledger_op_applier.dart';
export 'ledger/ledger_run_result.dart';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerService
//
// Runs the Studio Ledger after each final assistant response (after the
// POST-cleaner when enabled). Maintains compact continuity state so long-
// running chats do not reset NPCs to card baseline.
//
// Pipeline placement: after final assistant text is settled —
//   1. Assistant response saved.
//   2. POST-cleaner runs if enabled.
//   3. User auto InfBlocks run if configured.
//   4. Studio Ledger runs on final cleaned text. ← this service
//   5. Visible ledger returned for internal diagnostics.
//   6. Export parsed and validated.
//   7. Entity/relationship/arc/world/scene state written to tracker namespace.
//   8. Snapshot of tracker state saved for rollback/swipe safety.
// Ledger must not run on pre-cleaner text. Manual user InfBlocks do not delay
// canon state writes. User InfBlocks are auxiliary evidence only — the ledger
// can read them but must not promote their contents to canon unless supported
// by the final assistant text, visible accepted chat, or existing canon.
//
// Ledger canon lives in tracker_rows → <studio_session_state>. MemoryBook
// remains a separate, user-controlled long-term range-summary workflow.
//
// Failure behaviour:
//   - Ledger failure MUST NOT fail chat generation.
//   - On export-parse failure, return the visible ledger without writes.
//   - On LLM failure, keep previous ledger. No writes.
//   - Cancelled/aborted: clean up, no writes.
// ─────────────────────────────────────────────────────────────────────────────

/// Studio Ledger service.
///
/// Thin orchestrator:
///   1. Resolve LLM config.
///   2. Build prompt (via [LedgerPromptFactory]).
///   3. Call LLM (via [AuxLlmClient]).
///   4. Parse + validate (via [StudioLedgerExportParser]).
///   5. Apply ops to [TrackerRepo].
///   6. Snapshot tracker state for rollback safety.
///
/// Constructor-injected deps (no `Ref` — all repos/client are injected).
class StudioLedgerService {
  static const _reconciliationLeaseTtlSeconds = 60 * 60;
  final AuxLlmClient _llm;
  final TrackerRepo _trackerRepo;
  final MemoryBookRepo _bookRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;
  final LedgerReconciliationRunRepo _reconciliationRunRepo;
  final LedgerCanonAuthority _canonAuthority;
  final StudioLedgerExportParser _parser;
  final LedgerOpApplier _opApplier;
  final LedgerInFlightRegistry _inFlightRegistry;
  final LedgerOutputRecovery _outputRecovery;
  final LedgerRunDiagnostics _runDiagnostics;
  final LedgerReconciliationLeaseRepo _reconciliationLeaseRepo;
  final ReconciliationReplacementRepo _replacementRepo;
  late final LedgerReplacementBasisResolver _replacementBasisResolver;
  late final LedgerTurnRunner _turnRunner;

  StudioLedgerService({
    required this._llm,
    required this._trackerRepo,
    required this._bookRepo,
    required this._snapshotRepo,
    required this._knowledgeFactRepo,
    required this._reconciliationCheckpointRepo,
    required this._reconciliationRunRepo,
    required CharacterRepo characterRepo,
    required ChatRepo chatRepo,
    required EffectiveCanonContextLoader canonContextLoader,
    LedgerDebugRunRepo? debugRunRepo,
    LedgerReconciliationLeaseRepo? reconciliationLeaseRepo,
    ReconciliationReplacementRepo? replacementRepo,
    LedgerInFlightRegistry? inFlightRegistry,
    LedgerPromptFactory? promptFactory,
    LedgerOutputRecovery? outputRecovery,
    LedgerRunDiagnostics? runDiagnostics,
    LedgerCanonAuthority? canonAuthority,
    LedgerReplacementBasisResolver? replacementBasisResolver,
    LedgerTurnRunner? turnRunner,
  }) : _parser = const StudioLedgerExportParser(),
       _opApplier = const LedgerOpApplier(),
       _inFlightRegistry = inFlightRegistry ?? const LedgerInFlightRegistry(),
       _outputRecovery = outputRecovery ?? const LedgerOutputRecovery(),
       _runDiagnostics =
           runDiagnostics ??
           LedgerRunDiagnostics(
             debugRunRepo ?? LedgerDebugRunRepo(_trackerRepo.db),
           ),
       _reconciliationLeaseRepo =
           reconciliationLeaseRepo ??
           LedgerReconciliationLeaseRepo(_trackerRepo.db),
       _replacementRepo =
           replacementRepo ?? ReconciliationReplacementRepo(_trackerRepo.db),
       _canonAuthority =
           canonAuthority ??
           LedgerCanonAuthority(
             characterRepo: characterRepo,
             chatRepo: chatRepo,
             canonContextLoader: canonContextLoader,
             snapshotRepo: _snapshotRepo,
           ) {
    _replacementBasisResolver =
        replacementBasisResolver ??
        LedgerReplacementBasisResolver(
          reconciliationCheckpointRepo: _reconciliationCheckpointRepo,
          reconciliationRunRepo: _reconciliationRunRepo,
          replacementRepo: _replacementRepo,
          snapshotRepo: _snapshotRepo,
          canonAuthority: _canonAuthority,
        );
    _turnRunner =
        turnRunner ??
        LedgerTurnRunner(
          llm: _llm,
          bookRepo: _bookRepo,
          knowledgeFactRepo: _knowledgeFactRepo,
          canonAuthority: _canonAuthority,
          committer: LedgerTurnCommitter(
            trackerRepo: _trackerRepo,
            snapshotRepo: _snapshotRepo,
            knowledgeFactRepo: _knowledgeFactRepo,
            canonAuthority: _canonAuthority,
          ),
          runDiagnostics: _runDiagnostics,
          promptFactory: promptFactory ?? const LedgerPromptFactory(),
          outputRecovery: _outputRecovery,
        );
  }

  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    String? operationIdentity,
  }) {
    if (operationIdentity == null) {
      return _reconcileUnshared(
        sessionId: sessionId,
        settings: settings,
        config: config,
        plan: plan,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        isStillCurrent: isStillCurrent,
        cancelToken: cancelToken,
        purpose: 'normal',
      );
    }
    final end = plan.endMessage;
    final key = _inFlightRegistry.reconciliationKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      rangeHash: plan.rangeHash,
      endMessageId: end.id,
      endSwipeId: end.swipeId,
      endAgentSwipeId: end.agentSwipeId,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(
      key,
      () => _reconcileUnshared(
        sessionId: sessionId,
        settings: settings,
        config: config,
        plan: plan,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        isStillCurrent: isStillCurrent,
        cancelToken: cancelToken,
        purpose: operationIdentity.startsWith('manual:') ? 'manual' : 'normal',
      ),
    );
  }

  /// Regenerates only the expected current logical reconciliation head.
  /// Generation reads the immutable before-state; replacement writes happen
  /// later in one short transaction after all guards are revalidated.
  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    String? operationIdentity,
  }) {
    final key = _inFlightRegistry.replacementKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      expectedRunId: expectedRunId,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(
      key,
      () => _replaceLatestReconciliationUnshared(
        sessionId: sessionId,
        expectedRunId: expectedRunId,
        settings: settings,
        config: config,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        isStillCurrent: isStillCurrent,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<LedgerRunResult> _replaceLatestReconciliationUnshared({
    required String sessionId,
    required String expectedRunId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required List<StudioPresetBlock> ledgerBlocks,
    required MacroContext? macroCtx,
    required FutureOr<bool> Function()? isStillCurrent,
    required CancelToken? cancelToken,
  }) async {
    final ownerId = 'ledger-reconciliation-${generateId()}';
    if (!await _reconciliationLeaseRepo.acquire(
      sessionId: sessionId,
      ownerId: ownerId,
      purpose: 'replacement',
      ttlSeconds: _reconciliationLeaseTtlSeconds,
    )) {
      return const LedgerRunResult(
        status: 'skipped',
        error: 'Another reconciliation is already running for this session',
      );
    }
    final token = cancelToken ?? CancelToken();
    try {
      final basis = await _replacementBasisResolver.prepare(
        sessionId: sessionId,
        expectedRunId: expectedRunId,
        token: token,
        isStillCurrent: isStillCurrent,
      );
      if (basis is LedgerReplacementBasisFailure) {
        return LedgerRunResult(status: 'error', error: basis.reason);
      }
      final ready = basis as LedgerReplacementBasisReady;
      final trace = LedgerRunTrace(
        sessionId: sessionId,
        kind: LedgerDebugRunKind.reconciliation,
        messageId: ready.plan.endMessage.id,
        swipeId: ready.plan.endMessage.swipeId,
        agentSwipeId: ready.plan.endMessage.agentSwipeId,
      );
      final result = await _reconcileTraced(
        trace: trace,
        sessionId: sessionId,
        settings: settings,
        config: config,
        plan: ready.plan,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        isStillCurrent: isStillCurrent,
        cancelToken: token,
        canonOverride: ready.beforeCanon,
        replacement: ready,
        leaseOwnerId: ownerId,
      );
      if (await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
        sessionId: sessionId,
        ownerId: ownerId,
      )) {
        await _runDiagnostics.recordDebugRun(trace, result);
      }
      return result;
    } finally {
      await _reconciliationLeaseRepo.release(
        sessionId: sessionId,
        ownerId: ownerId,
      );
    }
  }

  Future<LedgerRunResult> _reconcileUnshared({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    required String purpose,
  }) async {
    final ownerId = 'ledger-reconciliation-${generateId()}';
    if (!await _reconciliationLeaseRepo.acquire(
      sessionId: sessionId,
      ownerId: ownerId,
      purpose: purpose,
      ttlSeconds: _reconciliationLeaseTtlSeconds,
    )) {
      return const LedgerRunResult(
        status: 'skipped',
        error: 'Another reconciliation is already running for this session',
      );
    }
    final trace = LedgerRunTrace(
      sessionId: sessionId,
      kind: LedgerDebugRunKind.reconciliation,
      messageId: plan.endMessage.id,
      swipeId: plan.endMessage.swipeId,
      agentSwipeId: plan.endMessage.agentSwipeId,
    );
    try {
      final result = await _reconcileTraced(
        trace: trace,
        sessionId: sessionId,
        settings: settings,
        config: config,
        plan: plan,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        isStillCurrent: isStillCurrent,
        cancelToken: cancelToken,
        leaseOwnerId: ownerId,
      );
      if (await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
        sessionId: sessionId,
        ownerId: ownerId,
      )) {
        await _runDiagnostics.recordDebugRun(trace, result);
      }
      return result;
    } finally {
      await _reconciliationLeaseRepo.release(
        sessionId: sessionId,
        ownerId: ownerId,
      );
    }
  }

  Future<LedgerRunResult> _reconcileTraced({
    required LedgerRunTrace trace,
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    LedgerCanonContext? canonOverride,
    LedgerReplacementBasisReady? replacement,
    required String leaseOwnerId,
  }) async {
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false) {
      return LedgerRunResult.aborted;
    }
    final sw = Stopwatch()..start();
    try {
      final canon = canonOverride ?? await _canonAuthority.load(sessionId);
      await _throwIfReconciliationAborted(token, isStillCurrent);
      final endpointSnapshot = await _snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: plan.endMessage.id,
        swipeId: plan.endMessage.swipeId,
        agentSwipeId: plan.endMessage.agentSwipeId,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      if (endpointSnapshot == null || !endpointSnapshot.committed) {
        return LedgerRunResult(
          status: 'skipped',
          error: 'review endpoint snapshot is not committed',
          elapsedMs: sw.elapsedMilliseconds,
        );
      }

      final promptTrackers = _canonAuthority.projectPromptTrackers(
        canon.context,
      );
      final reviewMessageIds = plan.messageIds.toSet();
      final reviewableFacts = canon.context.resolution.activeFacts;
      final promptFacts = reviewableFacts
          .where((fact) => reviewMessageIds.contains(fact.sourceMessageId))
          .toList();
      final duplicateRetractions = exactDuplicateKnowledgeRetractions(
        reviewableFacts,
      );
      final staleAnchorRetractions = staleKnowledgeAnchorRetractions(
        reviewableFacts,
        plan.messages,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      final promptBlock = ledgerBlocks
          .where(
            (block) =>
                block.id == ledgerReconciliationPromptBlockId &&
                block.enabled &&
                block.injectionPoint == 'ledger' &&
                block.content.trim().isNotEmpty,
          )
          .firstOrNull;
      final systemPrompt = promptBlock == null
          ? fallbackLedgerReconciliationPrompt
          : macroCtx == null
          ? promptBlock.content
          : replaceMacros(promptBlock.content, macroCtx).text;
      const reconciliationPrompt = StudioLedgerReconciliationPrompt();
      final reviewText = plan.messages
          .map((message) => message.content)
          .join('\n');
      final offeredFacts = reconciliationPrompt.relevantKnowledgeFacts(
        promptFacts,
        reviewText,
      );
      final prompt = reconciliationPrompt.build(
        systemPrompt: systemPrompt,
        plan: plan,
        trackers: promptTrackers,
        knowledgeFacts: offeredFacts,
        character: canon.source,
      );
      await _throwIfReconciliationAborted(token, isStillCurrent);
      if (!await _renewReconciliationLease(sessionId, leaseOwnerId)) {
        return LedgerRunResult.aborted;
      }
      final timeoutMs = _llm.resolveLedgerTimeout(settings);
      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: settings.ledger.studioLedgerMaxTokens > 0
            ? settings.ledger.studioLedgerMaxTokens
            : 15000,
        temperature: settings.ledger.studioLedgerTemperature >= 0
            ? settings.ledger.studioLedgerTemperature
            : 0.2,
        timeoutMs: timeoutMs,
        cancelToken: token,
        omitReasoning: true,
        captureContext: LlmCaptureContext(
          stage: 'ledger.reconciliation',
          sessionId: sessionId,
          messageId: plan.endMessage.id,
          pipelineRunId: plan.rangeHash,
          logicalCallId: plan.rangeHash,
          relatedArtifactId: plan.rangeHash,
        ),
      );
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
        sessionId: sessionId,
        canon: canon,
        replacement: replacement,
      )) {
        return LedgerRunResult.aborted;
      }
      if (!outcome.isOk || outcome.text == null || outcome.text!.isEmpty) {
        final attempt = outcome.attempts.lastOrNull;
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation LLM call failed: ${attempt?.status}',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }

      var responseText = outcome.text!;
      var cleanupResponseText = responseText;
      var parsed = _parser.parse(
        responseText,
        focalUserName: macroCtx?.userName ?? '',
      );
      await _runDiagnostics.recordLedgerParserVerdict(outcome, parsed);
      trace.recordFirstResponse(
        model: config.model,
        responseText: responseText,
        parsed: parsed,
      );
      final originalFailure = parsed.failure;
      final originalVisibleLedger = parsed.visibleLedger;
      var attempts = outcome.attempts;
      var repairAttempted = false;
      var totalPromptChars = prompt.length;
      var totalResponseChars = responseText.length;
      const cleanupParser = KnowledgeCleanupParser();
      final needsExportRepair = parsed.failure.isRepairable;
      final needsCleanupRepair =
          (parsed.hasExport ||
              parsed.failure == LedgerParseFailure.emptyExport) &&
          !cleanupParser.hasValidBlock(responseText);
      final needsRepair = needsExportRepair || needsCleanupRepair;
      if (needsRepair) {
        await _throwIfReconciliationAborted(token, isStillCurrent);
        if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
          sessionId: sessionId,
          canon: canon,
          replacement: replacement,
        )) {
          return LedgerRunResult.aborted;
        }
        repairAttempted = true;
        trace.recordRepairRequested(exportRepair: needsExportRepair);
        if (_outputRecovery.isOversizedRepairInput(responseText)) {
          return LedgerRunResult(
            status: 'error',
            visibleLedger: originalVisibleLedger,
            error: 'Ledger output is too large for safe deterministic repair',
            elapsedMs: sw.elapsedMilliseconds,
            attempts: attempts,
            model: config.model,
            effectiveTimeoutMs: timeoutMs,
            promptChars: totalPromptChars,
            responseChars: totalResponseChars,
          );
        }
        final repairPrompt = needsExportRepair
            ? _outputRecovery.buildRepairPrompt(
                responseText,
                reconciliation: true,
              )
            : _outputRecovery.buildCleanupRepairPrompt(responseText);
        totalPromptChars += repairPrompt.length;
        if (!await _renewReconciliationLease(sessionId, leaseOwnerId)) {
          return LedgerRunResult.aborted;
        }
        final repair = await _llm.callOnceWithLog(
          config: config,
          prompt: repairPrompt,
          maxTokens: settings.ledger.studioLedgerMaxTokens > 0
              ? settings.ledger.studioLedgerMaxTokens
              : 15000,
          temperature: 0,
          timeoutMs: timeoutMs,
          cancelToken: token,
          omitReasoning: true,
          captureContext: LlmCaptureContext(
            stage: 'ledger.reconciliation_repair',
            sessionId: sessionId,
            messageId: plan.endMessage.id,
            pipelineRunId: plan.rangeHash,
            logicalCallId: '${plan.rangeHash}:repair',
            relatedArtifactId: plan.rangeHash,
          ),
        );
        attempts = _outputRecovery.combineAttempts(attempts, repair.attempts);
        totalResponseChars += repair.text?.length ?? 0;
        await _throwIfReconciliationAborted(token, isStillCurrent);
        if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
          sessionId: sessionId,
          canon: canon,
          replacement: replacement,
        )) {
          return LedgerRunResult.aborted;
        }
        if (!repair.isOk || repair.text == null || repair.text!.isEmpty) {
          return LedgerRunResult(
            status: 'error',
            error: 'Ledger export repair call failed',
            elapsedMs: sw.elapsedMilliseconds,
            attempts: attempts,
            model: config.model,
            repairAttempted: true,
            effectiveTimeoutMs: timeoutMs,
            promptChars: totalPromptChars,
            responseChars: totalResponseChars,
          );
        }
        if (needsExportRepair) {
          final repairedText = repair.text!;
          final repaired = _parser.parse(
            repairedText,
            focalUserName: macroCtx?.userName ?? '',
          );
          await _runDiagnostics.recordLedgerParserVerdict(repair, repaired);
          trace.recordRepairResponse(
            responseText: repairedText,
            parsed: repaired,
          );
          if (repaired.export != null &&
              !_outputRecovery.repairPreservesStructuredEvidence(
                responseText,
                repaired.export!,
              )) {
            return LedgerRunResult(
              status: 'error',
              visibleLedger: originalVisibleLedger,
              error:
                  'Ledger repair introduced data absent from the original output',
              elapsedMs: sw.elapsedMilliseconds,
              attempts: attempts,
              model: config.model,
              repairAttempted: true,
              effectiveTimeoutMs: timeoutMs,
              promptChars: totalPromptChars,
              responseChars: totalResponseChars,
            );
          }
          responseText = repairedText;
          cleanupResponseText = repairedText;
          parsed = repaired;
          final repairedCleanup = cleanupParser.parse(
            output: cleanupResponseText,
            offeredFacts: offeredFacts,
            reviewText: reviewText,
          );
          if (!_outputRecovery.cleanupRepairPreservesLiteralEvidence(
            outcome.text!,
            repairedCleanup,
          )) {
            return LedgerRunResult(
              status: 'error',
              visibleLedger: originalVisibleLedger,
              error:
                  'Ledger cleanup repair introduced data absent from the original output',
              elapsedMs: sw.elapsedMilliseconds,
              attempts: attempts,
              model: config.model,
              repairAttempted: true,
              effectiveTimeoutMs: timeoutMs,
              promptChars: totalPromptChars,
              responseChars: totalResponseChars,
            );
          }
        } else {
          // The export was already valid. A cleanup-only repair must never
          // replace or reinterpret the authoritative tracker export.
          cleanupResponseText = repair.text!;
          trace.recordRepairResponse(responseText: cleanupResponseText);
          final repairedCleanup = cleanupParser.parse(
            output: cleanupResponseText,
            offeredFacts: offeredFacts,
            reviewText: reviewText,
          );
          if (!_outputRecovery.cleanupRepairPreservesLiteralEvidence(
            responseText,
            repairedCleanup,
          )) {
            return LedgerRunResult(
              status: 'error',
              visibleLedger: originalVisibleLedger,
              error:
                  'Ledger cleanup repair introduced data absent from the original output',
              elapsedMs: sw.elapsedMilliseconds,
              attempts: attempts,
              model: config.model,
              repairAttempted: true,
              effectiveTimeoutMs: timeoutMs,
              promptChars: totalPromptChars,
              responseChars: totalResponseChars,
            );
          }
        }
      }
      final isEmptyExport =
          parsed.rejectionReason == 'empty export (no ops or knowledge facts)';
      if (repairAttempted &&
          originalFailure == LedgerParseFailure.missingExport &&
          parsed.failure == LedgerParseFailure.emptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: originalVisibleLedger,
          error:
              'Repair produced an empty export without explicit empty intent',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: config.model,
          repairAttempted: true,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }
      if (!parsed.hasExport && !isEmptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: originalVisibleLedger.isNotEmpty
              ? originalVisibleLedger
              : parsed.visibleLedger,
          error: parsed.rejectionReason,
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: config.model,
          repairAttempted: repairAttempted,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }
      final export = parsed.export ?? const StudioLedgerExport();
      if (export.knowledgeFacts.isNotEmpty) {
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation must not emit knowledgeFacts',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: config.model,
          repairAttempted: repairAttempted,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!cleanupParser.hasValidBlock(cleanupResponseText)) {
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation returned no valid knowledge cleanup block',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: config.model,
          repairAttempted: repairAttempted,
        );
      }
      final cleanupOps =
          cleanupParser.parse(
              output: cleanupResponseText,
              offeredFacts: offeredFacts,
              reviewText: reviewText,
            )
            ..addAll(duplicateRetractions)
            ..addAll(staleAnchorRetractions);
      final allowedCleanupFactIds = {
        ...offeredFacts.map((fact) => fact.id),
        ...duplicateRetractions.map((op) => op.factId),
        ...staleAnchorRetractions.map((op) => op.factId),
      };
      final anchors = plan.messages
          .map(
            (message) => ReconciliationAnchor(
              messageId: message.id,
              swipeId: message.swipeId,
              agentSwipeId: message.agentSwipeId,
              role: message.role,
              contentHash: computeHash(message.content),
            ),
          )
          .toList(growable: false);
      final canonicalResult = <String, dynamic>{
        'cleanupOps': cleanupOps.map(_cleanupOpJson).toList(growable: false),
        'export': jsonDecode(jsonEncode(export.toJson())),
      };
      final intendedOps = <String>[
        ...export.ops.map((op) => 'tracker:${op.op}:${op.key}'),
        ...cleanupOps.map(_cleanupOpMetadata),
      ];

      var opsApplied = 0;
      var replayed = false;
      await _trackerRepo.db.transaction(() async {
        if (!await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
          sessionId: sessionId,
          ownerId: leaseOwnerId,
        )) {
          throw const LedgerCommitStale();
        }
        if (replacement == null) {
          await _canonAuthority.throwIfCommitStale(
            sessionId: sessionId,
            canon: canon,
            token: token,
            isStillCurrent: isStillCurrent,
            target: LedgerTarget.fromMessage(plan.endMessage),
            requireCommittedSnapshot: true,
          );
        } else {
          await _replacementBasisResolver.throwIfReplacementStale(
            replacement,
            token: token,
            isStillCurrent: isStillCurrent,
          );
        }
        final manifestRefs = await _reconciliationRunRepo
            .readAcceptedManifestRefs(sessionId: sessionId, anchors: anchors);
        final beforeState =
            replacement?.effect.before ??
            await _reconciliationRunRepo.captureState(sessionId);
        final candidate = LedgerReconciliationRun(
          id: '',
          sessionId: sessionId,
          ordinal: 1,
          anchors: anchors,
          acceptedManifestRefs: manifestRefs,
          effectiveCanonStamp: canon.context.stamp.identity,
          effectiveCanonRevision: canon.context.effectiveRevision.number,
          effectiveCanonHash: canon.context.effectiveRevision.hash,
          canonicalResult: canonicalResult,
          predecessorChainHash: '',
          contractVersion: 1,
          opsApplied: intendedOps,
          createdAt: currentTimestampSeconds(),
        );
        // The ID covers immutable candidate content, so a canon change appends
        // rather than colliding with an earlier identical plan/LLM output.
        final draft = LedgerReconciliationRun(
          id: 'reconciliation-${candidate.contentHash}',
          sessionId: candidate.sessionId,
          ordinal: candidate.ordinal,
          anchors: candidate.anchors,
          acceptedManifestRefs: candidate.acceptedManifestRefs,
          effectiveCanonStamp: candidate.effectiveCanonStamp,
          effectiveCanonRevision: candidate.effectiveCanonRevision,
          effectiveCanonHash: candidate.effectiveCanonHash,
          canonicalResult: candidate.canonicalResult,
          predecessorChainHash: candidate.predecessorChainHash,
          contractVersion: candidate.contractVersion,
          opsApplied: candidate.opsApplied,
          createdAt: candidate.createdAt,
        );
        if (replacement != null &&
            draft.manifestsJson != replacement.head.acceptedManifestRefsJson) {
          throw const LedgerCommitStale();
        }
        if (replacement != null &&
            draft.contentHash == replacement.head.contentHash) {
          replayed = true;
          return;
        }
        if (replacement != null) {
          await _replacementRepo.resetDownstreamInTransaction(
            sessionId: sessionId,
            reconciliationRunId: replacement.head.id,
            now: candidate.createdAt,
          );
          final invalidated = await _reconciliationRunRepo
              .invalidateLatestForReplacement(
                sessionId: sessionId,
                expectedRunId: replacement.head.id,
                expectedChainHash: replacement.head.chainHash,
                createdAt: candidate.createdAt,
              );
          if (invalidated is! ReconciliationHeadInvalidated) {
            throw const LedgerCommitStale();
          }
          await _knowledgeFactRepo.deleteCleanupJournalsForExactRange(
            sessionId: sessionId,
            endpointMessageId: plan.endMessage.id,
            messageIds: plan.messageIds,
          );
          await _trackerRepo.restoreLedgerRowsExact(
            sessionId,
            replacement.effect.before.ledgerJson,
          );
          await _knowledgeFactRepo.restoreSessionRowsExact(
            sessionId,
            replacement.effect.before.knowledgeJson,
          );
          if (!await _reconciliationRunRepo.currentStateMatches(
            sessionId,
            replacement.effect.before,
          )) {
            throw StateError(
              'Exact reconciliation before-state was not restored',
            );
          }
        }
        final append = await _reconciliationRunRepo.appendCandidate(draft);
        if (append is ReconciliationRunIdempotent) {
          replayed = true;
          return;
        }
        if (append is! ReconciliationRunAppended) {
          final reason = switch (append) {
            ReconciliationRunMalformed(:final reason) => reason,
            ReconciliationRunChainGap(:final reason) => reason,
            ReconciliationRunConcurrencyConflict(:final reason) => reason,
            ReconciliationRunConflict(:final reason) => reason,
            _ => append.runtimeType.toString(),
          };
          throw StateError('Unable to append reconciliation run: $reason');
        }
        await _trackerRepo.replaceLedgerState(
          sessionId,
          _canonAuthority.stampTrackers(canon, promptTrackers),
        );
        for (final op in export.ops) {
          await _canonAuthority.throwIfCommitStale(
            sessionId: sessionId,
            canon: canon,
            token: token,
            isStillCurrent: isStillCurrent,
            target: LedgerTarget.fromMessage(plan.endMessage),
            checkCanon: replacement == null,
          );
          await _opApplier.applyOp(
            op: op,
            sessionId: sessionId,
            messageId: plan.endMessage.id,
            swipeId: plan.endMessage.swipeId,
            agentSwipeId: plan.endMessage.agentSwipeId,
            trackerRepo: _trackerRepo,
            basisRevisionNumber: canon.context.effectiveRevision.number,
            basisRevisionHash: canon.context.effectiveRevision.hash,
          );
          opsApplied++;
        }
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: replacement == null,
        );
        opsApplied += await _knowledgeFactRepo.applyReconciliationCleanup(
          sessionId: sessionId,
          ops: cleanupOps,
          allowedFactIds: allowedCleanupFactIds,
          endpointMessageId: plan.endMessage.id,
          messageIds: plan.messageIds,
        );
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
        final updated = await _trackerRepo.getBySessionId(sessionId);
        final afterState = await _reconciliationRunRepo.captureState(sessionId);
        final appendedRun = await _reconciliationRunRepo.getByContentHash(
          sessionId,
          draft.contentHash,
        );
        if (appendedRun == null) {
          throw StateError('Appended reconciliation run is unavailable');
        }
        await _reconciliationRunRepo.recordEffect(
          runId: appendedRun.id,
          sessionId: sessionId,
          before: beforeState,
          after: afterState,
          createdAt: candidate.createdAt,
        );
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
        await _snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: plan.endMessage.id,
          swipeId: plan.endMessage.swipeId,
          agentSwipeId: plan.endMessage.agentSwipeId,
          trackers: updated,
          committed: true,
        );
        await _throwIfReconciliationAborted(token, isStillCurrent);
        await _reconciliationCheckpointRepo.upsert(
          LedgerReconciliationCheckpoint(
            sessionId: sessionId,
            startMessageId: plan.startMessageId,
            endMessageId: plan.endMessage.id,
            endSwipeId: plan.endMessage.swipeId,
            endAgentSwipeId: plan.endMessage.agentSwipeId,
            messageIds: plan.messageIds,
            rangeHash: plan.rangeHash,
          ),
        );
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: LedgerTarget.fromMessage(plan.endMessage),
          checkCanon: false,
        );
      });
      return LedgerRunResult(
        status: 'ok',
        visibleLedger: originalVisibleLedger.isNotEmpty
            ? originalVisibleLedger
            : parsed.visibleLedger,
        opsApplied: replayed ? 0 : opsApplied,
        elapsedMs: sw.elapsedMilliseconds,
        attempts: attempts,
        model: config.model,
        repairAttempted: repairAttempted,
        effectiveTimeoutMs: timeoutMs,
        promptChars: totalPromptChars,
        responseChars: totalResponseChars,
      );
    } on LedgerCommitStale {
      return LedgerRunResult.aborted;
    } on _LedgerReconciliationAborted {
      return LedgerRunResult.aborted;
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return LedgerRunResult.aborted;
      }
      debugPrint('[StudioLedger] reconciliation failed: $e');
      return LedgerRunResult(
        status: 'error',
        error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  Future<void> _throwIfReconciliationAborted(
    CancelToken token,
    FutureOr<bool> Function()? isStillCurrent,
  ) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false) {
      throw const _LedgerReconciliationAborted();
    }
  }

  Future<bool> _renewReconciliationLease(String sessionId, String ownerId) =>
      _reconciliationLeaseRepo.renew(
        sessionId: sessionId,
        ownerId: ownerId,
        ttlSeconds: _reconciliationLeaseTtlSeconds,
      );

  /// Run the Studio Ledger for [sessionId] on [finalAssistantText].
  ///
  /// [messageId], [swipeId], [agentSwipeId] are the provenance anchor for
  /// state writes — required for rollback.
  ///
  /// [isStillCurrent] is called before each write; returns false when a newer
  /// generation has started (abort guard).
  ///
  /// Never throws — all errors are captured in [LedgerRunResult].
  Future<LedgerRunResult> run({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    bool forceEnabled = false,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    bool commitSnapshot = false,
    StudioLedgerEngine engine = StudioLedgerEngine.currentReconciled,
    String? operationIdentity,
  }) {
    final request = LedgerTurnRequest(
      sessionId: sessionId,
      settings: settings,
      config: config,
      finalAssistantText: finalAssistantText,
      recentHistoryText: recentHistoryText,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      forceEnabled: forceEnabled,
      isStillCurrent: isStillCurrent,
      cancelToken: cancelToken,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
      commitSnapshot: commitSnapshot,
      engine: engine,
    );
    if (operationIdentity == null) {
      return _turnRunner.run(request);
    }
    final key = _inFlightRegistry.runKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      finalAssistantText: finalAssistantText,
      recentHistoryText: recentHistoryText,
      forceEnabled: forceEnabled,
      commitSnapshot: commitSnapshot,
      engine: engine,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(key, () => _turnRunner.run(request));
  }

  Map<String, dynamic> _cleanupOpJson(KnowledgeCleanupOp op) => {
    'type': op.type.name,
    if (op.factId.isNotEmpty) 'factId': op.factId,
    if (op.fromKey.isNotEmpty) 'fromKey': op.fromKey,
    if (op.toKey.isNotEmpty) 'toKey': op.toKey,
    if (op.canonicalName.isNotEmpty) 'canonicalName': op.canonicalName,
  };

  String _cleanupOpMetadata(KnowledgeCleanupOp op) => switch (op.type) {
    KnowledgeCleanupOpType.retract => 'cleanup:retract:${op.factId}',
    KnowledgeCleanupOpType.renameEntity =>
      'cleanup:rename:${op.fromKey}:${op.toKey}:${op.canonicalName}',
  };
}

class _LedgerReconciliationAborted implements Exception {
  const _LedgerReconciliationAborted();
}

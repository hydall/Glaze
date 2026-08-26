import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../db/app_db.dart';
import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/ledger_debug_run_repo.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/reconciliation_replacement_repo.dart';
import '../db/repositories/reconciliation_state_codec.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../models/character_knowledge_fact.dart';
import '../models/knowledge_cleanup.dart';
import '../models/memory_book.dart';
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
import 'ledger/ledger_run_diagnostics.dart';
import 'ledger/ledger_run_result.dart';
import 'knowledge_cleanup_parser.dart';
import 'macro_engine.dart';
import 'studio_ledger_export_parser.dart';
import 'studio_ledger_reconciliation.dart';
import 'transport/llm_capture_context.dart';

export 'ledger/ledger_op_applier.dart';
export 'ledger/ledger_run_result.dart';
export 'ledger/ledger_canon_authority.dart';

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
  final LedgerPromptFactory _promptFactory;
  final LedgerOutputRecovery _outputRecovery;
  final LedgerRunDiagnostics _runDiagnostics;
  final LedgerReconciliationLeaseRepo _reconciliationLeaseRepo;
  final ReconciliationReplacementRepo _replacementRepo;

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
  }) : _parser = const StudioLedgerExportParser(),
       _opApplier = const LedgerOpApplier(),
       _inFlightRegistry = inFlightRegistry ?? const LedgerInFlightRegistry(),
       _promptFactory = promptFactory ?? const LedgerPromptFactory(),
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
           );

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
      final basis = await _prepareReplacementBasis(
        sessionId: sessionId,
        expectedRunId: expectedRunId,
        token: token,
        isStillCurrent: isStillCurrent,
      );
      if (basis is _ReplacementBasisFailure) {
        return LedgerRunResult(status: 'error', error: basis.reason);
      }
      final ready = basis as _ReplacementBasisReady;
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
    _ReplacementBasisReady? replacement,
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
      if (!await _isReconciliationBasisCurrent(
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
        if (!await _isReconciliationBasisCurrent(
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
        if (!await _isReconciliationBasisCurrent(
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
          await _throwIfReplacementStale(
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
    if (operationIdentity == null) {
      return _runUnshared(
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
    return _inFlightRegistry.join(
      key,
      () => _runUnshared(
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
      ),
    );
  }

  Future<LedgerRunResult> _runUnshared({
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
  }) async {
    final trace = LedgerRunTrace(
      sessionId: sessionId,
      kind: LedgerDebugRunKind.normal,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final result = await _runTraced(
      trace: trace,
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
    await _runDiagnostics.recordDebugRun(trace, result);
    return result;
  }

  Future<LedgerRunResult> _runTraced({
    required LedgerRunTrace trace,
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
  }) async {
    // Studio Ledger is always-on when Studio is enabled. forceEnabled is
    // still respected for manual triggers.

    if (finalAssistantText.trim().isEmpty) {
      debugPrint('[StudioLedger] skipping — empty assistant text');
      return LedgerRunResult.skipped;
    }

    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) return LedgerRunResult.aborted;

    final sw = Stopwatch()..start();

    try {
      // ── 1. LLM config is resolved by the caller via StudioSlotResolver ──
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
              false) {
        return LedgerRunResult.aborted;
      }

      // ── 2. Load prompt base (committed canon + live manual overrides) ────
      final canon = await _canonAuthority.load(sessionId);
      final promptTrackers = _canonAuthority.projectPromptTrackers(
        canon.context,
      );
      final book = await _bookRepo.getBySessionId(sessionId);
      final recentEntries =
          book?.entries.where((e) => e.status == 'active').take(20).toList() ??
          const <MemoryEntry>[];
      final entityAliases = await _knowledgeFactRepo.getEntityAliases(
        sessionId,
      );

      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!await _canonAuthority.isStillCurrent(sessionId, canon)) {
        return LedgerRunResult.aborted;
      }

      // ── 3. Build prompt ─────────────────────────────────────────────────
      final prompt = _promptFactory.buildLedgerPrompt(
        finalAssistantText: finalAssistantText,
        recentHistoryText: recentHistoryText,
        currentTrackers: promptTrackers,
        recentMemoryEntries: recentEntries,
        ledgerBlocks: ledgerBlocks,
        macroCtx: macroCtx,
        character: canon.source,
        entityAliases: entityAliases,
        engine: engine,
      );

      debugPrint(
        '[StudioLedger] prompt session=$sessionId '
        'chars=${prompt.length} '
        'usingPresetBlocks=${ledgerBlocks.isNotEmpty && macroCtx != null} '
        'first500=${prompt.length > 500 ? prompt.substring(0, 500) : prompt}',
      );

      // ── 4. Call LLM ─────────────────────────────────────────────────────
      final maxTokens = settings.ledger.studioLedgerMaxTokens > 0
          ? settings.ledger.studioLedgerMaxTokens
          : 15000;
      final temperature = settings.ledger.studioLedgerTemperature >= 0
          ? settings.ledger.studioLedgerTemperature
          : 0.2;
      final timeoutMs = _llm.resolveLedgerTimeout(settings);

      debugPrint(
        '[StudioLedger] starting session=$sessionId '
        'model=${config.model} '
        'timeoutMs=$timeoutMs '
        'textChars=${finalAssistantText.length}',
      );

      final outcome = await _llm.callOnceWithLog(
        config: config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: token,
        omitReasoning: true,
        captureContext: LlmCaptureContext(
          stage: 'ledger.turn',
          sessionId: sessionId,
          messageId: messageId,
          pipelineRunId: 'ledger:$messageId:$swipeId:$agentSwipeId',
          logicalCallId: 'ledger:$messageId:$swipeId:$agentSwipeId',
          relatedArtifactId: messageId,
        ),
      );

      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
              false) {
        return LedgerRunResult.aborted;
      }

      if (!outcome.isOk || outcome.text == null || outcome.text!.isEmpty) {
        final lastAttempt = outcome.attempts.lastOrNull;
        debugPrint(
          '[StudioLedger] LLM call failed session=$sessionId '
          'status=${lastAttempt?.status} '
          'statusCode=${lastAttempt?.statusCode ?? 0} '
          'elapsedMs=${lastAttempt?.elapsedMs ?? 0} '
          'error=${lastAttempt?.error ?? "none"}',
        );
        return LedgerRunResult(
          status: 'error',
          error:
              'LLM call failed: ${lastAttempt?.status}'
              '${lastAttempt?.error != null ? ': ${lastAttempt!.error}' : ''}',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: config.model,
        );
      }

      // ── 5. Parse + validate ─────────────────────────────────────────────
      final rawResponse = outcome.text!;
      debugPrint(
        '[StudioLedger] raw response session=$sessionId '
        'chars=${rawResponse.length} '
        'first1000=${rawResponse.length > 1000 ? rawResponse.substring(0, 1000) : rawResponse}',
      );

      var effectiveResponse = rawResponse;
      var parseResult = _parser.parse(
        effectiveResponse,
        focalUserName: macroCtx?.userName ?? '',
      );
      await _runDiagnostics.recordLedgerParserVerdict(outcome, parseResult);
      trace.recordFirstResponse(
        model: config.model,
        responseText: rawResponse,
        parsed: parseResult,
      );
      final originalFailure = parseResult.failure;
      final originalVisibleLedger = parseResult.visibleLedger;
      var attempts = outcome.attempts;
      var repairAttempted = false;
      var totalPromptChars = prompt.length;
      var totalResponseChars = rawResponse.length;

      if (parseResult.failure.isRepairable) {
        if (token.isCancelled ||
            await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
                false) {
          return LedgerRunResult.aborted;
        }
        if (!await _canonAuthority.isStillCurrent(sessionId, canon)) {
          return LedgerRunResult.aborted;
        }
        if (_outputRecovery.isOversizedRepairInput(effectiveResponse)) {
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
        repairAttempted = true;
        trace.recordRepairRequested(exportRepair: true);
        final repairPrompt = _outputRecovery.buildRepairPrompt(
          effectiveResponse,
        );
        totalPromptChars += repairPrompt.length;
        final repair = await _llm.callOnceWithLog(
          config: config,
          prompt: repairPrompt,
          maxTokens: maxTokens,
          temperature: 0,
          timeoutMs: timeoutMs,
          cancelToken: token,
          omitReasoning: true,
          captureContext: LlmCaptureContext(
            stage: 'ledger.turn_repair',
            sessionId: sessionId,
            messageId: messageId,
            pipelineRunId: 'ledger:$messageId:$swipeId:$agentSwipeId',
            logicalCallId: 'ledger:$messageId:$swipeId:$agentSwipeId:repair',
            relatedArtifactId: messageId,
          ),
        );
        attempts = _outputRecovery.combineAttempts(attempts, repair.attempts);
        totalResponseChars += repair.text?.length ?? 0;
        if (token.isCancelled ||
            await _canonAuthority.passesCurrentnessGuard(isStillCurrent) ==
                false) {
          return LedgerRunResult.aborted;
        }
        if (!await _canonAuthority.isStillCurrent(sessionId, canon)) {
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
        effectiveResponse = repair.text!;
        parseResult = _parser.parse(
          effectiveResponse,
          focalUserName: macroCtx?.userName ?? '',
        );
        await _runDiagnostics.recordLedgerParserVerdict(repair, parseResult);
        trace.recordRepairResponse(
          responseText: effectiveResponse,
          parsed: parseResult,
        );
        if (parseResult.export != null &&
            !_outputRecovery.repairPreservesStructuredEvidence(
              rawResponse,
              parseResult.export!,
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
      }

      debugPrint(
        '[StudioLedger] parsed session=$sessionId '
        'hasExport=${parseResult.hasExport} '
        'visibleLedgerChars=${parseResult.visibleLedger.length} '
        'rejection=${parseResult.rejectionReason ?? "none"}',
      );

      if (repairAttempted &&
          originalFailure == LedgerParseFailure.missingExport &&
          parseResult.failure == LedgerParseFailure.emptyExport) {
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

      if (!parseResult.hasExport &&
          parseResult.failure != LedgerParseFailure.emptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: originalVisibleLedger.isNotEmpty
              ? originalVisibleLedger
              : parseResult.visibleLedger,
          error: parseResult.rejectionReason,
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

      // ── 6. Apply ops to tracker namespace ───────────────────────────────
      final export = parseResult.export ?? const StudioLedgerExport();
      var opsApplied = 0;
      final target = LedgerTarget(
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        content: finalAssistantText,
      );
      // Parse optional knowledge cleanup (rename_entity) from the same
      // response. It is committed under the same target/canon fence as the
      // tracker patch so an obsolete swipe can never rename live facts.
      final cleanupOps = const KnowledgeCleanupParser().parse(
        output: effectiveResponse,
        reviewText: '$recentHistoryText\n$finalAssistantText',
        entityKeys: entityAliases.keys.toSet(),
      );
      final facts = export.knowledgeFacts
          .map(
            (fact) => CharacterKnowledgeFact(
              id: generateId(),
              chatSessionId: sessionId,
              knowerKey: fact.knowerKey,
              knowerName: fact.knowerName,
              subjectKey: fact.subjectKey,
              subjectName: fact.subjectName,
              factClass: CharacterKnowledgeFactClass.fromWireName(
                fact.factClass,
              ),
              scopeKey: fact.scopeKey,
              predicate: fact.predicate,
              object: fact.object,
              epistemicState: CharacterKnowledgeEpistemicState.fromWireName(
                fact.epistemicState,
              ),
              confidence: fact.confidence,
              importance: fact.importance,
              entities: fact.entities,
              topics: fact.topics,
              sourceMessageId: messageId,
              sourceSwipeId: swipeId,
              sourceAgentSwipeId: agentSwipeId,
              supersedesId: fact.supersedesId,
              basisRevisionNumber: canon.context.effectiveRevision.number,
              basisRevisionHash: canon.context.effectiveRevision.hash,
            ),
          )
          .toList(growable: false);
      await _trackerRepo.db.transaction(() async {
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
        );
        // Rebuild model-owned state from committed canon before this patch.
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
            target: target,
          );
          await _opApplier.applyOp(
            op: op,
            sessionId: sessionId,
            messageId: messageId,
            swipeId: swipeId,
            agentSwipeId: agentSwipeId,
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
          target: target,
        );
        await _knowledgeFactRepo.replaceTentativeAnchor(
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          facts: facts,
        );
        if (cleanupOps.isNotEmpty) {
          await _canonAuthority.throwIfCommitStale(
            sessionId: sessionId,
            canon: canon,
            token: token,
            isStillCurrent: isStillCurrent,
            target: target,
          );
          opsApplied += await _knowledgeFactRepo.applyReconciliationCleanup(
            sessionId: sessionId,
            ops: cleanupOps,
            endpointMessageId: null,
          );
        }
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
          checkCanon: false,
        );
        final updatedTrackers = await _trackerRepo.getBySessionId(sessionId);
        await _snapshotRepo.upsertTrackers(
          sessionId: sessionId,
          messageId: messageId,
          swipeId: swipeId,
          agentSwipeId: agentSwipeId,
          trackers: updatedTrackers,
          committed: commitSnapshot,
        );
        await _canonAuthority.throwIfCommitStale(
          sessionId: sessionId,
          canon: canon,
          token: token,
          isStillCurrent: isStillCurrent,
          target: target,
          checkCanon: false,
        );
      });

      debugPrint(
        '[StudioLedger] applied $opsApplied/${export.ops.length} ops session=$sessionId',
      );

      sw.stop();
      debugPrint(
        '[StudioLedger] done session=$sessionId '
        'ops=$opsApplied '
        'elapsedMs=${sw.elapsedMilliseconds}',
      );

      return LedgerRunResult(
        status: 'ok',
        visibleLedger: originalVisibleLedger.isNotEmpty
            ? originalVisibleLedger
            : parseResult.visibleLedger,
        opsApplied: opsApplied,
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
    } on TimeoutException {
      sw.stop();
      debugPrint('[StudioLedger] timeout session=$sessionId');
      return LedgerRunResult(
        status: 'timeout',
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return LedgerRunResult.aborted;
      }
      debugPrint('[StudioLedger] error session=$sessionId: $e');
      return LedgerRunResult(
        status: 'error',
        error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }

  Future<_ReplacementBasis> _prepareReplacementBasis({
    required String sessionId,
    required String expectedRunId,
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
  }) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false) {
      return const _ReplacementBasisFailure('Replacement was cancelled');
    }
    if (await _reconciliationRunRepo.validateChain(sessionId)
        is! ReconciliationRunValid) {
      return const _ReplacementBasisFailure(
        'Reconciliation history failed integrity validation',
      );
    }
    final head = await _reconciliationRunRepo.getHead(sessionId);
    if (head == null || head.id != expectedRunId) {
      return const _ReplacementBasisFailure(
        'The selected reconciliation is no longer the latest commit',
      );
    }
    final validated = await _reconciliationRunRepo.validateEffect(head);
    if (validated is! ReconciliationEffectValid) {
      return _ReplacementBasisFailure(
        validated is ReconciliationEffectInvalid
            ? validated.reason
            : 'Exact reconciliation effect is unavailable',
      );
    }
    if (!await _reconciliationRunRepo.currentStateMatches(
      sessionId,
      validated.after,
    )) {
      return const _ReplacementBasisFailure(
        'Current Ledger or knowledge state changed after this commit',
      );
    }
    final messages = await _reconciliationRunRepo.reconstructSelectedMessages(
      head,
    );
    if (messages == null || messages.isEmpty) {
      return const _ReplacementBasisFailure(
        'The committed message range no longer matches the transcript',
      );
    }
    final plan = LedgerReconciliationPlan(
      messages: messages,
      endMessage: messages.last,
      rangeHash: computeLedgerReconciliationRangeHash(messages),
    );
    final checkpoint = await _reconciliationCheckpointRepo.get(sessionId);
    if (!_checkpointMatchesPlan(checkpoint, plan)) {
      return const _ReplacementBasisFailure(
        'Reconciliation checkpoint does not match the latest commit',
      );
    }
    if (await _replacementRepo.hasAppliedDependency(
      sessionId: sessionId,
      reconciliationRunId: head.id,
    )) {
      return const _ReplacementBasisFailure(
        'An applied Card Rewriter proposal depends on this reconciliation',
      );
    }
    final currentCanon = await _canonAuthority.loadReadOnly(sessionId);
    final decoded = ReconciliationStateCodec.decode(
      sessionId: sessionId,
      ledgerJson: validated.before.ledgerJson,
      knowledgeJson: validated.before.knowledgeJson,
    );
    final beforeCanon = await _canonAuthority
        .loadReadOnlyFromReconciliationState(
          sessionId: sessionId,
          sourceCharacter: currentCanon.source,
          ledgerTrackers: decoded.trackers,
          knowledgeFacts: decoded.knowledgeFacts,
        );
    final beforeContext = beforeCanon.context;
    if (beforeContext.stamp.identity != head.effectiveCanonStamp ||
        beforeContext.effectiveRevision.number != head.effectiveCanonRevision ||
        beforeContext.effectiveRevision.hash != head.effectiveCanonHash) {
      return const _ReplacementBasisFailure(
        'The saved before-state no longer matches the commit canon',
      );
    }
    final endpointSnapshot = await _snapshotRepo.getByAnchor(
      sessionId: sessionId,
      messageId: plan.endMessage.id,
      swipeId: plan.endMessage.swipeId,
      agentSwipeId: plan.endMessage.agentSwipeId,
    );
    if (endpointSnapshot == null || !endpointSnapshot.committed) {
      return const _ReplacementBasisFailure(
        'The reconciliation endpoint snapshot is not committed',
      );
    }
    return _ReplacementBasisReady(
      head: head,
      effect: validated,
      plan: plan,
      beforeCanon: beforeCanon,
      currentCanon: currentCanon,
    );
  }

  Future<bool> _isReconciliationBasisCurrent({
    required String sessionId,
    required LedgerCanonContext canon,
    required _ReplacementBasisReady? replacement,
  }) async {
    if (replacement == null) {
      return _canonAuthority.isStillCurrent(sessionId, canon);
    }
    return _replacementBasisStillCurrent(replacement);
  }

  Future<bool> _replacementBasisStillCurrent(
    _ReplacementBasisReady basis,
  ) async {
    final head = await _reconciliationRunRepo.getHead(basis.head.sessionId);
    final snapshot = await _snapshotRepo.getByAnchor(
      sessionId: basis.head.sessionId,
      messageId: basis.plan.endMessage.id,
      swipeId: basis.plan.endMessage.swipeId,
      agentSwipeId: basis.plan.endMessage.agentSwipeId,
    );
    return head?.id == basis.head.id &&
        head?.chainHash == basis.head.chainHash &&
        snapshot?.committed == true &&
        await _reconciliationRunRepo.currentStateMatches(
          basis.head.sessionId,
          basis.effect.after,
        ) &&
        await _canonAuthority.isStillCurrent(
          basis.head.sessionId,
          basis.currentCanon,
        );
  }

  Future<void> _throwIfReplacementStale(
    _ReplacementBasisReady basis, {
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
  }) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false ||
        !await _replacementBasisStillCurrent(basis)) {
      throw const LedgerCommitStale();
    }
    final messages = await _reconciliationRunRepo.reconstructSelectedMessages(
      basis.head,
    );
    final checkpoint = await _reconciliationCheckpointRepo.get(
      basis.head.sessionId,
    );
    if (messages == null || !_checkpointMatchesPlan(checkpoint, basis.plan)) {
      throw const LedgerCommitStale();
    }
    final validated = await _reconciliationRunRepo.validateEffect(basis.head);
    if (validated is! ReconciliationEffectValid ||
        validated.before.hash != basis.effect.before.hash ||
        validated.after.hash != basis.effect.after.hash ||
        await _replacementRepo.hasAppliedDependency(
          sessionId: basis.head.sessionId,
          reconciliationRunId: basis.head.id,
        )) {
      throw const LedgerCommitStale();
    }
  }

  bool _checkpointMatchesPlan(
    LedgerReconciliationCheckpoint? checkpoint,
    LedgerReconciliationPlan plan,
  ) {
    if (checkpoint == null ||
        checkpoint.startMessageId != plan.startMessageId ||
        checkpoint.endMessageId != plan.endMessage.id ||
        checkpoint.endSwipeId != plan.endMessage.swipeId ||
        checkpoint.endAgentSwipeId != plan.endMessage.agentSwipeId ||
        checkpoint.rangeHash != plan.rangeHash ||
        checkpoint.messageIds.length != plan.messageIds.length) {
      return false;
    }
    for (var i = 0; i < checkpoint.messageIds.length; i++) {
      if (checkpoint.messageIds[i] != plan.messageIds[i]) return false;
    }
    return true;
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

sealed class _ReplacementBasis {
  const _ReplacementBasis();
}

final class _ReplacementBasisReady extends _ReplacementBasis {
  const _ReplacementBasisReady({
    required this.head,
    required this.effect,
    required this.plan,
    required this.beforeCanon,
    required this.currentCanon,
  });

  final LedgerReconciliationSuccessfulRunRow head;
  final ReconciliationEffectValid effect;
  final LedgerReconciliationPlan plan;
  final LedgerCanonContext beforeCanon;
  final LedgerCanonContext currentCanon;
}

final class _ReplacementBasisFailure extends _ReplacementBasis {
  const _ReplacementBasisFailure(this.reason);

  final String reason;
}

class _LedgerReconciliationAborted implements Exception {
  const _LedgerReconciliationAborted();
}

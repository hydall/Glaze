import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../db/repositories/ledger_debug_run_repo.dart';
import '../../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../../db/repositories/tracker_snapshot_repo.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../../models/studio_ledger_export.dart';
import '../../utils/id_generator.dart';
import '../aux_llm_client.dart';
import '../knowledge_cleanup_parser.dart';
import '../macro_engine.dart';
import '../studio_ledger_export_parser.dart';
import '../studio_ledger_reconciliation.dart';
import '../transport/llm_capture_context.dart';
import 'ledger_canon_authority.dart';
import 'ledger_output_recovery.dart';
import 'ledger_reconciliation_committer.dart';
import 'ledger_replacement_basis_resolver.dart';
import 'ledger_run_diagnostics.dart';
import 'ledger_run_result.dart';

final class LedgerReconciliationRequest {
  const LedgerReconciliationRequest({
    required this.sessionId,
    required this.settings,
    required this.config,
    required this.plan,
    required this.ledgerBlocks,
    required this.macroCtx,
    required this.isStillCurrent,
    required this.cancelToken,
    required this.purpose,
  });

  final String sessionId;
  final PipelineSettings settings;
  final AuxApiConfig config;
  final LedgerReconciliationPlan plan;
  final List<StudioPresetBlock> ledgerBlocks;
  final MacroContext? macroCtx;
  final FutureOr<bool> Function()? isStillCurrent;
  final CancelToken? cancelToken;
  final String purpose;
}

final class LedgerReconciliationReplacementRequest {
  const LedgerReconciliationReplacementRequest({
    required this.sessionId,
    required this.expectedRunId,
    required this.settings,
    required this.config,
    required this.ledgerBlocks,
    required this.macroCtx,
    required this.isStillCurrent,
    required this.cancelToken,
  });

  final String sessionId;
  final String expectedRunId;
  final PipelineSettings settings;
  final AuxApiConfig config;
  final List<StudioPresetBlock> ledgerBlocks;
  final MacroContext? macroCtx;
  final FutureOr<bool> Function()? isStillCurrent;
  final CancelToken? cancelToken;
}

final class LedgerReconciliationRunner {
  static const _leaseTtlSeconds = 60 * 60;

  const LedgerReconciliationRunner({
    required AuxLlmClient llm,
    required TrackerSnapshotRepo snapshotRepo,
    required LedgerReconciliationLeaseRepo reconciliationLeaseRepo,
    required LedgerCanonAuthority canonAuthority,
    required LedgerOutputRecovery outputRecovery,
    required LedgerReconciliationCommitter committer,
    required LedgerReplacementBasisResolver replacementBasisResolver,
    required LedgerRunDiagnostics runDiagnostics,
    required StudioLedgerExportParser parser,
  }) : this._(
         llm,
         snapshotRepo,
         reconciliationLeaseRepo,
         canonAuthority,
         outputRecovery,
         committer,
         replacementBasisResolver,
         runDiagnostics,
         parser,
       );

  const LedgerReconciliationRunner._(
    this._llm,
    this._snapshotRepo,
    this._reconciliationLeaseRepo,
    this._canonAuthority,
    this._outputRecovery,
    this._committer,
    this._replacementBasisResolver,
    this._runDiagnostics,
    this._parser,
  );

  final AuxLlmClient _llm;
  final TrackerSnapshotRepo _snapshotRepo;
  final LedgerReconciliationLeaseRepo _reconciliationLeaseRepo;
  final LedgerCanonAuthority _canonAuthority;
  final LedgerOutputRecovery _outputRecovery;
  final LedgerReconciliationCommitter _committer;
  final LedgerReplacementBasisResolver _replacementBasisResolver;
  final LedgerRunDiagnostics _runDiagnostics;
  final StudioLedgerExportParser _parser;

  Future<LedgerRunResult> reconcile(LedgerReconciliationRequest request) async {
    final ownerId = 'ledger-reconciliation-${generateId()}';
    if (!await _reconciliationLeaseRepo.acquire(
      sessionId: request.sessionId,
      ownerId: ownerId,
      purpose: request.purpose,
      ttlSeconds: _leaseTtlSeconds,
    )) {
      return const LedgerRunResult(
        status: 'skipped',
        error: 'Another reconciliation is already running for this session',
      );
    }
    final trace = LedgerRunTrace(
      sessionId: request.sessionId,
      kind: LedgerDebugRunKind.reconciliation,
      messageId: request.plan.endMessage.id,
      swipeId: request.plan.endMessage.swipeId,
      agentSwipeId: request.plan.endMessage.agentSwipeId,
    );
    try {
      final result = await _reconcileTraced(
        trace: trace,
        request: request,
        leaseOwnerId: ownerId,
      );
      if (await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
        sessionId: request.sessionId,
        ownerId: ownerId,
      )) {
        await _runDiagnostics.recordDebugRun(trace, result);
      }
      return result;
    } finally {
      await _reconciliationLeaseRepo.release(
        sessionId: request.sessionId,
        ownerId: ownerId,
      );
    }
  }

  Future<LedgerRunResult> replaceLatest(
    LedgerReconciliationReplacementRequest request,
  ) async {
    final ownerId = 'ledger-reconciliation-${generateId()}';
    if (!await _reconciliationLeaseRepo.acquire(
      sessionId: request.sessionId,
      ownerId: ownerId,
      purpose: 'replacement',
      ttlSeconds: _leaseTtlSeconds,
    )) {
      return const LedgerRunResult(
        status: 'skipped',
        error: 'Another reconciliation is already running for this session',
      );
    }
    final token = request.cancelToken ?? CancelToken();
    try {
      final basis = await _replacementBasisResolver.prepare(
        sessionId: request.sessionId,
        expectedRunId: request.expectedRunId,
        token: token,
        isStillCurrent: request.isStillCurrent,
      );
      if (basis is LedgerReplacementBasisFailure) {
        return LedgerRunResult(status: 'error', error: basis.reason);
      }
      final ready = basis as LedgerReplacementBasisReady;
      final trace = LedgerRunTrace(
        sessionId: request.sessionId,
        kind: LedgerDebugRunKind.reconciliation,
        messageId: ready.plan.endMessage.id,
        swipeId: ready.plan.endMessage.swipeId,
        agentSwipeId: ready.plan.endMessage.agentSwipeId,
      );
      final result = await _reconcileTraced(
        trace: trace,
        request: LedgerReconciliationRequest(
          sessionId: request.sessionId,
          settings: request.settings,
          config: request.config,
          plan: ready.plan,
          ledgerBlocks: request.ledgerBlocks,
          macroCtx: request.macroCtx,
          isStillCurrent: request.isStillCurrent,
          cancelToken: token,
          purpose: 'replacement',
        ),
        canonOverride: ready.beforeCanon,
        replacement: ready,
        leaseOwnerId: ownerId,
      );
      if (await _reconciliationLeaseRepo.ownsLiveLeaseInTransaction(
        sessionId: request.sessionId,
        ownerId: ownerId,
      )) {
        await _runDiagnostics.recordDebugRun(trace, result);
      }
      return result;
    } finally {
      await _reconciliationLeaseRepo.release(
        sessionId: request.sessionId,
        ownerId: ownerId,
      );
    }
  }

  Future<LedgerRunResult> _reconcileTraced({
    required LedgerRunTrace trace,
    required LedgerReconciliationRequest request,
    LedgerCanonContext? canonOverride,
    LedgerReplacementBasisReady? replacement,
    required String leaseOwnerId,
  }) async {
    final token = request.cancelToken ?? CancelToken();
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(request.isStillCurrent) ==
            false) {
      return LedgerRunResult.aborted;
    }
    final sw = Stopwatch()..start();
    try {
      final canon =
          canonOverride ?? await _canonAuthority.load(request.sessionId);
      await _throwIfAborted(token, request.isStillCurrent);
      final endpointSnapshot = await _snapshotRepo.getByAnchor(
        sessionId: request.sessionId,
        messageId: request.plan.endMessage.id,
        swipeId: request.plan.endMessage.swipeId,
        agentSwipeId: request.plan.endMessage.agentSwipeId,
      );
      await _throwIfAborted(token, request.isStillCurrent);
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
      final reviewMessageIds = request.plan.messageIds.toSet();
      final reviewableFacts = canon.context.resolution.activeFacts;
      final promptFacts = reviewableFacts
          .where((fact) => reviewMessageIds.contains(fact.sourceMessageId))
          .toList();
      final duplicateRetractions = exactDuplicateKnowledgeRetractions(
        reviewableFacts,
      );
      final staleAnchorRetractions = staleKnowledgeAnchorRetractions(
        reviewableFacts,
        request.plan.messages,
      );
      await _throwIfAborted(token, request.isStillCurrent);
      final promptBlock = request.ledgerBlocks
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
          : request.macroCtx == null
          ? promptBlock.content
          : replaceMacros(promptBlock.content, request.macroCtx!).text;
      const reconciliationPrompt = StudioLedgerReconciliationPrompt();
      final reviewText = request.plan.messages
          .map((message) => message.content)
          .join('\n');
      final offeredFacts = reconciliationPrompt.relevantKnowledgeFacts(
        promptFacts,
        reviewText,
      );
      final prompt = reconciliationPrompt.build(
        systemPrompt: systemPrompt,
        plan: request.plan,
        trackers: promptTrackers,
        knowledgeFacts: offeredFacts,
        character: canon.source,
      );
      await _throwIfAborted(token, request.isStillCurrent);
      if (!await _renewLease(request.sessionId, leaseOwnerId)) {
        return LedgerRunResult.aborted;
      }
      final timeoutMs = _llm.resolveLedgerTimeout(request.settings);
      final outcome = await _llm.callOnceWithLog(
        config: request.config,
        prompt: prompt,
        maxTokens: request.settings.ledger.studioLedgerMaxTokens > 0
            ? request.settings.ledger.studioLedgerMaxTokens
            : 15000,
        temperature: request.settings.ledger.studioLedgerTemperature >= 0
            ? request.settings.ledger.studioLedgerTemperature
            : 0.2,
        timeoutMs: timeoutMs,
        cancelToken: token,
        omitReasoning: true,
        captureContext: LlmCaptureContext(
          stage: 'ledger.reconciliation',
          sessionId: request.sessionId,
          messageId: request.plan.endMessage.id,
          pipelineRunId: request.plan.rangeHash,
          logicalCallId: request.plan.rangeHash,
          relatedArtifactId: request.plan.rangeHash,
        ),
      );
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
        sessionId: request.sessionId,
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
          model: request.config.model,
        );
      }

      var responseText = outcome.text!;
      var cleanupResponseText = responseText;
      var parsed = _parser.parse(
        responseText,
        focalUserName: request.macroCtx?.userName ?? '',
      );
      await _runDiagnostics.recordLedgerParserVerdict(outcome, parsed);
      trace.recordFirstResponse(
        model: request.config.model,
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
        await _throwIfAborted(token, request.isStillCurrent);
        if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
          sessionId: request.sessionId,
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
            model: request.config.model,
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
        if (!await _renewLease(request.sessionId, leaseOwnerId)) {
          return LedgerRunResult.aborted;
        }
        final repair = await _llm.callOnceWithLog(
          config: request.config,
          prompt: repairPrompt,
          maxTokens: request.settings.ledger.studioLedgerMaxTokens > 0
              ? request.settings.ledger.studioLedgerMaxTokens
              : 15000,
          temperature: 0,
          timeoutMs: timeoutMs,
          cancelToken: token,
          omitReasoning: true,
          captureContext: LlmCaptureContext(
            stage: 'ledger.reconciliation_repair',
            sessionId: request.sessionId,
            messageId: request.plan.endMessage.id,
            pipelineRunId: request.plan.rangeHash,
            logicalCallId: '${request.plan.rangeHash}:repair',
            relatedArtifactId: request.plan.rangeHash,
          ),
        );
        attempts = _outputRecovery.combineAttempts(attempts, repair.attempts);
        totalResponseChars += repair.text?.length ?? 0;
        await _throwIfAborted(token, request.isStillCurrent);
        if (!await _replacementBasisResolver.isReconciliationBasisCurrent(
          sessionId: request.sessionId,
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
            model: request.config.model,
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
            focalUserName: request.macroCtx?.userName ?? '',
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
              model: request.config.model,
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
              model: request.config.model,
              repairAttempted: true,
              effectiveTimeoutMs: timeoutMs,
              promptChars: totalPromptChars,
              responseChars: totalResponseChars,
            );
          }
        } else {
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
              model: request.config.model,
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
          model: request.config.model,
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
          model: request.config.model,
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
          model: request.config.model,
          repairAttempted: repairAttempted,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!cleanupParser.hasValidBlock(cleanupResponseText)) {
        return LedgerRunResult(
          status: 'error',
          error: 'Reconciliation returned no valid knowledge cleanup block',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: request.config.model,
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
      final commit = await _committer.commit(
        LedgerReconciliationCommitRequest(
          sessionId: request.sessionId,
          leaseOwnerId: leaseOwnerId,
          plan: request.plan,
          canon: canon,
          promptTrackers: promptTrackers,
          export: export,
          cleanupOps: cleanupOps,
          allowedCleanupFactIds: allowedCleanupFactIds,
          token: token,
          isStillCurrent: request.isStillCurrent,
          replacement: replacement,
        ),
      );
      return LedgerRunResult(
        status: 'ok',
        visibleLedger: originalVisibleLedger.isNotEmpty
            ? originalVisibleLedger
            : parsed.visibleLedger,
        opsApplied: commit.replayed ? 0 : commit.opsApplied,
        elapsedMs: sw.elapsedMilliseconds,
        attempts: attempts,
        model: request.config.model,
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

  Future<void> _throwIfAborted(
    CancelToken token,
    FutureOr<bool> Function()? isStillCurrent,
  ) async {
    if (token.isCancelled ||
        await _canonAuthority.passesCurrentnessGuard(isStillCurrent) == false) {
      throw const _LedgerReconciliationAborted();
    }
  }

  Future<bool> _renewLease(String sessionId, String ownerId) =>
      _reconciliationLeaseRepo.renew(
        sessionId: sessionId,
        ownerId: ownerId,
        ttlSeconds: _leaseTtlSeconds,
      );
}

final class _LedgerReconciliationAborted implements Exception {
  const _LedgerReconciliationAborted();
}

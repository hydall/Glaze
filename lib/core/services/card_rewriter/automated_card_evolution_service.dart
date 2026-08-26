import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/card_evolution_writer_call_repo.dart';
import '../../db/repositories/llm_request_capture_repo.dart';
import '../../db/app_db.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../models/agent_operation_record.dart';
import '../../models/card_evolution_observation.dart';
import '../../utils/id_generator.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/time_helpers.dart';
import 'card_rewrite_prompt_builder.dart';
import 'card_rewriter_contracts.dart';
import 'card_evolution_diagnostics.dart';
import 'durable_writer_call_runner.dart';
import 'manual_rewrite_service.dart';
import 'observation_response_parser.dart';
import 'writer_context_consolidator.dart';

const _writerMaxTokens = 40000;
const _writerLeaseSeconds = 600;
const _writerCollectorBatchSize = 2;

enum AutomatedCardEvolutionStage { observation, cardRewriter }

/// Dedicated review-only automation lane. Claim and final commit are repository
/// operations; the only work between them is shared-context prompt assembly and
/// two bounded, cancellable writer calls.
class AutomatedCardEvolutionService {
  AutomatedCardEvolutionService({
    required this.repo,
    required this.resolveModel,
    required this._executor,
    this.isEnabled,
    this.isLorebookEvolutionEnabled,
    this.timeoutMs = 180000,
    this.leaseSeconds = _writerLeaseSeconds,
    CardEvolutionObservationRepo? observationRepo,
    CardEvolutionCollectorRunRepo? collectorRunRepo,
    CardEvolutionWriterCallRepo? writerCallRepo,
    LlmRequestCaptureRepo? requestCaptureRepo,
    CardEvolutionDiagnostics? diagnostics,
    DurableWriterCallRunner? writerCallRunner,
    WriterContextConsolidator? writerContextConsolidator,
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  }) : observationRepo =
           observationRepo ?? CardEvolutionObservationRepo(repo.db),
       collectorRunRepo =
           collectorRunRepo ?? CardEvolutionCollectorRunRepo(repo.db),
       writerCallRepo = writerCallRepo ?? CardEvolutionWriterCallRepo(repo.db),
       requestCaptureRepo =
           requestCaptureRepo ?? LlmRequestCaptureRepo(repo.db),
       _diagnostics = diagnostics ?? CardEvolutionDiagnostics(repo) {
    _writerCallRunner =
        writerCallRunner ??
        DurableWriterCallRunner(
          repo: repo,
          writerCallRepo: this.writerCallRepo,
          executor: _executor,
          diagnostics: _diagnostics,
          timeoutMs: timeoutMs,
          leaseSeconds: leaseSeconds,
        );
    _writerContextConsolidator =
        writerContextConsolidator ??
        WriterContextConsolidator(
          writerCallRunner: _writerCallRunner,
          discardOrRetainWriter: _discardOrRetainWriter,
          snapshotTooLarge: _snapshotTooLarge,
        );
  }

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
  final ObservationResponseParser _observationResponseParser =
      const ObservationResponseParser();
  final CardEvolutionDiagnostics _diagnostics;
  late final DurableWriterCallRunner _writerCallRunner;
  late final WriterContextConsolidator _writerContextConsolidator;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final bool Function()? isLorebookEvolutionEnabled;
  final int timeoutMs;
  final int leaseSeconds;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
  final Map<String, CancelToken> _tokens = {};
  final Map<String, Future<CardEvolutionFinalizeOutcome>> _inFlight = {};

  Future<CardEvolutionFinalizeOutcome> runOneBatch(
    String sessionId, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) {
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _runManual(sessionId, onStage: onStage);
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _runManual(
    String sessionId, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    // Explicit "Run now" retains its historical convenience: when the current
    // reconciliation count is even it also refreshes observations. Automatic
    // cadence never uses this path.
    try {
      final count = await repo.countSuccessfulReconciliations(sessionId);
      if (count > 0 && count.isEven) {
        onStage?.call(AutomatedCardEvolutionStage.observation);
        final snapshot = await repo.buildObservationSnapshot(sessionId);
        if (snapshot != null) {
          await _runObservationPass(sessionId, snapshot, count ~/ 2);
          await _checkPromotions(sessionId);
        }
      }
    } catch (_) {
      // Manual observation refresh is best effort; writer remains available.
    }
    return _runWriter(sessionId, onStage: onStage);
  }

  /// Automatic lane: collect each completed pair of valid reconciliations,
  /// then run at most one overdue writer cycle per two collectors.
  Future<CardEvolutionFinalizeOutcome> runAfterReconciliation(
    LedgerReconciliationSuccessfulRunRow reconciliationRun, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) {
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final sessionId = reconciliationRun.sessionId;
    final active = _inFlight[sessionId];
    if (active != null) {
      // Do not silently absorb a newer reconciliation while the previous
      // collector is running. Re-enter after it finishes; the durable backlog
      // makes this idempotent when the newer callback names the same head.
      return () async {
        try {
          await active;
        } catch (_) {
          // A failed active attempt must not discard the newer durable head.
        }
        return runAfterReconciliation(reconciliationRun, onStage: onStage);
      }();
    }
    final future = _runAutomatic(reconciliationRun, onStage: onStage);
    _inFlight[sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> retryFailedCollector(
    String collectorRunId,
  ) => _recoverFailedCollector(collectorRunId);

  Future<CardEvolutionFinalizeOutcome> resumeFailedWriter(String claimId) =>
      _recoverWriter(claimId);

  Future<CardEvolutionFinalizeOutcome> retryFailedWriterCall(String callId) =>
      _recoverWriterCall(callId);

  Future<CardEvolutionFinalizeOutcome> correctFailedWriterCall(
    String callId, {
    required String response,
  }) => _recoverWriterCall(callId, manualResponse: response);

  Future<CardEvolutionFinalizeOutcome> _recoverWriterCall(
    String callId, {
    String? manualResponse,
  }) async {
    final call = await writerCallRepo.getById(callId);
    if (call == null) {
      return const CardEvolutionFinalizeOutcome('writerCallNotFound');
    }
    if (call.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('writerCallNotFailed');
    }
    final chain = await writerCallRepo.readChain(call.claimId);
    final frontier = chain
        .where((row) => row.status != 'completed')
        .firstOrNull;
    if (frontier?.id != call.id) {
      return const CardEvolutionFinalizeOutcome('writerCallNotFrontier');
    }
    return _recoverWriter(
      call.claimId,
      requestedCallId: call.id,
      manualResponse: manualResponse,
    );
  }

  Future<CardEvolutionFinalizeOutcome> _recoverWriter(
    String claimId, {
    String? requestedCallId,
    String? manualResponse,
  }) async {
    final initial = await repo.getClaimById(claimId);
    if (initial == null) {
      return const CardEvolutionFinalizeOutcome('claimMissing');
    }
    if (initial.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('writerNotFailed');
    }
    final active = _inFlight[initial.sessionId];
    if (active != null) return active;
    final future = _recoverWriterUnshared(
      initial,
      requestedCallId: requestedCallId,
      manualResponse: manualResponse,
    );
    _inFlight[initial.sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(initial.sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _recoverWriterUnshared(
    CardEvolutionClaimRow failed, {
    String? requestedCallId,
    String? manualResponse,
  }) async {
    final owner = 'evolution-recovery-${generateId()}';
    final claimed = await repo.claimFailedWriter(
      claimId: failed.id,
      ownerId: owner,
      now: currentTimestampSeconds(),
      leaseSeconds: leaseSeconds,
    );
    final claim = claimed.claim;
    if (!claimed.isClaimed || claim == null) {
      return CardEvolutionFinalizeOutcome(claimed.kind, null, claimed.detail);
    }
    if (requestedCallId != null) {
      final retried = await writerCallRepo.retryFailed(
        id: requestedCallId,
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
      );
      if (!retried) {
        await repo.markWriterFailed(
          claimId: claim.row.id,
          ownerId: owner,
          now: currentTimestampSeconds(),
          code: 'writerCallNotFrontier',
        );
        return const CardEvolutionFinalizeOutcome('writerCallNotFrontier');
      }
    } else {
      final chain = await writerCallRepo.readChain(claim.row.id);
      final frontier = chain
          .where((row) => row.status != 'completed')
          .firstOrNull;
      if (frontier?.status == 'failed') {
        final retried = await writerCallRepo.retryFailed(
          id: frontier!.id,
          claimId: claim.row.id,
          ownerId: owner,
          now: currentTimestampSeconds(),
        );
        if (!retried) {
          await repo.markWriterFailed(
            claimId: claim.row.id,
            ownerId: owner,
            now: currentTimestampSeconds(),
            code: 'writerCallRetryFailed',
          );
          return const CardEvolutionFinalizeOutcome('writerCallRetryFailed');
        }
      }
    }
    return _runClaimedWriter(
      claim,
      owner,
      manualCallId: requestedCallId,
      manualResponse: manualResponse,
    );
  }

  Future<CardEvolutionFinalizeOutcome> correctFailedCollector(
    String collectorRunId, {
    required String response,
  }) => _recoverFailedCollector(collectorRunId, manualResponse: response);

  Future<CardEvolutionFinalizeOutcome> _recoverFailedCollector(
    String collectorRunId, {
    String? manualResponse,
  }) async {
    final initial = await collectorRunRepo.getById(collectorRunId);
    if (initial == null) {
      return const CardEvolutionFinalizeOutcome('collectorNotFound');
    }
    if (initial.status != 'failed') {
      return const CardEvolutionFinalizeOutcome('collectorNotFailed');
    }
    final active = _inFlight[initial.sessionId];
    if (active != null) return active;
    final future = _recoverFailedCollectorUnshared(
      initial,
      manualResponse: manualResponse,
    );
    _inFlight[initial.sessionId] = future;
    return future.whenComplete(() => _inFlight.remove(initial.sessionId));
  }

  Future<CardEvolutionFinalizeOutcome> _recoverFailedCollectorUnshared(
    CardEvolutionCollectorRunRow failed, {
    String? manualResponse,
  }) async {
    final runs = await collectorRunRepo.runsForCollectors(failed.sessionId, [
      failed,
    ]);
    if (runs.length != 2) {
      return const CardEvolutionFinalizeOutcome('collectorEvidenceStale');
    }
    final pair = CardEvolutionCollectorPair(runs.first, runs.last);
    final snapshot = await repo.buildObservationSnapshotForRuns(runs);
    if (snapshot == null ||
        computeHash(snapshot.selectedInputJson) != failed.inputHash) {
      return const CardEvolutionFinalizeOutcome('staleInput');
    }

    String? prompt;
    if (manualResponse == null) {
      final failedCallId = failed.lastCallId;
      if (failedCallId == null) {
        return const CardEvolutionFinalizeOutcome('exactCaptureUnavailable');
      }
      final capture = await requestCaptureRepo.exactPromptForCall(
        callId: failedCallId,
        sessionId: failed.sessionId,
        pipelineRunId: failed.id,
        stage: 'card.collector',
      );
      if (capture == null) {
        return const CardEvolutionFinalizeOutcome('exactCaptureUnavailable');
      }
      prompt = capture.prompt;
    }

    final ownerId = 'collector-recovery-${generateId()}';
    final claim = await collectorRunRepo.claimFailed(
      id: failed.id,
      ownerId: ownerId,
      now: currentTimestampSeconds(),
      leaseSeconds: leaseSeconds,
    );
    if (!claim.canRun || claim.row == null) {
      return CardEvolutionFinalizeOutcome(claim.kind);
    }
    final context = LlmCaptureContext(
      stage: 'card.collector',
      sessionId: failed.sessionId,
      pipelineRunId: failed.id,
      callId: manualResponse == null ? null : 'llm-call-${generateId()}',
      parentCallId: failed.lastCallId,
      logicalCallId:
          '${failed.id}:${manualResponse == null ? 'retry' : 'manual'}',
      relatedArtifactId: failed.id,
      stageOrdinal: failed.collectorOrdinal,
      attempt: manualResponse == null ? null : 1,
    );
    String? output = manualResponse;
    LlmCaptureContext? selectedContext = context;
    var completed = false;
    try {
      if (output == null) {
        final config = await resolveModel();
        final token = CancelToken();
        _tokens['observation-${failed.sessionId}'] = token;
        final outcome = await _executor(
          config: config,
          prompt: prompt!,
          maxTokens: _writerMaxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
          captureContext: context,
        );
        selectedContext = outcome.selectedCaptureContext;
        if (token.isCancelled || !outcome.isOk || outcome.text == null) {
          await collectorRunRepo.markFailed(
            id: failed.id,
            ownerId: ownerId,
            now: currentTimestampSeconds(),
            code: outcome.status.name,
            detail: outcome.lastError?.toString(),
            callId: selectedContext?.callId ?? failed.lastCallId,
          );
          return CardEvolutionFinalizeOutcome(outcome.status.name);
        }
        output = outcome.text;
      }

      final finalized = await _finalizeCollectorOutput(
        sessionId: failed.sessionId,
        snapshot: snapshot,
        runOrdinal: failed.collectorOrdinal,
        pair: pair,
        collectorId: failed.id,
        ownerId: ownerId,
        output: output!,
        captureContext: selectedContext,
        source: manualResponse == null ? 'exact_retry' : 'manual_correction',
      );
      if (!finalized.success) {
        await collectorRunRepo.markFailed(
          id: failed.id,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: finalized.code,
          detail: finalized.detail,
          callId: manualResponse == null
              ? selectedContext?.callId ?? failed.lastCallId
              : failed.lastCallId,
        );
        return CardEvolutionFinalizeOutcome(
          finalized.code,
          null,
          finalized.detail,
        );
      }
      completed = true;
      await _checkPromotions(failed.sessionId);
      return _continueWriterAfterCollectors(failed.sessionId);
    } catch (error) {
      if (!completed) {
        await collectorRunRepo.markFailed(
          id: failed.id,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'unexpectedFailure',
          detail: error.toString(),
          callId: selectedContext?.callId ?? failed.lastCallId,
        );
      }
      return CardEvolutionFinalizeOutcome(
        completed ? 'collectorCompleted' : 'unexpectedFailure',
        null,
        error.toString(),
      );
    } finally {
      _tokens.remove('observation-${failed.sessionId}');
    }
  }

  Future<CardEvolutionFinalizeOutcome> _runAutomatic(
    LedgerReconciliationSuccessfulRunRow reconciliationRun, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    try {
      final pending = await collectorRunRepo.pendingValidPairs(
        reconciliationRun.sessionId,
        currentRun: reconciliationRun,
      );
      for (final pair in pending) {
        final collected = await _runCollector(pair, onStage: onStage);
        if (!collected) {
          return const CardEvolutionFinalizeOutcome('collectorUnavailable');
        }
      }
      return await _continueWriterAfterCollectors(
        reconciliationRun.sessionId,
        onStage: onStage,
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[CardRewriter] automatic lane failed before a durable writer result: '
        '$error\n$stackTrace',
      );
      await _diagnostics.saveSelectionBail(
        sessionId: reconciliationRun.sessionId,
        outcome: 'unexpectedFailure',
        reason: error.toString(),
        throughCollectorOrdinal: 0,
        reconciliationRunIds: [reconciliationRun.id],
      );
      return CardEvolutionFinalizeOutcome(
        'unexpectedFailure',
        null,
        error.toString(),
      );
    }
  }

  Future<CardEvolutionFinalizeOutcome> _continueWriterAfterCollectors(
    String sessionId, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    final delivered = await collectorRunRepo.latestDeliveredWriterBoundary(
      sessionId,
    );
    final dueBoundary = delivered + _writerCollectorBatchSize;
    final latest = await collectorRunRepo.latestCompletedOrdinal(sessionId);
    if (latest < dueBoundary) {
      return const CardEvolutionFinalizeOutcome('collectorCompleted');
    }
    final boundaryRuns = await collectorRunRepo.completedBoundary(
      sessionId,
      dueBoundary,
      count: _writerCollectorBatchSize,
    );
    if (boundaryRuns.length != _writerCollectorBatchSize) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    final reconciliationRuns = await collectorRunRepo.runsForCollectors(
      sessionId,
      boundaryRuns,
    );
    if (reconciliationRuns.length != _writerCollectorBatchSize * 2) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    return _runWriter(
      sessionId,
      onStage: onStage,
      throughCollectorOrdinal: dueBoundary,
      collectorBoundaryHash: boundaryRuns.last.reconciliationChainHash,
      collectorBoundaryRuns: boundaryRuns,
      reconciliationRunIds: [for (final run in reconciliationRuns) run.id],
    );
  }

  Future<CardEvolutionFinalizeOutcome> _runWriter(
    String sessionId, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
    int throughCollectorOrdinal = 0,
    String collectorBoundaryHash = '',
    List<CardEvolutionCollectorRunRow> collectorBoundaryRuns = const [],
    List<String>? reconciliationRunIds,
  }) async {
    onStage?.call(AutomatedCardEvolutionStage.cardRewriter);
    final owner = 'evolution-owner-${generateId()}';
    final now = currentTimestampSeconds();
    final claimed = await repo.claim(
      sessionId: sessionId,
      ownerId: owner,
      now: now,
      leaseSeconds: leaseSeconds,
      throughCollectorOrdinal: throughCollectorOrdinal,
      collectorBoundaryHash: collectorBoundaryHash,
      reconciliationRunIds:
          reconciliationRunIds ??
          [for (final run in collectorBoundaryRuns) run.reconciliationRunId],
      writerOptionsJson: jsonEncode({
        'lorebookEnabled': isLorebookEvolutionEnabled?.call() != false,
      }),
    );
    final claim = claimed.claim;
    if (!claimed.isClaimed || claim == null) {
      await _diagnostics.saveSelectionBail(
        sessionId: sessionId,
        outcome: claimed.kind,
        reason: claimed.detail,
        throughCollectorOrdinal: throughCollectorOrdinal,
        reconciliationRunIds:
            reconciliationRunIds ??
            [for (final run in collectorBoundaryRuns) run.reconciliationRunId],
      );
      return CardEvolutionFinalizeOutcome(claimed.kind, null, claimed.detail);
    }
    return _runClaimedWriter(claim, owner);
  }

  Future<CardEvolutionFinalizeOutcome> _runClaimedWriter(
    CardEvolutionClaim claim,
    String owner, {
    String? manualCallId,
    String? manualResponse,
  }) async {
    final sessionId = claim.row.sessionId;
    final token = CancelToken();
    _tokens[sessionId] = token;
    try {
      final chain = await writerCallRepo.readChain(claim.row.id);
      final snapshotOutcome = await repo.readPromptSnapshotOutcome(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
      );
      final snapshot = snapshotOutcome.snapshot;
      if (snapshot == null) {
        await _discardOrRetainWriter(
          claim,
          owner,
          chain,
          'snapshotUnavailable',
          snapshotOutcome.reason,
        );
        return CardEvolutionFinalizeOutcome(
          'snapshotUnavailable',
          null,
          snapshotOutcome.reason,
        );
      }
      final model = LazyWriterModel(resolveModel);
      var nextOrdinal = 1;
      var chainIndex = 0;
      var parentCallId = chain.isEmpty ? null : chain.first.parentCallId;
      final prepared = await _writerContextConsolidator.prepare(
        claim: claim,
        owner: owner,
        model: model,
        selectedInputJson: snapshot.selectedInputJson,
        cancelToken: token,
        chain: chain,
        chainIndex: chainIndex,
        nextOrdinal: nextOrdinal,
        parentCallId: parentCallId,
        manualCallId: manualCallId,
        manualResponse: manualResponse,
      );
      if (prepared.failure != null) return prepared.failure!;
      var sharedContext = prepared.context!;
      chainIndex = prepared.chainIndex;
      nextOrdinal = prepared.nextOrdinal;
      parentCallId = prepared.parentCallId;
      final operations = <RewriteOperationSnapshot>[];
      final cardOperations = <CardRewriteOperationSnapshot>[];
      final modelOutputs = <String, String>{};
      final allowedCardFields = CardRewritePolicy.nonEmptyEvolutionFields(
        snapshot.character,
      );
      final cardContext = _cardWriterContext(sharedContext);
      if (allowedCardFields.isNotEmpty) {
        final cardPrompt =
            '${CardRewriterPromptBuilder.buildEvolution(character: snapshot.character, instruction: 'Independently evaluate the accumulated observation candidates, the available non-empty card fields, the complete immutable chat evidence or its cumulative factual consolidation, and the current Ledger-backed factual context. Russian evidence may support an English card patch; preserve exact Ledger identities without translation. An active observation alone is an unconfirmed candidate; promoted observations are stronger confirmed evidence. If the supplied immutable chat or Ledger confirms a durable candidate that directly contradicts supplied card text, resolve it with the smallest valid patch regardless of observation status unless no writable field or valid character-boundary-preserving anchor can do so; an empty operations list is not valid for a confirmed, resolvable contradiction. Otherwise return an empty operations list when no candidate is durable enough. Change only the smallest exact fragments and do not invent canon.', accumulatedObservations: _extractAccumulatedObservations(cardContext))}\n\n# Immutable chat history and effective canon\n$cardContext';
        if (cardPrompt.length >
            WriterContextConsolidator.snapshotCharacterLimit) {
          await _discardOrRetainWriter(
            claim,
            owner,
            chain,
            'snapshotTooLarge',
            'Card writer prompt exceeds the safe request limit',
          );
          return _snapshotTooLarge(cardPrompt.length, stage: 'card prompt');
        }
        final card = await _writerCallRunner.runOperationCall(
          claim: claim,
          owner: owner,
          model: model,
          token: token,
          chain: chain,
          chainIndex: chainIndex,
          ordinal: nextOrdinal,
          stage: 'card_writer',
          captureStage: 'card.writer',
          prompt: cardPrompt,
          parentCallId: parentCallId,
          allowedCardFields: allowedCardFields,
          cardContext: cardContext,
          manualCallId: manualCallId,
          manualResponse: manualResponse,
        );
        if (card.failure != null) return card.failure!;
        chainIndex++;
        nextOrdinal++;
        parentCallId = card.call!.lastCallId;
        modelOutputs['card'] = card.call!.responseText!;
        if (card.operations != null) {
          cardOperations.addAll(
            card.operations!.whereType<CardRewriteOperationSnapshot>(),
          );
        } else {
          final repairPrompt = _cardRepairPrompt(
            originalPrompt: cardPrompt,
            failure: card.call!.parserDetail ?? 'invalid output',
            selectedInputJson: cardContext,
          );
          final repair = await _writerCallRunner.runOperationCall(
            claim: claim,
            owner: owner,
            model: model,
            token: token,
            chain: chain,
            chainIndex: chainIndex,
            ordinal: nextOrdinal,
            stage: 'card_repair',
            captureStage: 'card.writer_repair',
            prompt: repairPrompt,
            parentCallId: parentCallId,
            allowedCardFields: allowedCardFields,
            cardContext: cardContext,
            manualCallId: manualCallId,
            manualResponse: manualResponse,
          );
          if (repair.failure != null) return repair.failure!;
          chainIndex++;
          nextOrdinal++;
          parentCallId = repair.call!.lastCallId;
          modelOutputs['card'] = repair.call!.responseText!;
          cardOperations.addAll(
            repair.operations!.whereType<CardRewriteOperationSnapshot>(),
          );
        }
        operations.addAll(cardOperations);
      }
      if (_writerLorebookEnabled(claim.row.writerOptionsJson) &&
          _hasInjectedLoreTargets(sharedContext)) {
        final lorebookPrompt =
            '${CardRewriterPromptBuilder.buildLorebookEvolution(instruction: 'Use the shared card, chat, and Ledger context to keep only the supplied injected lorebook entries current. Prefer the card for character relationships and enduring behavior; prefer lorebook entries for their specific locations, people, objects, or setting facts. Do not duplicate a current or proposed card fact into lorebook. Return a patch whenever the chat supports a durable update that belongs in an injected entry and is not already covered by the card.')}\n\n# Shared immutable context\n$sharedContext\n\n# Proposed card operations (read-only)\n${_cardProposalContext(cardOperations)}';
        if (lorebookPrompt.length >
            WriterContextConsolidator.snapshotCharacterLimit) {
          await _discardOrRetainWriter(
            claim,
            owner,
            chain,
            'snapshotTooLarge',
            'Lorebook writer prompt exceeds the safe request limit',
          );
          return _snapshotTooLarge(
            lorebookPrompt.length,
            stage: 'lorebook prompt',
          );
        }
        final lorebook = await _writerCallRunner.runOperationCall(
          claim: claim,
          owner: owner,
          model: model,
          token: token,
          chain: chain,
          chainIndex: chainIndex,
          ordinal: nextOrdinal,
          stage: 'lorebook_writer',
          captureStage: 'card.lorebook_writer',
          prompt: lorebookPrompt,
          parentCallId: parentCallId,
          cardContext: sharedContext,
          manualCallId: manualCallId,
          manualResponse: manualResponse,
        );
        if (lorebook.failure != null) return lorebook.failure!;
        chainIndex++;
        modelOutputs['lorebook'] = lorebook.call!.responseText!;
        operations.addAll(lorebook.operations!);
      }
      if (chainIndex < chain.length) {
        final failed = await _writerCallRunner.failClosed(
          claim,
          owner,
          'checkpointMismatch',
          'Stored writer chain has an unexpected trailing checkpoint',
        );
        return failed.failure!;
      }
      if (operations.isEmpty) {
        if (claim.row.predecessorRunOrdinal > 0) {
          await repo.completeEmptyClaim(
            claimId: claim.row.id,
            ownerId: owner,
            now: currentTimestampSeconds(),
          );
        } else {
          await repo.abandonClaim(claimId: claim.row.id, ownerId: owner);
        }
        return const CardEvolutionFinalizeOutcome(
          'emptyModelProposal',
          null,
          'Every enabled writer returned an empty operations list. Check the saved card/lorebook debug responses.',
        );
      }
      final finalized = await repo.finalize(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        modelOutput: jsonEncode(modelOutputs),
        operations: operations,
      );
      if (!finalized.isPersisted) {
        await _writerCallRunner.markWriterFailure(
          claim,
          owner,
          finalized.kind,
          finalized.detail,
        );
      }
      return finalized;
    } on CardRewriteModelNotConfigured catch (error) {
      await _writerCallRunner.markWriterFailure(
        claim,
        owner,
        'modelNotConfigured',
        error.toString(),
      );
      return const CardEvolutionFinalizeOutcome('modelNotConfigured');
    } catch (error) {
      await _writerCallRunner.markWriterFailure(
        claim,
        owner,
        'unexpectedFailure',
        error.toString(),
      );
      return CardEvolutionFinalizeOutcome(
        'unexpectedFailure',
        null,
        error.toString(),
      );
    } finally {
      if (identical(_tokens[sessionId], token)) _tokens.remove(sessionId);
    }
  }

  static bool _writerLorebookEnabled(String optionsJson) {
    try {
      final options = jsonDecode(optionsJson);
      return options is! Map || options['lorebookEnabled'] != false;
    } catch (_) {
      return true;
    }
  }

  Future<void> _discardOrRetainWriter(
    CardEvolutionClaim claim,
    String owner,
    List<CardEvolutionWriterCallRow> chain,
    String code,
    String? detail,
  ) => chain.isEmpty
      ? repo.abandonClaim(claimId: claim.row.id, ownerId: owner)
      : _writerCallRunner.markWriterFailure(claim, owner, code, detail);

  void cancelSession(String sessionId) {
    _tokens['observation-$sessionId']?.cancel('generationAborted');
    _tokens[sessionId]?.cancel('generationAborted');
  }

  void dispose() {
    for (final token in _tokens.values) {
      token.cancel('serviceDisposed');
    }
    _tokens.clear();
  }

  static bool _hasInjectedLoreTargets(String selectedInputJson) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final entries = input['injectedLorebookEntries'];
      return entries is List && entries.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _runCollector(
    CardEvolutionCollectorPair pair, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    final reconciliationRun = pair.boundary;
    final sessionId = reconciliationRun.sessionId;
    String? claimId;
    String? ownerId;
    try {
      final snapshot = await repo.buildObservationSnapshotForRuns(pair.runs);
      if (snapshot == null) return false;
      ownerId = 'collector-owner-${generateId()}';
      final now = currentTimestampSeconds();
      final claim = await collectorRunRepo.claim(
        reconciliationRun: reconciliationRun,
        characterId: snapshot.character.id,
        inputHash: computeHash(snapshot.selectedInputJson),
        ownerId: ownerId,
        now: now,
        leaseSeconds: leaseSeconds,
        rangeHash: pair.rangeHash,
      );
      if (claim.kind == 'completed') return true;
      if (!claim.canRun || claim.row == null) return false;
      claimId = claim.row!.id;
      onStage?.call(AutomatedCardEvolutionStage.observation);
      final output = await _runObservationPass(
        sessionId,
        snapshot,
        claim.row!.collectorOrdinal,
        pipelineRunId: claim.row!.id,
        onFailure: ({required code, detail, callId}) async {
          await collectorRunRepo.markFailed(
            id: claimId!,
            ownerId: ownerId!,
            now: currentTimestampSeconds(),
            code: code,
            detail: detail,
            callId: callId,
          );
        },
        finalize: (output, applyEffects) =>
            collectorRunRepo.completeWithEffects(
              id: claimId!,
              ownerId: ownerId!,
              modelOutputHash: computeHash(output),
              now: currentTimestampSeconds(),
              validateEvidence: () async {
                final logical = await collectorRunRepo.runsForCollectors(
                  sessionId,
                  [claim.row!],
                );
                return logical.length == 2 &&
                    logical[0].id == pair.first.id &&
                    logical[1].id == pair.boundary.id;
              },
              applyEffects: applyEffects,
            ),
      );
      if (output == null) {
        await collectorRunRepo.markFailed(
          id: claimId,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'collectorFailed',
          detail: 'Collector did not produce a valid response',
        );
        return false;
      }
      await _checkPromotions(sessionId);
      claimId = null;
      return true;
    } catch (error) {
      if (claimId != null && ownerId != null) {
        await collectorRunRepo.markFailed(
          id: claimId,
          ownerId: ownerId,
          now: currentTimestampSeconds(),
          code: 'unexpectedFailure',
          detail: error.toString(),
        );
      }
      return false;
    } finally {
      if (claimId != null && ownerId != null) {
        await collectorRunRepo.abandon(id: claimId, ownerId: ownerId);
      }
    }
  }

  Future<String?> _runObservationPass(
    String sessionId,
    CardEvolutionObservationSnapshot snapshot,
    int runOrdinal, {
    String? pipelineRunId,
    Future<void> Function({
      required String code,
      String? detail,
      String? callId,
    })?
    onFailure,
    Future<bool> Function(String output, Future<void> Function() applyEffects)?
    finalize,
  }) async {
    final config = await resolveModel();
    final activeMaps = _extractAccumulatedObservations(
      snapshot.selectedInputJson,
    ).where((observation) => observation['status'] == 'active').toList();
    final prompt =
        '${CardRewriterPromptBuilder.buildObservationPass(character: snapshot.character, activeObservations: activeMaps, instruction: 'Review the last 40 immutable chat messages and the current Ledger-backed canon below. For each active observation, decide whether the chat history still supports it. Identify any new repeatedly demonstrated shift in preference, attitude, relationship dynamics, or lasting character development. Do not record one-off events or temporary state. Be conservative.')}\n\n# Immutable chat history and effective canon\n${_collectorContext(snapshot.selectedInputJson)}';
    final token = CancelToken();
    _tokens['observation-$sessionId'] = token;
    try {
      if (token.isCancelled) return null;
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: _writerMaxTokens,
        temperature: 0.2,
        timeoutMs: timeoutMs,
        cancelToken: token,
        captureContext: LlmCaptureContext(
          stage: 'card.collector',
          sessionId: sessionId,
          pipelineRunId: pipelineRunId ?? 'collector:$runOrdinal',
          logicalCallId: pipelineRunId ?? 'collector:$runOrdinal',
          relatedArtifactId: pipelineRunId,
          stageOrdinal: runOrdinal,
        ),
      );
      if (token.isCancelled ||
          outcome.status == AgentOperationStatus.aborted ||
          !outcome.isOk ||
          outcome.text == null) {
        await onFailure?.call(
          code: outcome.status.name,
          detail: outcome.lastError?.toString(),
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final actions = _observationResponseParser.parse(outcome.text!);
      if (actions == null) {
        await _diagnostics.recordCollectorParserVerdict(
          context: outcome.selectedCaptureContext,
          accepted: false,
          code: 'invalidOutput',
          detail: 'Collector response is not valid JSON',
          source: 'model',
        );
        await onFailure?.call(
          code: 'parserRejected',
          detail: 'Collector response is not valid JSON',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final validEvidenceIds = _chatMessageIds(snapshot.selectedInputJson);
      if (validEvidenceIds == null) {
        await onFailure?.call(
          code: 'invalidSelectedInput',
          detail: 'Collector input has no valid immutable chat history',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      final retrievalTargets = _retrievalTargets(snapshot.selectedInputJson);
      if (retrievalTargets == null) {
        await onFailure?.call(
          code: 'invalidSelectedInput',
          detail: 'Collector input has no valid retrieval targets',
          callId: outcome.selectedCaptureContext?.callId,
        );
        return null;
      }
      await _diagnostics.recordCollectorParserVerdict(
        context: outcome.selectedCaptureContext,
        accepted: true,
        code: 'accepted',
        source: 'model',
      );
      Future<void> applyEffects() async {
        await _applyCollectorActions(
          sessionId: sessionId,
          snapshot: snapshot,
          runOrdinal: runOrdinal,
          actions: actions,
          validEvidenceIds: validEvidenceIds,
          retrievalTargets: retrievalTargets,
        );
      }

      if (finalize != null) {
        if (!await finalize(outcome.text!, applyEffects)) return null;
      } else {
        await applyEffects();
      }
      return outcome.text;
    } finally {
      if (identical(_tokens['observation-$sessionId'], token)) {
        _tokens.remove('observation-$sessionId');
      }
    }
  }

  Future<_CollectorFinalizeResult> _finalizeCollectorOutput({
    required String sessionId,
    required CardEvolutionObservationSnapshot snapshot,
    required int runOrdinal,
    required CardEvolutionCollectorPair pair,
    required String collectorId,
    required String ownerId,
    required String output,
    required LlmCaptureContext? captureContext,
    required String source,
  }) async {
    final actions = _observationResponseParser.parse(output);
    if (actions == null) {
      await _diagnostics.recordCollectorParserVerdict(
        context: captureContext,
        accepted: false,
        code: 'invalidOutput',
        detail: 'Collector response is not valid JSON',
        responseText: source == 'manual_correction' ? output : null,
        source: source,
      );
      return const _CollectorFinalizeResult.failure(
        'parserRejected',
        'Collector response is not valid JSON',
      );
    }
    final validEvidenceIds = _chatMessageIds(snapshot.selectedInputJson);
    final retrievalTargets = _retrievalTargets(snapshot.selectedInputJson);
    if (validEvidenceIds == null || retrievalTargets == null) {
      return const _CollectorFinalizeResult.failure(
        'invalidSelectedInput',
        'Collector input cannot be validated',
      );
    }
    await _diagnostics.recordCollectorParserVerdict(
      context: captureContext,
      accepted: true,
      code: 'accepted',
      responseText: source == 'manual_correction' ? output : null,
      source: source,
    );
    final completed = await collectorRunRepo.completeWithEffects(
      id: collectorId,
      ownerId: ownerId,
      modelOutputHash: computeHash(output),
      now: currentTimestampSeconds(),
      lastCallId: captureContext?.callId,
      validateEvidence: () async {
        final collector = await collectorRunRepo.getById(collectorId);
        if (collector == null) return false;
        final logical = await collectorRunRepo.runsForCollectors(sessionId, [
          collector,
        ]);
        if (logical.length != 2 ||
            logical[0].id != pair.first.id ||
            logical[1].id != pair.boundary.id) {
          return false;
        }
        final currentSnapshot = await repo.buildObservationSnapshotForRuns(
          logical,
        );
        return currentSnapshot != null &&
            computeHash(currentSnapshot.selectedInputJson) ==
                collector.inputHash &&
            collector.inputHash == computeHash(snapshot.selectedInputJson);
      },
      applyEffects: () => _applyCollectorActions(
        sessionId: sessionId,
        snapshot: snapshot,
        runOrdinal: runOrdinal,
        actions: actions,
        validEvidenceIds: validEvidenceIds,
        retrievalTargets: retrievalTargets,
      ),
    );
    return completed
        ? const _CollectorFinalizeResult.success()
        : const _CollectorFinalizeResult.failure(
            'collectorEvidenceStale',
            'Collector lease or reconciliation evidence changed',
          );
  }

  Future<void> _applyCollectorActions({
    required String sessionId,
    required CardEvolutionObservationSnapshot snapshot,
    required int runOrdinal,
    required List<ParsedObservationAction> actions,
    required Set<String> validEvidenceIds,
    required Map<String, String> retrievalTargets,
  }) async {
    final now = currentTimestampSeconds();
    for (final action in actions) {
      if (!validEvidenceIds.containsAll(action.evidenceMessageIds)) continue;
      if (!retrievalTargets.keys.toSet().containsAll(action.retrievalKeys)) {
        continue;
      }
      final loreIdentity = action.lorebookEntryId;
      final hasExactLoreTarget =
          loreIdentity != null &&
          action.retrievalKeys.contains(loreIdentity) &&
          retrievalTargets[loreIdentity] == 'injected_lorebook_entry';
      if ((action.targetKind == 'injected_lorebook_entry' &&
              !hasExactLoreTarget) ||
          (action.targetKind == 'main_character_card' &&
              (loreIdentity != null ||
                  action.retrievalKeys.any(
                    (key) => retrievalTargets[key] == 'injected_lorebook_entry',
                  )))) {
        continue;
      }
      await _applyObservationAction(
        sessionId: sessionId,
        characterId: snapshot.character.id,
        runOrdinal: runOrdinal,
        now: now,
        action: action,
      );
    }
    await observationRepo.expireUnconfirmed(
      sessionId: sessionId,
      currentRunOrdinal: runOrdinal,
      maxUnconfirmedRuns: observationExpiryRuns?.call() ?? 4,
      now: now,
    );
  }

  Future<void> _applyObservationAction({
    required String sessionId,
    required String characterId,
    required int runOrdinal,
    required int now,
    required ParsedObservationAction action,
  }) async {
    switch (action.action) {
      case 'confirm':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing != null &&
            existing.status == 'active' &&
            (existing.targetKind == null ||
                existing.targetKind == action.targetKind) &&
            existing.lorebookEntryId == action.lorebookEntryId) {
          await observationRepo.confirmObservation(
            id: existing.id,
            runOrdinal: runOrdinal,
            confidence: action.confidence,
            now: now,
            evidenceMessageIds: action.evidenceMessageIds,
            retrievalKeys: action.retrievalKeys,
            targetKind: action.targetKind,
          );
        }
        break;
      case 'new':
        await observationRepo.insertOrReactivate(
          CardEvolutionObservation(
            id: 'observation-${generateId()}',
            sessionId: sessionId,
            characterId: characterId,
            runOrdinal: runOrdinal,
            semanticScopeKey: action.scopeKey,
            observedChange: action.observedChange,
            canonicalClaim: action.canonicalClaim,
            evidenceClusters: [action.evidenceMessageIds],
            retrievalKeys: action.retrievalKeys,
            targetKind: action.targetKind,
            cardFieldPath: action.cardFieldPath,
            lorebookEntryId: action.lorebookEntryId,
            confidence: action.confidence,
            status: 'active',
            firstSeenRun: runOrdinal,
            lastConfirmedRun: runOrdinal,
            createdAt: now,
            updatedAt: now,
          ),
        );
        break;
      case 'no_evidence':
        break;
      case 'contradict':
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing != null && existing.status == 'active') {
          await observationRepo.contradictObservation(existing.id, now: now);
        }
        break;
    }
  }

  Future<void> _checkPromotions(String sessionId) async {
    final now = currentTimestampSeconds();
    final threshold = observationPromotionThreshold?.call() ?? 3;
    final minConfidence = observationMinConfidence?.call() ?? 0.7;
    final promotable = await observationRepo.getPromotableObservations(
      sessionId,
      minRepeatCount: threshold,
      minConfidence: minConfidence,
    );
    for (final obs in promotable) {
      await observationRepo.promoteObservation(obs.id, now: now);
    }
  }

  static Set<String>? _chatMessageIds(String selectedInputJson) {
    try {
      final decoded = jsonDecode(selectedInputJson);
      if (decoded is! Map || decoded['chatHistory'] is! List) return null;
      final result = <String>{};
      for (final message in decoded['chatHistory'] as List) {
        if (message is! Map || message['messageId'] is! String) return null;
        result.add(message['messageId'] as String);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static Map<String, String>? _retrievalTargets(String selectedInputJson) {
    try {
      final decoded = jsonDecode(selectedInputJson);
      if (decoded is! Map ||
          decoded['availableObservationRetrievalTargets'] is! List) {
        return null;
      }
      final result = <String, String>{};
      for (final target
          in decoded['availableObservationRetrievalTargets'] as List) {
        if (target is! Map ||
            target['key'] is! String ||
            target['kind'] is! String) {
          return null;
        }
        result[target['key'] as String] = target['kind'] as String;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static List<Map<String, Object?>> _extractAccumulatedObservations(
    String selectedInputJson,
  ) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final targets = input['accumulatedObservations'];
      if (targets is! List) return const [];
      return [
        for (final target in targets)
          if (target is Map<String, Object?>) target,
      ];
    } catch (_) {
      return const [];
    }
  }

  static CardEvolutionFinalizeOutcome _snapshotTooLarge(
    int actual, {
    String stage = 'snapshot',
    int limit = WriterContextConsolidator.snapshotCharacterLimit,
  }) => CardEvolutionFinalizeOutcome(
    'snapshotTooLarge',
    null,
    'Card Rewriter $stage is $actual characters; the safe request limit is '
        '$limit.',
  );

  static String _cardWriterContext(String selectedInputJson) {
    try {
      final input = Map<String, Object?>.from(
        jsonDecode(selectedInputJson) as Map,
      )..remove('card');
      final observations = input['accumulatedObservations'];
      input['accumulatedObservations'] = observations is List
          ? [
              for (final value in observations)
                if (value is Map &&
                    value['targetKind'] != 'injected_lorebook_entry')
                  value,
            ]
          : const [];
      return jsonEncode(input);
    } catch (_) {
      return selectedInputJson;
    }
  }

  static String _collectorContext(String selectedInputJson) {
    try {
      final decoded = Map<String, Object?>.from(
        jsonDecode(selectedInputJson) as Map,
      )..remove('card');
      return jsonEncode(decoded);
    } catch (_) {
      return selectedInputJson;
    }
  }

  static String _cardProposalContext(
    List<CardRewriteOperationSnapshot> operations,
  ) => jsonEncode([
    for (final operation in operations)
      jsonDecode(ManualRewriteOperationSnapshotCodec.encode(operation)),
  ]);

  static String _cardRepairPrompt({
    required String originalPrompt,
    required String failure,
    required String selectedInputJson,
  }) {
    final allowed =
        (_retrievalTargets(selectedInputJson)?.keys ?? const [])
            .where(_isCardScopeTarget)
            .toList()
          ..sort();
    final scopeCorrection = allowed.isEmpty
        ? 'Every patch and transition scopeKey MUST follow the advertised scope '
              'grammar exactly.'
        : 'Every patch and transition scopeKey MUST equal one of these exact '
              'available keys: ${jsonEncode(allowed)}. Do not shorten, combine, '
              'translate, or derive a scope key.';
    return '$originalPrompt\n\n'
        '# Required correction\n'
        'Your previous response was rejected: $failure. Return a fresh complete '
        'response containing exactly one valid JSON object with no prose before '
        'or after it. $scopeCorrection Every replacement value MUST preserve '
        'the exact macro-token multiset from its anchor. Never add, remove, rename, '
        'or substitute tokens such as {{user}}.';
  }

  static bool _isCardScopeTarget(String key) =>
      !key.contains('/') && CardRewriteScope.tryParse(key) != null;
}

final class _CollectorFinalizeResult {
  const _CollectorFinalizeResult.success()
    : success = true,
      code = 'completed',
      detail = null;

  const _CollectorFinalizeResult.failure(this.code, this.detail)
    : success = false;

  final bool success;
  final String code;
  final String? detail;
}

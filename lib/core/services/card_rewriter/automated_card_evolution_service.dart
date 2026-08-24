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
import '../../llm/aux_retry_runner.dart';
import '../../llm/aux_llm_client.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../llm/transport/llm_call_event.dart';
import '../../models/agent_operation_record.dart';
import '../../models/card_evolution_observation.dart';
import '../../utils/id_generator.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/time_helpers.dart';
import 'card_rewrite_operation_parser.dart';
import 'card_rewrite_prompt_builder.dart';
import 'card_rewriter_contracts.dart';
import 'manual_rewrite_service.dart';

const _writerMaxTokens = 40000;
const _writerLeaseSeconds = 600;
const _writerCollectorBatchSize = 2;
const _writerSnapshotCharacterLimit = 600000;
const _writerContextCharacterLimit = 180000;
const _historyConsolidationInstruction =
    'Consolidate this next immutable Card Rewriter evidence segment into a '
    'compact cumulative factual handoff. Preserve all durable character '
    'changes, relationship developments, exact identities, supporting message '
    'IDs, and contradictions from both the prior handoff and this segment. Do '
    'not propose or apply card patches. Do not invent facts.';

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
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  }) : observationRepo =
           observationRepo ?? CardEvolutionObservationRepo(repo.db),
       collectorRunRepo =
           collectorRunRepo ?? CardEvolutionCollectorRunRepo(repo.db),
       writerCallRepo = writerCallRepo ?? CardEvolutionWriterCallRepo(repo.db),
       requestCaptureRepo =
           requestCaptureRepo ?? LlmRequestCaptureRepo(repo.db);

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
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
    return _continueWriterAfterCollectors(
      reconciliationRun.sessionId,
      onStage: onStage,
    );
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
      await _saveSelectionBail(
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
      final model = _LazyWriterModel(resolveModel);
      var nextOrdinal = 1;
      var chainIndex = 0;
      var parentCallId = chain.isEmpty ? null : chain.first.parentCallId;
      final prepared = await _prepareDurableWriterContext(
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
        if (cardPrompt.length > _writerSnapshotCharacterLimit) {
          await _discardOrRetainWriter(
            claim,
            owner,
            chain,
            'snapshotTooLarge',
            'Card writer prompt exceeds the safe request limit',
          );
          return _snapshotTooLarge(cardPrompt.length, stage: 'card prompt');
        }
        final card = await _runDurableOperationCall(
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
          final repair = await _runDurableOperationCall(
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
        if (lorebookPrompt.length > _writerSnapshotCharacterLimit) {
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
        final lorebook = await _runDurableOperationCall(
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
        final failed = await _failClosed(
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
        await _markWriterFailure(
          claim,
          owner,
          finalized.kind,
          finalized.detail,
        );
      }
      return finalized;
    } on CardRewriteModelNotConfigured catch (error) {
      await _markWriterFailure(
        claim,
        owner,
        'modelNotConfigured',
        error.toString(),
      );
      return const CardEvolutionFinalizeOutcome('modelNotConfigured');
    } catch (error) {
      await _markWriterFailure(
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
      : _markWriterFailure(claim, owner, code, detail);

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
      final actions = _parseObservationResponse(outcome.text!);
      if (actions == null) {
        await _recordCollectorParserVerdict(
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
      await _recordCollectorParserVerdict(
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
    final actions = _parseObservationResponse(output);
    if (actions == null) {
      await _recordCollectorParserVerdict(
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
    await _recordCollectorParserVerdict(
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
    required List<_ParsedObservationAction> actions,
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

  static Future<void> _recordCollectorParserVerdict({
    required LlmCaptureContext? context,
    required bool accepted,
    required String code,
    required String source,
    String? detail,
    String? responseText,
  }) {
    if (context?.callId == null || context?.pipelineRunId == null) {
      return Future<void>.value();
    }
    return LlmCallEventCapture.record(
      LlmCallEvent.parserVerdict(
        context: context!,
        parserName: 'AutomatedCardEvolutionService.collectorResponse',
        accepted: accepted,
        code: code,
        detail: detail,
        responseText: responseText,
        payload: {'source': source},
      ),
    );
  }

  Future<void> _applyObservationAction({
    required String sessionId,
    required String characterId,
    required int runOrdinal,
    required int now,
    required _ParsedObservationAction action,
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

  Future<_PreparedWriterContext> _prepareDurableWriterContext({
    required CardEvolutionClaim claim,
    required String owner,
    required _LazyWriterModel model,
    required String selectedInputJson,
    required CancelToken cancelToken,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int nextOrdinal,
    required String? parentCallId,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    if (selectedInputJson.length <= _writerContextCharacterLimit) {
      return _PreparedWriterContext.context(
        selectedInputJson,
        chainIndex: chainIndex,
        nextOrdinal: nextOrdinal,
        parentCallId: parentCallId,
      );
    }
    Map<String, dynamic> decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(selectedInputJson) as Map);
    } catch (_) {
      await _discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Stored writer input cannot be decoded for consolidation',
      );
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(selectedInputJson.length),
      );
    }
    final history = decoded['chatHistory'];
    if (history is! List) {
      await _discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Stored writer input has no valid chat history',
      );
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(selectedInputJson.length),
      );
    }
    final common = Map<String, dynamic>.from(decoded)
      ..remove('writerCollectorMessageIds')
      ..remove('chatHistory');
    if (jsonEncode(common).length > _writerContextCharacterLimit) {
      await _discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Shared writer context exceeds the safe request limit',
      );
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(jsonEncode(common).length, stage: 'shared context'),
      );
    }
    String? handoff;
    var offset = 0;
    var stageOrdinal = 1;
    while (offset < history.length) {
      final chunk = <Object?>[];
      String? prompt;
      while (offset + chunk.length < history.length) {
        final candidate = [...chunk, history[offset + chunk.length]];
        final candidatePrompt = _historyConsolidationPrompt(
          common: common,
          priorHandoff: handoff,
          history: candidate,
        );
        if (candidatePrompt.length > _writerSnapshotCharacterLimit) break;
        chunk.add(history[offset + chunk.length]);
        prompt = candidatePrompt;
      }
      if (chunk.isEmpty || prompt == null) {
        await _discardOrRetainWriter(
          claim,
          owner,
          chain,
          'snapshotTooLarge',
          'A history consolidation chunk exceeds the safe request limit',
        );
        return _PreparedWriterContext.failure(
          _snapshotTooLarge(
            _historyConsolidationPrompt(
              common: common,
              priorHandoff: handoff,
              history: [history[offset]],
            ).length,
            stage: 'history message ${offset + 1}',
          ),
        );
      }
      final call = await _runDurableTextCall(
        claim: claim,
        owner: owner,
        model: model,
        token: cancelToken,
        chain: chain,
        chainIndex: chainIndex,
        ordinal: nextOrdinal,
        stage: 'history_consolidation',
        stageOrdinal: stageOrdinal,
        captureStage: 'card.history_consolidation',
        prompt: prompt,
        parentCallId: parentCallId,
        manualCallId: manualCallId,
        manualResponse: manualResponse,
      );
      if (call.failure != null) {
        return _PreparedWriterContext.failure(call.failure!);
      }
      handoff = call.call!.responseText;
      parentCallId = call.call!.lastCallId;
      offset += chunk.length;
      chainIndex++;
      nextOrdinal++;
      stageOrdinal++;
    }
    final context = jsonEncode({
      ...common,
      'chatHistory': const <Object?>[],
      'completeHistoryConsolidation': handoff,
    });
    if (context.length > _writerContextCharacterLimit) {
      await _discardOrRetainWriter(
        claim,
        owner,
        chain,
        'snapshotTooLarge',
        'Final consolidated writer context exceeds the safe request limit',
      );
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(context.length, stage: 'final writer context'),
      );
    }
    return _PreparedWriterContext.context(
      context,
      chainIndex: chainIndex,
      nextOrdinal: nextOrdinal,
      parentCallId: parentCallId,
    );
  }

  Future<_DurableCallResult> _runDurableTextCall({
    required CardEvolutionClaim claim,
    required String owner,
    required _LazyWriterModel model,
    required CancelToken token,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required int stageOrdinal,
    required String captureStage,
    required String prompt,
    required String? parentCallId,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    final prepared = await _prepareCall(
      claim: claim,
      owner: owner,
      chain: chain,
      chainIndex: chainIndex,
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: stageOrdinal,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    if (prepared.failure != null || prepared.call!.status == 'completed') {
      return prepared;
    }
    return _executePreparedCall(
      claim: claim,
      owner: owner,
      model: model,
      token: token,
      call: prepared.call!,
      captureStage: captureStage,
      manualResponse: manualCallId == prepared.call!.id ? manualResponse : null,
      parse: (response) =>
          _ParsedCallResult.accepted(jsonEncode({'handoff': response})),
    );
  }

  Future<_DurableCallResult> _runDurableOperationCall({
    required CardEvolutionClaim claim,
    required String owner,
    required _LazyWriterModel model,
    required CancelToken token,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required String captureStage,
    required String prompt,
    required String? parentCallId,
    required String cardContext,
    Set<CardRewriteField>? allowedCardFields,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    final prepared = await _prepareCall(
      claim: claim,
      owner: owner,
      chain: chain,
      chainIndex: chainIndex,
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: 1,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    if (prepared.failure != null) return prepared;
    if (prepared.call!.status == 'completed') {
      final decoded = _decodeOperations(prepared.call!.resultJson);
      if (prepared.call!.parserCode == 'invalidOutput' &&
          stage == 'card_writer') {
        return _DurableCallResult.completed(prepared.call!);
      }
      if (decoded == null) {
        return _failClosed(
          claim,
          owner,
          'checkpointMalformed',
          'Stored $stage resultJson is malformed',
        );
      }
      return _DurableCallResult.completed(prepared.call!, decoded);
    }
    return _executePreparedCall(
      claim: claim,
      owner: owner,
      model: model,
      token: token,
      call: prepared.call!,
      captureStage: captureStage,
      manualResponse: manualCallId == prepared.call!.id ? manualResponse : null,
      completeRejected: stage == 'card_writer',
      parse: (response) {
        final parsed = allowedCardFields == null
            ? CardRewriteOperationParser.parseLorebookEvolutionBatch(response)
            : CardRewriteOperationParser.parseEvolutionBatch(
                response,
                allowedFields: allowedCardFields,
              );
        final detail = parsed == null
            ? allowedCardFields == null
                  ? 'Lorebook response is not a valid operation batch'
                  : CardRewriteOperationParser.explainEvolutionBatchFailure(
                      response,
                      allowedFields: allowedCardFields,
                    )
            : allowedCardFields == null
            ? null
            : _scopeAllowlistFailure(
                parsed.whereType<CardRewriteOperationSnapshot>().toList(),
                cardContext,
              );
        if (parsed == null || detail != null) {
          return _ParsedCallResult.rejected(detail ?? 'invalid output');
        }
        return _ParsedCallResult.accepted(_encodeOperations(parsed), parsed);
      },
    );
  }

  Future<_DurableCallResult> _prepareCall({
    required CardEvolutionClaim claim,
    required String owner,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required int stageOrdinal,
    required String prompt,
    required String? parentCallId,
  }) async {
    final outcome = await writerCallRepo.prepareNextCall(
      claimId: claim.row.id,
      ownerId: owner,
      now: currentTimestampSeconds(),
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: stageOrdinal,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    final call = outcome.row;
    if (call == null) {
      return _failClosed(
        claim,
        owner,
        outcome.kind,
        'Unable to prepare $stage',
      );
    }
    if (call.ordinal != ordinal ||
        call.stage != stage ||
        call.stageOrdinal != stageOrdinal ||
        call.promptHash != computeHash(prompt) ||
        call.prompt != prompt ||
        chainIndex < chain.length && chain[chainIndex].id != call.id) {
      return _failClosed(
        claim,
        owner,
        'checkpointMismatch',
        'Stored writer checkpoint does not match recomputed $stage request',
      );
    }
    if (call.status == 'failed') {
      return _failClosed(
        claim,
        owner,
        'writerCallFailed',
        'Writer checkpoint ${call.id} requires explicit recovery',
      );
    }
    return _DurableCallResult.completed(call);
  }

  Future<_DurableCallResult> _executePreparedCall({
    required CardEvolutionClaim claim,
    required String owner,
    required _LazyWriterModel model,
    required CancelToken token,
    required CardEvolutionWriterCallRow call,
    required String captureStage,
    required _ParsedCallResult Function(String response) parse,
    String? manualResponse,
    bool completeRejected = false,
  }) async {
    final now = currentTimestampSeconds();
    if (!await repo.renewClaimLease(
      claimId: claim.row.id,
      ownerId: owner,
      now: now,
      leaseSeconds: leaseSeconds,
    )) {
      await _markWriterFailure(
        claim,
        owner,
        'leaseLost',
        'Writer lease could not be renewed before ${call.stage}',
      );
      return const _DurableCallResult.failure(
        CardEvolutionFinalizeOutcome('leaseLost'),
      );
    }
    final context = LlmCaptureContext(
      stage: captureStage,
      sessionId: claim.row.sessionId,
      pipelineRunId: claim.row.id,
      callId: manualResponse == null ? null : 'llm-call-${generateId()}',
      parentCallId: call.lastCallId ?? call.parentCallId ?? call.id,
      logicalCallId: '${claim.row.id}:${call.stage}:${call.stageOrdinal}',
      relatedArtifactId: claim.row.id,
      stageOrdinal: call.stageOrdinal,
    );
    AuxCallOutcome? outcome;
    final config = manualResponse == null ? await model.resolve() : null;
    final response =
        manualResponse ??
        (outcome = await _executor(
          config: config!,
          prompt: call.prompt,
          maxTokens: _writerMaxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
          captureContext: context,
        )).text;
    if (manualResponse == null) {
      final modelOutcome = outcome!;
      if (token.isCancelled ||
          modelOutcome.status == AgentOperationStatus.aborted ||
          !modelOutcome.isOk ||
          response == null) {
        final code = token.isCancelled
            ? 'cancelled'
            : '${call.stage}ModelFailed';
        final detail = _modelFailureDetail(modelOutcome);
        await writerCallRepo.failCall(
          id: call.id,
          claimId: claim.row.id,
          ownerId: owner,
          now: currentTimestampSeconds(),
          code: code,
          detail: detail,
          lastCallId: modelOutcome.selectedCaptureContext?.callId ?? call.id,
        );
        await _saveDebugOutcome(
          sessionId: claim.row.sessionId,
          stage: call.stage == 'lorebook_writer' ? 'lorebook' : 'card',
          model: config!.model,
          outcome: modelOutcome,
        );
        await _markWriterFailure(claim, owner, code, detail);
        return _DurableCallResult.failure(
          CardEvolutionFinalizeOutcome(
            token.isCancelled ? 'cancelled' : _publicModelFailure(call.stage),
            null,
            detail,
          ),
        );
      }
    }
    final responseText = response!;
    final parserContext = outcome?.selectedCaptureContext ?? context;
    final parsed = parse(responseText);
    await _recordWriterParserVerdict(
      context: parserContext,
      accepted: parsed.accepted,
      detail: parsed.detail,
      responseText: manualResponse == null ? null : responseText,
      source: manualResponse != null
          ? 'manual_correction'
          : call.source == 'exact_retry'
          ? 'exact_retry'
          : 'model',
    );
    if (!parsed.accepted && (!completeRejected || manualResponse != null)) {
      await writerCallRepo.failCall(
        id: call.id,
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        code: 'parserRejected',
        detail: parsed.detail,
        lastCallId: parserContext.callId,
        responseText: responseText,
        parserCode: 'invalidOutput',
        parserDetail: parsed.detail,
      );
      await _markWriterFailure(claim, owner, 'parserRejected', parsed.detail);
      return _DurableCallResult.failure(
        CardEvolutionFinalizeOutcome(
          call.stage == 'lorebook_writer'
              ? 'invalidLorebookOutput'
              : 'invalidCardOutput',
          null,
          parsed.detail,
        ),
      );
    }
    final completed = await writerCallRepo.completeCall(
      id: call.id,
      claimId: claim.row.id,
      ownerId: owner,
      now: currentTimestampSeconds(),
      responseText: responseText,
      resultJson: parsed.resultJson ?? jsonEncode({'rejected': parsed.detail}),
      source: manualResponse != null
          ? 'manual_correction'
          : call.source == 'exact_retry'
          ? 'exact_retry'
          : 'model',
      parserCode: parsed.accepted ? 'accepted' : 'invalidOutput',
      parserDetail: parsed.detail,
      lastCallId: parserContext.callId,
    );
    if (!completed) {
      return _failClosed(
        claim,
        owner,
        'leaseLost',
        'Call completion lost ownership',
      );
    }
    if (outcome != null) {
      await _saveDebugOutcome(
        sessionId: claim.row.sessionId,
        stage: call.stage == 'lorebook_writer' ? 'lorebook' : 'card',
        model: config!.model,
        outcome: outcome,
      );
    }
    final stored = await writerCallRepo.getById(call.id);
    return _DurableCallResult.completed(stored!, parsed.operations);
  }

  Future<_DurableCallResult> _failClosed(
    CardEvolutionClaim claim,
    String owner,
    String code,
    String detail,
  ) async {
    await _markWriterFailure(claim, owner, code, detail);
    return _DurableCallResult.failure(
      CardEvolutionFinalizeOutcome(code, null, detail),
    );
  }

  Future<void> _markWriterFailure(
    CardEvolutionClaim claim,
    String owner,
    String code,
    String? detail,
  ) => repo.markWriterFailed(
    claimId: claim.row.id,
    ownerId: owner,
    now: currentTimestampSeconds(),
    code: code,
    detail: detail,
  );

  static String _publicModelFailure(String stage) =>
      stage == 'lorebook_writer' ? 'lorebookModelFailed' : 'cardModelFailed';

  static String _encodeOperations(List<RewriteOperationSnapshot> operations) =>
      jsonEncode([
        for (final operation in operations)
          jsonDecode(RewriteOperationSnapshotCodec.encode(operation)),
      ]);

  static List<RewriteOperationSnapshot>? _decodeOperations(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return null;
      final operations = <RewriteOperationSnapshot>[];
      for (final raw in decoded) {
        final operation = RewriteOperationSnapshotCodec.tryDecode(raw);
        if (operation == null) return null;
        operations.add(operation);
      }
      return operations;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _recordWriterParserVerdict({
    required LlmCaptureContext context,
    required bool accepted,
    required String source,
    String? detail,
    String? responseText,
  }) => LlmCallEventCapture.record(
    LlmCallEvent.parserVerdict(
      context: context,
      parserName: 'CardRewriteOperationParser.writerCheckpoint',
      accepted: accepted,
      code: accepted ? 'accepted' : 'invalidOutput',
      detail: detail,
      responseText: responseText,
      payload: {'source': source},
    ),
  );

  static String _historyConsolidationPrompt({
    required Map<String, dynamic> common,
    required String? priorHandoff,
    required List<Object?> history,
  }) =>
      '$_historyConsolidationInstruction\n\n'
      '# Prior cumulative handoff\n${priorHandoff ?? '(none)'}\n\n'
      '# Shared card, canon, and lorebook context\n${jsonEncode(common)}\n\n'
      '# Next immutable chat-history segment\n${jsonEncode(history)}';

  static CardEvolutionFinalizeOutcome _snapshotTooLarge(
    int actual, {
    String stage = 'snapshot',
  }) => CardEvolutionFinalizeOutcome(
    'snapshotTooLarge',
    null,
    'Card Rewriter $stage is $actual characters; the safe request limit is '
        '$_writerSnapshotCharacterLimit.',
  );

  static String _cardWriterContext(String selectedInputJson) {
    try {
      final input = Map<String, Object?>.from(
        jsonDecode(selectedInputJson) as Map,
      );
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

  static List<_ParsedObservationAction>? _parseObservationResponse(
    String output,
  ) {
    try {
      final cleaned = output
          .replaceAll(RegExp(r'^```(?:json)?\s*'), '')
          .replaceAll(RegExp(r'\s*```$'), '')
          .trim();
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) return null;
      final observations = decoded['observations'];
      if (observations is! List) return null;
      final result = <_ParsedObservationAction>[];
      final scopes = <String>{};
      for (final raw in observations) {
        if (raw is! Map) return null;
        final action = raw['action'];
        final scopeKey = raw['scopeKey'];
        final observedChange = raw['observedChange'];
        final confidence = raw['confidence'];
        final retrievalKeysRaw = raw['retrievalKeys'];
        final targetKind = raw['targetKind'];
        if (action is! String ||
            !const {
              'confirm',
              'new',
              'no_evidence',
              'contradict',
            }.contains(action) ||
            scopeKey is! String ||
            scopeKey.isEmpty ||
            !scopes.add(scopeKey) ||
            (action == 'new' &&
                (observedChange is! String || observedChange.isEmpty)) ||
            (action != 'no_evidence' &&
                (retrievalKeysRaw is! List ||
                    retrievalKeysRaw.isEmpty ||
                    retrievalKeysRaw.any(
                      (value) => value is! String || value.isEmpty,
                    ))) ||
            (action != 'no_evidence' &&
                !const {
                  'main_character_card',
                  'injected_lorebook_entry',
                }.contains(targetKind))) {
          return null;
        }
        final conf = confidence is num ? confidence.toDouble() : 0.5;
        final clampedConf = conf < 0.0
            ? 0.0
            : conf > 1.0
            ? 1.0
            : conf;
        final evidenceRaw = raw['evidenceMessageIds'];
        if (action != 'no_evidence' &&
            (evidenceRaw is! List ||
                evidenceRaw.any((item) => item is! String))) {
          return null;
        }
        final evidence = <String>[];
        for (final item
            in (evidenceRaw is List
                ? evidenceRaw.cast<String>()
                : const <String>[])) {
          if (item.isNotEmpty && !evidence.contains(item)) evidence.add(item);
        }
        if (action != 'no_evidence' && evidence.isEmpty) return null;
        result.add(
          _ParsedObservationAction(
            action: action,
            scopeKey: scopeKey,
            observedChange: observedChange is String ? observedChange : '',
            canonicalClaim: raw['canonicalClaim'] is String
                ? raw['canonicalClaim'] as String
                : null,
            evidenceMessageIds: evidence,
            retrievalKeys: retrievalKeysRaw is List
                ? retrievalKeysRaw.cast<String>().toSet().toList()
                : const [],
            targetKind: targetKind is String ? targetKind : null,
            cardFieldPath: raw['cardFieldPath'] is String
                ? raw['cardFieldPath'] as String
                : null,
            lorebookEntryId: raw['lorebookEntryId'] is String
                ? raw['lorebookEntryId'] as String
                : null,
            confidence: clampedConf,
          ),
        );
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static String _cardProposalContext(
    List<CardRewriteOperationSnapshot> operations,
  ) => jsonEncode([
    for (final operation in operations)
      jsonDecode(ManualRewriteOperationSnapshotCodec.encode(operation)),
  ]);

  static String? _scopeAllowlistFailure(
    List<CardRewriteOperationSnapshot> operations,
    String selectedInputJson,
  ) {
    final targets = _retrievalTargets(selectedInputJson);
    if (targets == null || targets.isEmpty) return null;
    final allowed = targets.keys.where(_isCardScopeTarget).toSet();
    if (allowed.isEmpty) return null;
    for (final operation in operations) {
      final scope = operation.transition.scopeKey;
      if (!allowed.contains(scope)) {
        return 'scopeKey "$scope" is not an available retrieval target';
      }
    }
    return null;
  }

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

  static String _modelFailureDetail(AuxCallOutcome outcome) {
    final attempts = outcome.attempts;
    if (attempts.isEmpty) return 'status: ${outcome.status.name}';
    final last = attempts.last;
    final error = last.error?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compactError = error == null || error.isEmpty
        ? ''
        : ': ${error.length > 180 ? '${error.substring(0, 180)}...' : error}';
    final code = last.statusCode == 0 ? '' : ' HTTP ${last.statusCode}';
    return '${attempts.length} attempt(s), ${last.status}$code$compactError';
  }

  Future<void> _saveDebugOutcome({
    required String sessionId,
    required String stage,
    required String model,
    required AuxCallOutcome outcome,
  }) async {
    try {
      await repo.saveDebugRun(
        sessionId: sessionId,
        stage: stage,
        status: outcome.status.name,
        model: model,
        output: outcome.text,
        attemptsJson: jsonEncode([
          for (final attempt in outcome.attempts) attempt.toJson(),
        ]),
        updatedAt: currentTimestampSeconds(),
      );
    } catch (error) {
      debugPrint('[CardRewriter] failed to persist model diagnostics: $error');
    }
  }

  /// Records a writer run that ended before any model call. Without this the
  /// only trace of a refused claim or an unavailable prompt snapshot is a
  /// transient toast, which makes the cause unrecoverable after the fact.
  Future<void> _saveSelectionBail({
    required String sessionId,
    required String outcome,
    required String? reason,
    required int throughCollectorOrdinal,
    required List<String> reconciliationRunIds,
  }) async {
    final detail = reason == null || reason.isEmpty ? 'unattributed' : reason;
    debugPrint(
      '[CardRewriter] writer bailed before model session=$sessionId '
      'outcome=$outcome reason=$detail '
      'collectorBoundary=$throughCollectorOrdinal '
      'runs=${reconciliationRunIds.length}',
    );
    try {
      await repo.saveDebugRun(
        sessionId: sessionId,
        stage: 'selection',
        status: outcome,
        model: '',
        output: null,
        attemptsJson: jsonEncode([
          {
            'outcome': outcome,
            'reason': detail,
            'collectorBoundary': throughCollectorOrdinal,
            'reconciliationRunIds': reconciliationRunIds,
            'at': currentTimestampSeconds(),
          },
        ]),
        updatedAt: currentTimestampSeconds(),
      );
    } catch (error) {
      // Diagnostics must never break the pipeline.
      debugPrint('[CardRewriter] failed to persist selection bail: $error');
    }
  }
}

final class _PreparedWriterContext {
  const _PreparedWriterContext.context(
    this.context, {
    this.chainIndex = 0,
    this.nextOrdinal = 1,
    this.parentCallId,
  }) : failure = null;
  const _PreparedWriterContext.failure(this.failure)
    : context = null,
      chainIndex = 0,
      nextOrdinal = 1,
      parentCallId = null;

  final String? context;
  final CardEvolutionFinalizeOutcome? failure;
  final int chainIndex;
  final int nextOrdinal;
  final String? parentCallId;
}

final class _LazyWriterModel {
  _LazyWriterModel(this._resolver);

  final CardRewriteModelResolver _resolver;
  Future<AuxApiConfig>? _value;

  Future<AuxApiConfig> resolve() => _value ??= _resolver();
}

final class _DurableCallResult {
  const _DurableCallResult.completed(this.call, [this.operations])
    : failure = null;
  const _DurableCallResult.failure(this.failure)
    : call = null,
      operations = null;

  final CardEvolutionWriterCallRow? call;
  final List<RewriteOperationSnapshot>? operations;
  final CardEvolutionFinalizeOutcome? failure;
}

final class _ParsedCallResult {
  const _ParsedCallResult.accepted(this.resultJson, [this.operations])
    : accepted = true,
      detail = null;
  const _ParsedCallResult.rejected(this.detail)
    : accepted = false,
      resultJson = null,
      operations = null;

  final bool accepted;
  final String? resultJson;
  final List<RewriteOperationSnapshot>? operations;
  final String? detail;
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

final class _ParsedObservationAction {
  const _ParsedObservationAction({
    required this.action,
    required this.scopeKey,
    required this.observedChange,
    required this.canonicalClaim,
    required this.evidenceMessageIds,
    required this.retrievalKeys,
    required this.targetKind,
    required this.cardFieldPath,
    required this.lorebookEntryId,
    required this.confidence,
  });

  final String action;
  final String scopeKey;
  final String observedChange;
  final String? canonicalClaim;
  final List<String> evidenceMessageIds;
  final List<String> retrievalKeys;
  final String? targetKind;
  final String? cardFieldPath;
  final String? lorebookEntryId;
  final double confidence;
}

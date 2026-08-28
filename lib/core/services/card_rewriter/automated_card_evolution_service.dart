import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/card_evolution_writer_call_repo.dart';
import '../../db/repositories/llm_request_capture_repo.dart';
import '../../db/app_db.dart';
import 'card_evolution_collector_coordinator.dart';
import 'card_evolution_writer_coordinator.dart';
import 'card_evolution_diagnostics.dart';
import 'durable_writer_call_runner.dart';
import 'manual_rewrite_service.dart';
import 'writer_context_consolidator.dart';

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
    CardEvolutionWriterCoordinator? writerCoordinator,
    CardEvolutionCollectorCoordinator? collectorCoordinator,
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
    if (writerCoordinator != null) {
      _writerCoordinator = writerCoordinator;
    } else {
      final effectiveWriterCallRunner =
          writerCallRunner ??
          DurableWriterCallRunner(
            repo: repo,
            writerCallRepo: this.writerCallRepo,
            executor: _executor,
            diagnostics: _diagnostics,
            timeoutMs: timeoutMs,
            leaseSeconds: leaseSeconds,
          );
      _writerCoordinator = CardEvolutionWriterCoordinator(
        repo: repo,
        writerCallRepo: this.writerCallRepo,
        resolveModel: resolveModel,
        diagnostics: _diagnostics,
        writerCallRunner: effectiveWriterCallRunner,
        writerContextConsolidator: writerContextConsolidator,
        leaseSeconds: leaseSeconds,
        isLorebookEvolutionEnabled: isLorebookEvolutionEnabled,
      );
    }
    _collectorCoordinator =
        collectorCoordinator ??
        CardEvolutionCollectorCoordinator(
          repo: repo,
          observationRepo: this.observationRepo,
          collectorRunRepo: this.collectorRunRepo,
          requestCaptureRepo: this.requestCaptureRepo,
          resolveModel: resolveModel,
          executor: _executor,
          diagnostics: _diagnostics,
          timeoutMs: timeoutMs,
          leaseSeconds: leaseSeconds,
          continueWriterAfterCollectors: _continueWriterAfterCollectors,
          observationPromotionThreshold: observationPromotionThreshold,
          observationMinConfidence: observationMinConfidence,
          observationExpiryRuns: observationExpiryRuns,
        );
  }

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
  final CardEvolutionDiagnostics _diagnostics;
  late final CardEvolutionWriterCoordinator _writerCoordinator;
  late final CardEvolutionCollectorCoordinator _collectorCoordinator;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final bool Function()? isEnabled;
  final bool Function()? isLorebookEvolutionEnabled;
  final int timeoutMs;
  final int leaseSeconds;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
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
    // Explicit "Run now" retains its historical convenience: on each complete
    // reconciliation batch it also refreshes observations. Automatic cadence
    // never uses this path.
    try {
      final count = await repo.countSuccessfulReconciliations(sessionId);
      if (count > 0 && count % collectorReconciliationBatchSize == 0) {
        onStage?.call(AutomatedCardEvolutionStage.observation);
        final snapshot = await repo.buildObservationSnapshot(sessionId);
        if (snapshot != null) {
          await _collectorCoordinator.runObservationPass(
            sessionId,
            snapshot,
            count ~/ collectorReconciliationBatchSize,
          );
          await _collectorCoordinator.checkPromotions(sessionId);
        }
      }
    } catch (_) {
      // Manual observation refresh is best effort; writer remains available.
    }
    return _runWriter(sessionId, onStage: onStage);
  }

  /// Automatic lane: collect each completed batch of valid reconciliations,
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

  /// Recovery lane for valid reconciliation batches that automatic dispatch did
  /// not process. Existing failed or live claims remain on their explicit
  /// recovery paths and are never bypassed.
  Future<CardEvolutionFinalizeOutcome> runPendingCollectors(String sessionId) {
    if (isEnabled?.call() == false) {
      return Future.value(const CardEvolutionFinalizeOutcome('disabled'));
    }
    final active = _inFlight[sessionId];
    if (active != null) return active;
    final future = _runPendingCollectors(sessionId);
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
  }) => _writerCoordinator.recoverWriterUnshared(
    failed,
    requestedCallId: requestedCallId,
    manualResponse: manualResponse,
  );

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
  }) => _collectorCoordinator.recoverFailedCollectorUnshared(
    failed,
    manualResponse: manualResponse,
  );

  Future<CardEvolutionFinalizeOutcome> _runAutomatic(
    LedgerReconciliationSuccessfulRunRow reconciliationRun, {
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) => _runPendingCollectors(
    reconciliationRun.sessionId,
    currentRun: reconciliationRun,
    onStage: onStage,
  );

  Future<CardEvolutionFinalizeOutcome> _runPendingCollectors(
    String sessionId, {
    LedgerReconciliationSuccessfulRunRow? currentRun,
    void Function(AutomatedCardEvolutionStage stage)? onStage,
  }) async {
    try {
      final pending = await collectorRunRepo.pendingValidPairs(
        sessionId,
        currentRun: currentRun,
      );
      if (pending.isEmpty && currentRun == null) {
        return const CardEvolutionFinalizeOutcome('collectorUpToDate');
      }
      for (final batch in pending) {
        final collected = await _collectorCoordinator.runCollector(
          batch,
          onObservationStage: () =>
              onStage?.call(AutomatedCardEvolutionStage.observation),
        );
        if (!collected) {
          return const CardEvolutionFinalizeOutcome('collectorUnavailable');
        }
      }
      return await _continueWriterAfterCollectors(sessionId, onStage: onStage);
    } catch (error, stackTrace) {
      debugPrint(
        '[CardRewriter] automatic lane failed before a durable writer result: '
        '$error\n$stackTrace',
      );
      await _diagnostics.saveSelectionBail(
        sessionId: sessionId,
        outcome: 'unexpectedFailure',
        reason: error.toString(),
        throughCollectorOrdinal: 0,
        reconciliationRunIds: currentRun == null ? const [] : [currentRun.id],
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
    if (reconciliationRuns.length !=
        _writerCollectorBatchSize * collectorReconciliationBatchSize) {
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
    return _writerCoordinator.runWriter(
      sessionId,
      throughCollectorOrdinal: throughCollectorOrdinal,
      collectorBoundaryHash: collectorBoundaryHash,
      collectorBoundaryRuns: collectorBoundaryRuns,
      reconciliationRunIds: reconciliationRunIds,
    );
  }

  void cancelSession(String sessionId) {
    _collectorCoordinator.cancelSession(sessionId);
    _writerCoordinator.cancelSession(sessionId);
  }

  void dispose() {
    _collectorCoordinator.dispose();
    _writerCoordinator.dispose();
  }
}

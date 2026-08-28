import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/llm_request_capture_repo.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../models/agent_operation_record.dart';
import '../../models/card_evolution_observation.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_evolution_diagnostics.dart';
import 'card_rewrite_prompt_builder.dart';
import 'manual_rewrite_service.dart';
import 'observation_response_parser.dart';

const _collectorMaxTokens = 40000;

typedef CardEvolutionWriterContinuation =
    Future<CardEvolutionFinalizeOutcome> Function(String sessionId);

/// Owns the automatic Card Evolution collector lane and its observation state.
class CardEvolutionCollectorCoordinator {
  CardEvolutionCollectorCoordinator({
    required this.repo,
    required this.observationRepo,
    required this.collectorRunRepo,
    required this.requestCaptureRepo,
    required this.resolveModel,
    required this._executor,
    required this._diagnostics,
    required this.timeoutMs,
    required this.leaseSeconds,
    required this.continueWriterAfterCollectors,
    this.parser = const ObservationResponseParser(),
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  });

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
  final LlmRequestCaptureRepo requestCaptureRepo;
  final CardRewriteModelResolver resolveModel;
  final CardRewriteLlmExecutor _executor;
  final CardEvolutionDiagnostics _diagnostics;
  final ObservationResponseParser parser;
  final int timeoutMs;
  final int leaseSeconds;
  final CardEvolutionWriterContinuation continueWriterAfterCollectors;
  final int Function()? observationPromotionThreshold;
  final double Function()? observationMinConfidence;
  final int Function()? observationExpiryRuns;
  final Map<String, CancelToken> _observationTokens = {};

  Future<bool> runCollector(
    CardEvolutionCollectorBatch batch, {
    void Function()? onObservationStage,
  }) async {
    final reconciliationRun = batch.boundary;
    final sessionId = reconciliationRun.sessionId;
    String? claimId;
    String? ownerId;
    try {
      final snapshot = await repo.buildObservationSnapshotForRuns(batch.runs);
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
        rangeHash: batch.rangeHash,
      );
      if (claim.kind == 'completed') return true;
      if (!claim.canRun || claim.row == null) return false;
      claimId = claim.row!.id;
      onObservationStage?.call();
      final output = await runObservationPass(
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
                return _sameRuns(logical, batch.runs);
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
      await checkPromotions(sessionId);
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

  Future<String?> runObservationPass(
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
    final prompt = _buildObservationPrompt(snapshot);
    final token = CancelToken();
    _observationTokens[sessionId] = token;
    try {
      if (token.isCancelled) return null;
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: _collectorMaxTokens,
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
      final actions = parser.parse(outcome.text!);
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
      if (identical(_observationTokens[sessionId], token)) {
        _observationTokens.remove(sessionId);
      }
    }
  }

  Future<CardEvolutionFinalizeOutcome> recoverFailedCollectorUnshared(
    CardEvolutionCollectorRunRow failed, {
    String? manualResponse,
  }) async {
    final runs = await collectorRunRepo.runsForCollectors(failed.sessionId, [
      failed,
    ]);
    if (runs.length != collectorReconciliationBatchSize) {
      return const CardEvolutionFinalizeOutcome('collectorEvidenceStale');
    }
    final batch = CardEvolutionCollectorBatch(runs);
    final snapshot = await repo.buildObservationSnapshotForRuns(runs);
    if (snapshot == null ||
        computeHash(snapshot.selectedInputJson) != failed.inputHash) {
      return const CardEvolutionFinalizeOutcome('staleInput');
    }

    String? prompt;
    if (manualResponse == null) {
      final failedCallId = failed.lastCallId;
      if (failedCallId != null) {
        final capture = await requestCaptureRepo.exactPromptForCall(
          callId: failedCallId,
          sessionId: failed.sessionId,
          pipelineRunId: failed.id,
          stage: 'card.collector',
        );
        prompt = capture?.prompt;
      }
      prompt ??= _buildObservationPrompt(snapshot);
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
        _observationTokens[failed.sessionId] = token;
        final outcome = await _executor(
          config: config,
          prompt: prompt!,
          maxTokens: _collectorMaxTokens,
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
        batch: batch,
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
      await checkPromotions(failed.sessionId);
      return continueWriterAfterCollectors(failed.sessionId);
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
      _observationTokens.remove(failed.sessionId);
    }
  }

  Future<_CollectorFinalizeResult> _finalizeCollectorOutput({
    required String sessionId,
    required CardEvolutionObservationSnapshot snapshot,
    required int runOrdinal,
    required CardEvolutionCollectorBatch batch,
    required String collectorId,
    required String ownerId,
    required String output,
    required LlmCaptureContext? captureContext,
    required String source,
  }) async {
    final actions = parser.parse(output);
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
        if (!_sameRuns(logical, batch.runs)) {
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

  bool _sameRuns(
    List<LedgerReconciliationSuccessfulRunRow> left,
    List<LedgerReconciliationSuccessfulRunRow> right,
  ) =>
      left.length == right.length &&
      left.indexed.every((entry) => entry.$2.id == right[entry.$1].id);

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

  Future<void> checkPromotions(String sessionId) async {
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

  List<Map<String, Object?>> extractAccumulatedObservations(
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

  String _buildObservationPrompt(CardEvolutionObservationSnapshot snapshot) {
    final activeMaps = extractAccumulatedObservations(
      snapshot.selectedInputJson,
    ).where((observation) => observation['status'] == 'active').toList();
    return '${CardRewriterPromptBuilder.buildObservationPass(character: snapshot.character, activeObservations: activeMaps, instruction: 'Review the last 40 immutable chat messages and the current Ledger-backed canon below. For each active observation, decide whether the chat history still supports it. Identify any new repeatedly demonstrated shift in preference, attitude, relationship dynamics, or lasting character development. Do not record one-off events or temporary state. Be conservative.')}\n\n# Immutable chat history and effective canon\n${_collectorContext(snapshot.selectedInputJson)}';
  }

  void cancelSession(String sessionId) {
    _observationTokens[sessionId]?.cancel('generationAborted');
  }

  void dispose() {
    for (final token in _observationTokens.values) {
      token.cancel('serviceDisposed');
    }
    _observationTokens.clear();
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

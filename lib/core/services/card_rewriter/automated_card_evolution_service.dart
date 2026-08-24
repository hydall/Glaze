import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../db/repositories/card_evolution_observation_repo.dart';
import '../../db/repositories/card_evolution_collector_run_repo.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/app_db.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../llm/aux_retry_runner.dart';
import '../../llm/aux_llm_client.dart';
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
    this.observationPromotionThreshold,
    this.observationMinConfidence,
    this.observationExpiryRuns,
  }) : observationRepo =
           observationRepo ?? CardEvolutionObservationRepo(repo.db),
       collectorRunRepo =
           collectorRunRepo ?? CardEvolutionCollectorRunRepo(repo.db);

  final CardEvolutionRepo repo;
  final CardEvolutionObservationRepo observationRepo;
  final CardEvolutionCollectorRunRepo collectorRunRepo;
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
    final delivered = await collectorRunRepo.latestDeliveredWriterBoundary(
      reconciliationRun.sessionId,
    );
    final dueBoundary = delivered + _writerCollectorBatchSize;
    final latest = await collectorRunRepo.latestCompletedOrdinal(
      reconciliationRun.sessionId,
    );
    if (latest < dueBoundary) {
      return const CardEvolutionFinalizeOutcome('collectorCompleted');
    }
    final boundaryRuns = await collectorRunRepo.completedBoundary(
      reconciliationRun.sessionId,
      dueBoundary,
      count: _writerCollectorBatchSize,
    );
    if (boundaryRuns.length != _writerCollectorBatchSize) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    final reconciliationRuns = await collectorRunRepo.runsForCollectors(
      reconciliationRun.sessionId,
      boundaryRuns,
    );
    if (reconciliationRuns.length != _writerCollectorBatchSize * 2) {
      return const CardEvolutionFinalizeOutcome('collectorUnavailable');
    }
    return _runWriter(
      reconciliationRun.sessionId,
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
    );
    final claim = claimed.claim;
    if (claim == null) {
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
    CancelToken? token;
    var finalized = false;
    try {
      final snapshotOutcome = await repo.readPromptSnapshotOutcome(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
      );
      final snapshot = snapshotOutcome.snapshot;
      if (snapshot == null) {
        await _saveSelectionBail(
          sessionId: sessionId,
          outcome: 'snapshotUnavailable',
          reason: snapshotOutcome.reason,
          throughCollectorOrdinal: throughCollectorOrdinal,
          reconciliationRunIds:
              reconciliationRunIds ??
              [
                for (final run in collectorBoundaryRuns)
                  run.reconciliationRunId,
              ],
        );
        return CardEvolutionFinalizeOutcome(
          'snapshotUnavailable',
          null,
          snapshotOutcome.reason,
        );
      }
      final config = await resolveModel();
      token = CancelToken();
      _tokens[sessionId] = token;
      final prepared = await _prepareWriterContext(
        config: config,
        selectedInputJson: snapshot.selectedInputJson,
        cancelToken: token,
      );
      if (prepared.failure != null) return prepared.failure!;
      final sharedContext = prepared.context!;
      final cardContext = _cardWriterContext(sharedContext);
      final allowedCardFields = CardRewritePolicy.nonEmptyEvolutionFields(
        snapshot.character,
      );
      final operations = <RewriteOperationSnapshot>[];
      final cardOperations = <CardRewriteOperationSnapshot>[];
      String? cardOutput;
      if (allowedCardFields.isNotEmpty) {
        final accumulatedObservations = _extractAccumulatedObservations(
          cardContext,
        );
        final cardPrompt =
            '${CardRewriterPromptBuilder.buildEvolution(character: snapshot.character, instruction: 'Independently evaluate the accumulated observation candidates, the available non-empty card fields, the complete immutable chat evidence or its cumulative factual consolidation, and the current Ledger-backed factual context. Russian evidence may support an English card patch; preserve exact Ledger identities without translation. An active observation alone is an unconfirmed candidate; promoted observations are stronger confirmed evidence. If the supplied immutable chat or Ledger confirms a durable candidate that directly contradicts supplied card text, resolve it with the smallest valid patch regardless of observation status unless no writable field or valid character-boundary-preserving anchor can do so; an empty operations list is not valid for a confirmed, resolvable contradiction. Otherwise return an empty operations list when no candidate is durable enough. Change only the smallest exact fragments and do not invent canon.', accumulatedObservations: accumulatedObservations)}\n\n# Immutable chat history and effective canon\n$cardContext';
        if (cardPrompt.length > _writerSnapshotCharacterLimit) {
          return _snapshotTooLarge(cardPrompt.length, stage: 'card prompt');
        }
        var cardOutcome = await _executor(
          config: config,
          prompt: cardPrompt,
          maxTokens: _writerMaxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
        );
        if (token.isCancelled ||
            cardOutcome.status == AgentOperationStatus.aborted ||
            !cardOutcome.isOk ||
            cardOutcome.text == null) {
          await _saveDebugOutcome(
            sessionId: sessionId,
            stage: 'card',
            model: config.model,
            outcome: cardOutcome,
          );
          return CardEvolutionFinalizeOutcome(
            token.isCancelled ||
                    cardOutcome.status == AgentOperationStatus.aborted
                ? 'cancelled'
                : 'cardModelFailed',
            null,
            _modelFailureDetail(cardOutcome),
          );
        }
        var parsedCardOperations =
            CardRewriteOperationParser.parseEvolutionBatch(
              cardOutcome.text!,
              allowedFields: allowedCardFields,
            );
        var parseFailure = parsedCardOperations == null
            ? CardRewriteOperationParser.explainEvolutionBatchFailure(
                cardOutcome.text!,
                allowedFields: allowedCardFields,
              )
            : _scopeAllowlistFailure(parsedCardOperations, cardContext);
        if (parseFailure != null) {
          final leaseRenewed = await repo.renewClaimLease(
            claimId: claim.row.id,
            ownerId: owner,
            now: currentTimestampSeconds(),
            leaseSeconds: leaseSeconds,
          );
          if (!leaseRenewed) {
            await _saveDebugOutcome(
              sessionId: sessionId,
              stage: 'card',
              model: config.model,
              outcome: cardOutcome,
            );
            return const CardEvolutionFinalizeOutcome('leaseLost');
          }
          final repairOutcome = await _executor(
            config: config,
            prompt: _cardRepairPrompt(
              originalPrompt: cardPrompt,
              failure: parseFailure,
              selectedInputJson: cardContext,
            ),
            maxTokens: _writerMaxTokens,
            temperature: 0.2,
            timeoutMs: timeoutMs,
            cancelToken: token,
          );
          cardOutcome = _combineOutcomes(cardOutcome, repairOutcome);
          if (token.isCancelled ||
              repairOutcome.status == AgentOperationStatus.aborted ||
              !repairOutcome.isOk ||
              repairOutcome.text == null) {
            await _saveDebugOutcome(
              sessionId: sessionId,
              stage: 'card',
              model: config.model,
              outcome: cardOutcome,
            );
            return CardEvolutionFinalizeOutcome(
              token.isCancelled ||
                      repairOutcome.status == AgentOperationStatus.aborted
                  ? 'cancelled'
                  : 'cardModelFailed',
              null,
              _modelFailureDetail(repairOutcome),
            );
          }
          parsedCardOperations = CardRewriteOperationParser.parseEvolutionBatch(
            repairOutcome.text!,
            allowedFields: allowedCardFields,
          );
          parseFailure = parsedCardOperations == null
              ? CardRewriteOperationParser.explainEvolutionBatchFailure(
                  repairOutcome.text!,
                  allowedFields: allowedCardFields,
                )
              : _scopeAllowlistFailure(parsedCardOperations, cardContext);
        }
        await _saveDebugOutcome(
          sessionId: sessionId,
          stage: 'card',
          model: config.model,
          outcome: cardOutcome,
        );
        if (parsedCardOperations == null) {
          return CardEvolutionFinalizeOutcome(
            'invalidCardOutput',
            null,
            _diagnostic(parseFailure, cardOutcome.text!),
          );
        }
        if (parseFailure != null) {
          return CardEvolutionFinalizeOutcome(
            'invalidCardOutput',
            null,
            _diagnostic(parseFailure, cardOutcome.text!),
          );
        }
        cardOperations.addAll(parsedCardOperations);
        operations.addAll(cardOperations);
        cardOutput = cardOutcome.text;
      }
      String? lorebookOutput;
      if (isLorebookEvolutionEnabled?.call() != false &&
          _hasInjectedLoreTargets(sharedContext)) {
        final lorebookPrompt =
            '${CardRewriterPromptBuilder.buildLorebookEvolution(instruction: 'Use the shared card, chat, and Ledger context to keep only the supplied injected lorebook entries current. Prefer the card for character relationships and enduring behavior; prefer lorebook entries for their specific locations, people, objects, or setting facts. Do not duplicate a current or proposed card fact into lorebook. Return a patch whenever the chat supports a durable update that belongs in an injected entry and is not already covered by the card.')}\n\n# Shared immutable context\n$sharedContext\n\n# Proposed card operations (read-only)\n${_cardProposalContext(cardOperations)}';
        if (lorebookPrompt.length > _writerSnapshotCharacterLimit) {
          return _snapshotTooLarge(
            lorebookPrompt.length,
            stage: 'lorebook prompt',
          );
        }
        final lorebookOutcome = await _executor(
          config: config,
          prompt: lorebookPrompt,
          maxTokens: _writerMaxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
        );
        await _saveDebugOutcome(
          sessionId: sessionId,
          stage: 'lorebook',
          model: config.model,
          outcome: lorebookOutcome,
        );
        if (token.isCancelled ||
            lorebookOutcome.status == AgentOperationStatus.aborted ||
            !lorebookOutcome.isOk ||
            lorebookOutcome.text == null) {
          return CardEvolutionFinalizeOutcome(
            token.isCancelled ||
                    lorebookOutcome.status == AgentOperationStatus.aborted
                ? 'cancelled'
                : 'lorebookModelFailed',
            null,
            _modelFailureDetail(lorebookOutcome),
          );
        }
        final lorebookOperations =
            CardRewriteOperationParser.parseLorebookEvolutionBatch(
              lorebookOutcome.text!,
            );
        if (lorebookOperations == null) {
          return const CardEvolutionFinalizeOutcome('invalidLorebookOutput');
        }
        operations.addAll(lorebookOperations);
        lorebookOutput = lorebookOutcome.text;
      }
      if (operations.isEmpty) {
        if (throughCollectorOrdinal > 0) {
          finalized = await repo.completeEmptyClaim(
            claimId: claim.row.id,
            ownerId: owner,
            now: currentTimestampSeconds(),
          );
        }
        return const CardEvolutionFinalizeOutcome(
          'emptyModelProposal',
          null,
          'Every enabled writer returned an empty operations list. Check the '
              'saved card/lorebook debug responses.',
        );
      }
      final modelOutputs = <String, String>{};
      if (cardOutput != null) modelOutputs['card'] = cardOutput;
      if (lorebookOutput != null) modelOutputs['lorebook'] = lorebookOutput;
      final result = await repo.finalize(
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        modelOutput: jsonEncode(modelOutputs),
        operations: operations,
      );
      finalized = result.isPersisted;
      return result;
    } on CardRewriteModelNotConfigured {
      return const CardEvolutionFinalizeOutcome('modelNotConfigured');
    } catch (_) {
      return const CardEvolutionFinalizeOutcome('unexpectedFailure');
    } finally {
      if (token != null && identical(_tokens[sessionId], token)) {
        _tokens.remove(sessionId);
      }
      if (!finalized) {
        await repo.abandonClaim(claimId: claim.row.id, ownerId: owner);
      }
    }
  }

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
      if (output == null) return false;
      await _checkPromotions(sessionId);
      claimId = null;
      return true;
    } catch (_) {
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
      );
      if (token.isCancelled ||
          outcome.status == AgentOperationStatus.aborted ||
          !outcome.isOk ||
          outcome.text == null) {
        return null;
      }
      final actions = _parseObservationResponse(outcome.text!);
      if (actions == null) return null;
      final validEvidenceIds = _chatMessageIds(snapshot.selectedInputJson);
      if (validEvidenceIds == null) return null;
      final retrievalTargets = _retrievalTargets(snapshot.selectedInputJson);
      if (retrievalTargets == null) return null;
      Future<void> applyEffects() async {
        final now = currentTimestampSeconds();
        for (final action in actions) {
          if (!validEvidenceIds.containsAll(action.evidenceMessageIds)) {
            continue;
          }
          if (!retrievalTargets.keys.toSet().containsAll(
            action.retrievalKeys,
          )) {
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
                        (key) =>
                            retrievalTargets[key] == 'injected_lorebook_entry',
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
        final existing = await observationRepo.findByScopeKey(
          sessionId,
          action.scopeKey,
        );
        if (existing == null) {
          await observationRepo.insertObservation(
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
        }
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

  Future<_PreparedWriterContext> _prepareWriterContext({
    required AuxApiConfig config,
    required String selectedInputJson,
    required CancelToken cancelToken,
  }) async {
    if (selectedInputJson.length <= _writerContextCharacterLimit) {
      return _PreparedWriterContext.context(selectedInputJson);
    }
    Map<String, dynamic> decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(selectedInputJson) as Map);
    } catch (_) {
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(selectedInputJson.length),
      );
    }
    final history = decoded['chatHistory'];
    if (history is! List) {
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(selectedInputJson.length),
      );
    }
    final common = Map<String, dynamic>.from(decoded)
      ..remove('writerCollectorMessageIds')
      ..remove('chatHistory');
    if (jsonEncode(common).length > _writerContextCharacterLimit) {
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(jsonEncode(common).length, stage: 'shared context'),
      );
    }
    String? handoff;
    var offset = 0;
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
        final singlePrompt = _historyConsolidationPrompt(
          common: common,
          priorHandoff: handoff,
          history: [history[offset]],
        );
        return _PreparedWriterContext.failure(
          _snapshotTooLarge(
            singlePrompt.length,
            stage: 'history message ${offset + 1}',
          ),
        );
      }
      final outcome = await _executor(
        config: config,
        prompt: prompt,
        maxTokens: _writerMaxTokens,
        temperature: 0.2,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled ||
          outcome.status == AgentOperationStatus.aborted) {
        return const _PreparedWriterContext.failure(
          CardEvolutionFinalizeOutcome('cancelled'),
        );
      }
      if (!outcome.isOk || outcome.text == null) {
        return _PreparedWriterContext.failure(
          CardEvolutionFinalizeOutcome(
            'cardModelFailed',
            null,
            _modelFailureDetail(outcome),
          ),
        );
      }
      handoff = outcome.text;
      offset += chunk.length;
    }
    final finalContext = jsonEncode({
      ...common,
      'chatHistory': const <Object?>[],
      'completeHistoryConsolidation': handoff,
    });
    if (finalContext.length > _writerContextCharacterLimit) {
      return _PreparedWriterContext.failure(
        _snapshotTooLarge(finalContext.length, stage: 'final writer context'),
      );
    }
    return _PreparedWriterContext.context(finalContext);
  }

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

  static String _diagnostic(String? reason, String output) {
    final compact = output.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = compact.length > 240
        ? '${compact.substring(0, 240)}...'
        : compact;
    return '${reason ?? 'unrecognized response'}; response: $preview';
  }

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

  static AuxCallOutcome _combineOutcomes(
    AuxCallOutcome first,
    AuxCallOutcome second,
  ) => AuxCallOutcome(
    status: second.status,
    text: second.text,
    attempts: [
      ...first.attempts,
      for (var index = 0; index < second.attempts.length; index++)
        AgentOperationAttempt(
          attempt: first.attempts.length + index + 1,
          statusCode: second.attempts[index].statusCode,
          status: second.attempts[index].status,
          error: second.attempts[index].error,
          startedAtMs: second.attempts[index].startedAtMs,
          elapsedMs: second.attempts[index].elapsedMs,
        ),
    ],
    totalElapsedMs: first.totalElapsedMs + second.totalElapsedMs,
    lastError: second.lastError,
  );

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
  }) => repo.saveDebugRun(
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
  const _PreparedWriterContext.context(this.context) : failure = null;
  const _PreparedWriterContext.failure(this.failure) : context = null;

  final String? context;
  final CardEvolutionFinalizeOutcome? failure;
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

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/card_evolution_writer_call_repo.dart';
import '../../llm/card_rewrite_slot_resolver.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_evolution_diagnostics.dart';
import 'card_rewrite_prompt_builder.dart';
import 'card_rewriter_contracts.dart';
import 'durable_writer_call_runner.dart';
import 'manual_rewrite_service.dart';
import 'writer_context_consolidator.dart';

/// Owns durable Card Evolution writer claims, checkpoints, and cancellation.
final class CardEvolutionWriterCoordinator {
  CardEvolutionWriterCoordinator({
    required this.repo,
    required this.writerCallRepo,
    required this.resolveModel,
    required this.diagnostics,
    required this.writerCallRunner,
    required this.leaseSeconds,
    this.isLorebookEvolutionEnabled,
    WriterContextConsolidator? writerContextConsolidator,
  }) {
    _writerContextConsolidator =
        writerContextConsolidator ??
        WriterContextConsolidator(
          writerCallRunner: writerCallRunner,
          discardOrRetainWriter: _discardOrRetainWriter,
          snapshotTooLarge: _snapshotTooLarge,
        );
  }

  final CardEvolutionRepo repo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final CardRewriteModelResolver resolveModel;
  final CardEvolutionDiagnostics diagnostics;
  final DurableWriterCallRunner writerCallRunner;
  final int leaseSeconds;
  final bool Function()? isLorebookEvolutionEnabled;
  late final WriterContextConsolidator _writerContextConsolidator;
  final Map<String, CancelToken> _tokens = {};

  Future<CardEvolutionFinalizeOutcome> runWriter(
    String sessionId, {
    int throughCollectorOrdinal = 0,
    String collectorBoundaryHash = '',
    List<CardEvolutionCollectorRunRow> collectorBoundaryRuns = const [],
    List<String>? reconciliationRunIds,
  }) async {
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
      await diagnostics.saveSelectionBail(
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

  Future<CardEvolutionFinalizeOutcome> recoverWriterUnshared(
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
      final sharedContext = prepared.context!;
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
        final card = await writerCallRunner.runOperationCall(
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
          final repair = await writerCallRunner.runOperationCall(
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
        final lorebook = await writerCallRunner.runOperationCall(
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
        final failed = await writerCallRunner.failClosed(
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
        await writerCallRunner.markWriterFailure(
          claim,
          owner,
          finalized.kind,
          finalized.detail,
        );
      }
      return finalized;
    } on CardRewriteModelNotConfigured catch (error) {
      await writerCallRunner.markWriterFailure(
        claim,
        owner,
        'modelNotConfigured',
        error.toString(),
      );
      return const CardEvolutionFinalizeOutcome('modelNotConfigured');
    } catch (error) {
      await writerCallRunner.markWriterFailure(
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

  Future<void> _discardOrRetainWriter(
    CardEvolutionClaim claim,
    String owner,
    List<CardEvolutionWriterCallRow> chain,
    String code,
    String? detail,
  ) => chain.isEmpty
      ? repo.abandonClaim(claimId: claim.row.id, ownerId: owner)
      : writerCallRunner.markWriterFailure(claim, owner, code, detail);

  void cancelSession(String sessionId) {
    _tokens[sessionId]?.cancel('generationAborted');
  }

  void dispose() {
    for (final token in _tokens.values) {
      token.cancel('serviceDisposed');
    }
    _tokens.clear();
  }

  static bool _writerLorebookEnabled(String optionsJson) {
    try {
      final options = jsonDecode(optionsJson);
      return options is! Map || options['lorebookEnabled'] != false;
    } catch (_) {
      return true;
    }
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

  static String _cardProposalContext(
    List<CardRewriteOperationSnapshot> operations,
  ) => jsonEncode([
    for (final operation in operations)
      jsonDecode(ManualRewriteOperationSnapshotCodec.encode(operation)),
  ]);

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

  static bool _isCardScopeTarget(String key) =>
      !key.contains('/') && CardRewriteScope.tryParse(key) != null;
}

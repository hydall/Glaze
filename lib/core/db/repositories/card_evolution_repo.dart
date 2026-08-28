import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../models/character.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../services/card_rewriter/effective_canon_assembler.dart';
import '../../services/card_rewriter/effective_canon_read_repository.dart';
import '../../llm/prompt/exact_lorebook_manifest.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../app_db.dart';
import 'card_evolution_collector_run_repo.dart';
import 'manual_rewrite_job_repo.dart';
import 'session_lorebook_evolution_repo.dart';

const _maxChatHistoryMessages = 40;
const _writerCollectorBatchSize = 2;
const _writerReconciliationRunCount =
    _writerCollectorBatchSize * collectorReconciliationBatchSize;
const _maxCanonValueCharacters = 2000;
const _maxLorebookEntryCharacters = 60000;
const _maxLorebookTotalCharacters = 600000;

/// Why the canonical writer/collector input could not be selected. Every bail
/// point in [CardEvolutionRepo._selectInput] maps to exactly one value so a
/// silent `notEligible` can be attributed without re-deriving the state.
enum CardEvolutionSelectionFailure {
  sessionMissing,
  messagesMalformed,
  canonUnavailable,
  baselineDecisionRequired,
  reconciliationRunsMissing,
  historyUnresolved,
  historyTooShort,
  historyRolesIncomplete,
  lorebookEvidenceUnavailable,
  collectorRunsUnresolved,
  inputHashMismatch,
  claimEvidenceMismatch,
  unexpectedError,
}

/// Either the canonical selected input or the reason it is unavailable.
final class CardEvolutionSelection {
  const CardEvolutionSelection.selected(String this.json) : failure = null;
  const CardEvolutionSelection.failed(
    CardEvolutionSelectionFailure this.failure,
  ) : json = null;

  final String? json;
  final CardEvolutionSelectionFailure? failure;

  bool get isSelected => json != null;

  /// Stable diagnostic label; empty when the selection succeeded.
  String get failureName => failure?.name ?? '';
}

final class CardEvolutionClaim {
  const CardEvolutionClaim({
    required this.row,
    required this.selectedInputJson,
  });
  final CardEvolutionClaimRow row;
  final String selectedInputJson;
}

final class CardEvolutionClaimOutcome {
  const CardEvolutionClaimOutcome(this.kind, [this.claim, this.detail]);
  final String kind;
  final CardEvolutionClaim? claim;

  /// Diagnostic attribution for the non-claiming kinds. Never user-facing
  /// copy: it carries a [CardEvolutionSelectionFailure] name when the claim
  /// failed while selecting evidence.
  final String? detail;
  bool get isClaimed => kind == 'claimed' || kind == 'existing';
}

final class CardEvolutionPromptSnapshot {
  const CardEvolutionPromptSnapshot({
    required this.claim,
    required this.character,
    required this.selectedInputJson,
  });

  final CardEvolutionClaimRow claim;
  final Character character;
  final String selectedInputJson;
}

/// Either the prompt snapshot for a live lease or the reason it is
/// unavailable. The reason is diagnostic only and is never shown verbatim to
/// the user.
final class CardEvolutionPromptSnapshotOutcome {
  const CardEvolutionPromptSnapshotOutcome.ready(
    CardEvolutionPromptSnapshot this.snapshot,
  ) : reason = null;
  const CardEvolutionPromptSnapshotOutcome.unavailable(String this.reason)
    : snapshot = null;

  final CardEvolutionPromptSnapshot? snapshot;
  final String? reason;
}

final class CardEvolutionFinalizeOutcome {
  const CardEvolutionFinalizeOutcome(this.kind, [this.job, this.detail]);
  final String kind;
  final RewriteJobRow? job;
  final String? detail;
  bool get isPersisted => kind == 'persisted' || kind == 'alreadyCompleted';
}

final class CardEvolutionDeleteOutcome {
  const CardEvolutionDeleteOutcome(this.kind);

  final String kind;
  bool get isDeleted => kind == 'deleted';
}

/// Read-only context for the observation pass: the character and the canonical
/// selected input (chat history, card snapshot, effective canon). Unlike
/// [CardEvolutionPromptSnapshot] this does not require a live claim lease.
final class CardEvolutionObservationSnapshot {
  const CardEvolutionObservationSnapshot({
    required this.character,
    required this.selectedInputJson,
  });

  final Character character;
  final String selectedInputJson;
}

/// Owns eligibility, lease ownership and the all-or-nothing automated proposal
/// commit. The immutable chat-history snapshot is the primary evidence; the
/// current effective canon supplies Ledger's durable facts and tracker state.
class CardEvolutionRepo {
  static const _minimumEvolutionAnchorCodeUnits = 12;

  CardEvolutionRepo({
    required this.db,
    required this.canonReader,
    required this.jobRepo,
    SessionLorebookEvolutionRepo? lorebookEvolutionRepo,
    @visibleForTesting this.beforeCursorInsert,
  }) : lorebookEvolutionRepo =
           lorebookEvolutionRepo ?? SessionLorebookEvolutionRepo(db);

  final AppDatabase db;
  final EffectiveCanonReadRepository canonReader;
  final ManualRewriteJobRepo jobRepo;
  final SessionLorebookEvolutionRepo lorebookEvolutionRepo;
  final Future<void> Function()? beforeCursorInsert;

  Future<CardEvolutionClaimRow?> getClaimById(String claimId) => (db.select(
    db.cardEvolutionClaims,
  )..where((row) => row.id.equals(claimId))).getSingleOrNull();

  Future<bool> isEligible(String sessionId) => db.transaction<bool>(
    () async => (await _selectInput(sessionId)).isSelected,
  );

  /// Deletes one replaceable automated proposal and its complete review
  /// provenance. Pending review proposals are replaceable because none of their
  /// patches have been applied to the card yet.
  /// The completed claim is removed as well so the same immutable input may be
  /// explicitly regenerated instead of being blocked by idempotency.
  Future<CardEvolutionDeleteOutcome> deleteReplaceableProposal(String jobId) =>
      db.transaction(() async {
        final job = await (db.select(
          db.rewriteJobs,
        )..where((row) => row.id.equals(jobId))).getSingleOrNull();
        if (job == null) return const CardEvolutionDeleteOutcome('notFound');
        if (!const {'pending', 'failed', 'cancelled'}.contains(job.status)) {
          return const CardEvolutionDeleteOutcome('invalidState');
        }
        final proposal = await (db.select(
          db.cardEvolutionProposalRuns,
        )..where((row) => row.rewriteJobId.equals(jobId))).getSingleOrNull();
        if (proposal == null) {
          return const CardEvolutionDeleteOutcome('notAutomatedEvolution');
        }
        final operations = await (db.select(
          db.rewriteOperations,
        )..where((row) => row.rewriteJobId.equals(jobId))).get();
        final operationIds = operations.map((row) => row.id).toList();
        if (operationIds.isNotEmpty) {
          await (db.delete(
            db.rewriteOperationRevisions,
          )..where((row) => row.rewriteOperationId.isIn(operationIds))).go();
          await (db.delete(
            db.rewriteEvidenceRows,
          )..where((row) => row.rewriteOperationId.isIn(operationIds))).go();
          await (db.delete(
            db.rewriteOperations,
          )..where((row) => row.id.isIn(operationIds))).go();
        }
        await (db.delete(
          db.cardEvolutionProposalRuns,
        )..where((row) => row.id.equals(proposal.id))).go();
        await (db.delete(
          db.rewriteJobs,
        )..where((row) => row.id.equals(jobId))).go();
        await (db.delete(
          db.cardEvolutionClaims,
        )..where((row) => row.id.equals(proposal.claimId))).go();
        return const CardEvolutionDeleteOutcome('deleted');
      });

  /// Discards a failed automated writer chain so its collector boundary may be
  /// attempted again. Completed claims and review proposals are never touched.
  Future<CardEvolutionDeleteOutcome> deleteFailedWriterClaim(String claimId) =>
      db.transaction(() async {
        final claim = await (db.select(
          db.cardEvolutionClaims,
        )..where((row) => row.id.equals(claimId))).getSingleOrNull();
        if (claim == null) return const CardEvolutionDeleteOutcome('notFound');
        if (claim.status != 'failed') {
          return const CardEvolutionDeleteOutcome('invalidState');
        }
        await (db.delete(
          db.cardEvolutionWriterCalls,
        )..where((row) => row.claimId.equals(claimId))).go();
        final deleted =
            await (db.delete(db.cardEvolutionClaims)..where(
                  (row) => row.id.equals(claimId) & row.status.equals('failed'),
                ))
                .go();
        return CardEvolutionDeleteOutcome(
          deleted == 1 ? 'deleted' : 'invalidState',
        );
      });

  /// Diagnostic variant of [isEligible]: reports why the session cannot be
  /// selected instead of collapsing every cause into `false`.
  @visibleForTesting
  Future<CardEvolutionSelectionFailure?> selectionFailure(String sessionId) =>
      db.transaction<CardEvolutionSelectionFailure?>(
        () async => (await _selectInput(sessionId)).failure,
      );

  Future<CardEvolutionClaimOutcome> claim({
    required String sessionId,
    required String ownerId,
    required int now,
    required int leaseSeconds,
    int throughCollectorOrdinal = 0,
    String collectorBoundaryHash = '',
    List<String> reconciliationRunIds = const [],
    String writerOptionsJson = '{}',
  }) => db.transaction(() async {
    if (ownerId.isEmpty || leaseSeconds <= 0) {
      return const CardEvolutionClaimOutcome('invalidRequest');
    }
    final existing =
        await (db.select(db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('claimed')))
            .getSingleOrNull();
    if (existing != null && existing.leaseExpiresAt > now) {
      if (existing.ownerId != ownerId) {
        return const CardEvolutionClaimOutcome('busy');
      }
      final selection = await _selectedInputForClaim(existing);
      final selected = selection.json;
      return selected == null
          ? CardEvolutionClaimOutcome('stale', null, selection.failureName)
          : CardEvolutionClaimOutcome(
              'existing',
              CardEvolutionClaim(row: existing, selectedInputJson: selected),
            );
    }
    if (existing != null) {
      final writerCall =
          await (db.select(db.cardEvolutionWriterCalls)
                ..where((row) => row.claimId.equals(existing.id))
                ..limit(1))
              .getSingleOrNull();
      if (writerCall != null) {
        await (db.update(db.cardEvolutionClaims)..where(
              (row) =>
                  row.id.equals(existing.id) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isSmallerOrEqualValue(now),
            ))
            .write(
              CardEvolutionClaimsCompanion(
                status: const Value('failed'),
                leaseExpiresAt: const Value(0),
                failureCode: const Value('recoveryRequired'),
                failureDetail: const Value(
                  'Writer lease expired with durable call checkpoints',
                ),
                failedAt: Value(now),
              ),
            );
        final failed = await getClaimById(existing.id);
        final selected = failed?.selectedInputJson;
        return CardEvolutionClaimOutcome(
          'failed',
          failed == null ||
                  selected == null ||
                  computeHash(selected) != failed.inputHash
              ? null
              : CardEvolutionClaim(row: failed, selectedInputJson: selected),
          'recoveryRequired',
        );
      }
      // An expired owner cannot finalize (finalize checks the same lease). Do
      // not reuse its snapshot: chat/canon may have advanced while the app was
      // closed, so drop the stale lease and create a fresh claim below.
      final deleted =
          await (db.delete(db.cardEvolutionClaims)
                ..where((row) => row.id.equals(existing.id))
                ..where((row) => row.status.equals('claimed'))
                ..where((row) => row.leaseExpiresAt.isSmallerOrEqualValue(now)))
              .go();
      if (deleted != 1) {
        return const CardEvolutionClaimOutcome('busy');
      }
    }
    final failed =
        await (db.select(db.cardEvolutionClaims)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.status.equals('failed'))
              ..orderBy([(row) => OrderingTerm.desc(row.failedAt)])
              ..limit(1))
            .getSingleOrNull();
    if (failed != null) {
      // Validate the failed snapshot the way a real restart would: the stored
      // input must still reproduce from the current chat and canon. Only a
      // reproducible claim is recoverable through the manual recovery UI.
      final selection = await _selectedInputForClaim(failed);
      final selected = selection.json;
      if (selected != null) {
        return CardEvolutionClaimOutcome(
          'failed',
          CardEvolutionClaim(row: failed, selectedInputJson: selected),
          failed.failureCode,
        );
      }
      // The failed snapshot can no longer be reproduced (chat, canon, or the
      // context format moved on), so no restart can ever succeed. Exit the
      // restart loop instead of blocking the lane forever: drop the dead
      // claim with its call chain and select a fresh snapshot below.
      await (db.delete(
        db.cardEvolutionWriterCalls,
      )..where((row) => row.claimId.equals(failed.id))).go();
      final deleted =
          await (db.delete(db.cardEvolutionClaims)
                ..where((row) => row.id.equals(failed.id))
                ..where((row) => row.status.equals('failed')))
              .go();
      if (deleted != 1) {
        return const CardEvolutionClaimOutcome('busy');
      }
    }
    final selection = await _selectInput(
      sessionId,
      reconciliationRunIds: reconciliationRunIds,
    );
    final selected = selection.json;
    if (selected == null) {
      return CardEvolutionClaimOutcome(
        'notEligible',
        null,
        selection.failureName,
      );
    }
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return const CardEvolutionClaimOutcome('notFound');
    if (await _activeJob(sessionId, session.characterId) != null) {
      return const CardEvolutionClaimOutcome('activeJob');
    }
    final id = 'evolution-claim-${generateId()}';
    final inputHash = computeHash(selected);
    final snapshot = jsonDecode(selected) as Map<String, dynamic>;
    try {
      await db
          .into(db.cardEvolutionClaims)
          .insert(
            CardEvolutionClaimsCompanion.insert(
              id: id,
              sessionId: sessionId,
              characterId: session.characterId,
              ownerId: ownerId,
              status: 'claimed',
              leaseExpiresAt: now + leaseSeconds,
              chatHistoryHash: snapshot['chatHistoryHash'] as String,
              effectiveCanonIdentity:
                  snapshot['effectiveCanonIdentity'] as String,
              predecessorCursorHash: collectorBoundaryHash,
              predecessorRunOrdinal: throughCollectorOrdinal,
              inputHash: inputHash,
              selectedInputJson: Value(selected),
              writerOptionsJson: Value(writerOptionsJson),
              createdAt: now,
            ),
          );
    } catch (_) {
      return const CardEvolutionClaimOutcome('busy');
    }
    final row = await (db.select(
      db.cardEvolutionClaims,
    )..where((item) => item.id.equals(id))).getSingle();
    return CardEvolutionClaimOutcome(
      'claimed',
      CardEvolutionClaim(row: row, selectedInputJson: selected),
    );
  });

  /// Returns the immutable, canon-bound prompt input for a live claimed lease.
  /// This path is read-only: it never reconciles source lineage or writes any
  /// baseline/canon state.
  Future<CardEvolutionPromptSnapshot?> readPromptSnapshot({
    required String claimId,
    required String ownerId,
    required int now,
  }) async => (await readPromptSnapshotOutcome(
    claimId: claimId,
    ownerId: ownerId,
    now: now,
  )).snapshot;

  /// Extends a live claim without allowing an expired or different owner to
  /// reclaim it. Long writer and repair calls use this before starting more
  /// remote work so finalization cannot lose ownership mid-cycle.
  Future<bool> renewClaimLease({
    required String claimId,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) async {
    if (ownerId.isEmpty || leaseSeconds <= 0) return false;
    final changed =
        await (db.update(db.cardEvolutionClaims)..where(
              (row) =>
                  row.id.equals(claimId) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionClaimsCompanion(
                leaseExpiresAt: Value(now + leaseSeconds),
              ),
            );
    return changed == 1;
  }

  Future<CardEvolutionClaimOutcome> claimFailedWriter({
    required String claimId,
    required String ownerId,
    required int now,
    required int leaseSeconds,
  }) => db.transaction(() async {
    if (ownerId.isEmpty || leaseSeconds <= 0) {
      return const CardEvolutionClaimOutcome('invalidRequest');
    }
    final failed = await getClaimById(claimId);
    if (failed == null || failed.status != 'failed') {
      return const CardEvolutionClaimOutcome('notFailed');
    }
    if (failed.predecessorRunOrdinal > 0) {
      final completedBoundary =
          await (db.select(db.cardEvolutionClaims)
                ..where(
                  (row) =>
                      row.sessionId.equals(failed.sessionId) &
                      row.status.equals('completed') &
                      row.predecessorRunOrdinal.equals(
                        failed.predecessorRunOrdinal,
                      ) &
                      row.predecessorCursorHash.equals(
                        failed.predecessorCursorHash,
                      ),
                )
                ..limit(1))
              .getSingleOrNull();
      if (completedBoundary != null) {
        return const CardEvolutionClaimOutcome('notFailed');
      }
    }
    final changed =
        await (db.update(db.cardEvolutionClaims)..where(
              (row) => row.id.equals(claimId) & row.status.equals('failed'),
            ))
            .write(
              CardEvolutionClaimsCompanion(
                ownerId: Value(ownerId),
                status: const Value('claimed'),
                leaseExpiresAt: Value(now + leaseSeconds),
                failureCode: const Value(null),
                failureDetail: const Value(null),
                failedAt: const Value(null),
              ),
            );
    if (changed != 1) return const CardEvolutionClaimOutcome('notFailed');
    final row = await (db.select(
      db.cardEvolutionClaims,
    )..where((item) => item.id.equals(claimId))).getSingle();
    final selected = row.selectedInputJson;
    if (selected == null || computeHash(selected) != row.inputHash) {
      // The stored input is corrupt: put the claim back into its failed state
      // so the recovery UI keeps showing it instead of stranding a claimed
      // lease that can never produce a snapshot.
      await (db.update(db.cardEvolutionClaims)..where(
            (row) => row.id.equals(claimId) & row.ownerId.equals(ownerId),
          ))
          .write(
            CardEvolutionClaimsCompanion(
              status: const Value('failed'),
              leaseExpiresAt: const Value(0),
              failureCode: const Value('inputHashMismatch'),
              failureDetail: const Value(
                'Stored Card Evolution input is invalid',
              ),
              failedAt: Value(now),
            ),
          );
      return const CardEvolutionClaimOutcome(
        'stale',
        null,
        'inputHashMismatch',
      );
    }
    return CardEvolutionClaimOutcome(
      'claimed',
      CardEvolutionClaim(row: row, selectedInputJson: selected),
    );
  });

  Future<bool> markWriterFailed({
    required String claimId,
    required String ownerId,
    required int now,
    required String code,
    String? detail,
  }) async {
    final changed =
        await (db.update(db.cardEvolutionClaims)..where(
              (row) =>
                  row.id.equals(claimId) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed'),
            ))
            .write(
              CardEvolutionClaimsCompanion(
                status: const Value('failed'),
                leaseExpiresAt: const Value(0),
                failureCode: Value(code),
                failureDetail: Value(detail),
                failedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  /// Same contract as [readPromptSnapshot] but keeps the reason the snapshot
  /// could not be produced, so an early writer bail stays attributable.
  Future<CardEvolutionPromptSnapshotOutcome> readPromptSnapshotOutcome({
    required String claimId,
    required String ownerId,
    required int now,
  }) => db.transaction(() async {
    final claim = await (db.select(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claimId))).getSingleOrNull();
    if (claim == null) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable(
        'claimMissing',
      );
    }
    if (claim.status != 'claimed') {
      return const CardEvolutionPromptSnapshotOutcome.unavailable(
        'claimNotClaimed',
      );
    }
    if (claim.ownerId != ownerId) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable('claimOwner');
    }
    if (claim.leaseExpiresAt <= now) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable('leaseLost');
    }
    final selection = await _selectedInputForClaim(claim);
    final selected = selection.json;
    if (selected == null) {
      return CardEvolutionPromptSnapshotOutcome.unavailable(
        selection.failureName,
      );
    }
    if (computeHash(selected) != claim.inputHash) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable(
        'inputHashMismatch',
      );
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable(
        'canonUnavailable',
      );
    }
    if (assembled.$2.requiresBaselineDecision) {
      return const CardEvolutionPromptSnapshotOutcome.unavailable(
        'baselineDecisionRequired',
      );
    }
    final assembly = assembled.$2;
    return CardEvolutionPromptSnapshotOutcome.ready(
      CardEvolutionPromptSnapshot(
        claim: claim,
        character: assembly.character,
        selectedInputJson: selected,
      ),
    );
  });

  Future<CardEvolutionFinalizeOutcome> finalize({
    required String claimId,
    required String ownerId,
    required int now,
    required String modelOutput,
    required List<RewriteOperationSnapshot> operations,
  }) => db.transaction(() async {
    final claim = await (db.select(
      db.cardEvolutionClaims,
    )..where((row) => row.id.equals(claimId))).getSingleOrNull();
    if (claim == null) {
      return const CardEvolutionFinalizeOutcome('claimMissing');
    }
    if (claim.status == 'completed') {
      final job = claim.rewriteJobId == null
          ? null
          : await (db.select(db.rewriteJobs)
                  ..where((row) => row.id.equals(claim.rewriteJobId!)))
                .getSingleOrNull();
      return CardEvolutionFinalizeOutcome('alreadyCompleted', job);
    }
    if (claim.ownerId != ownerId || claim.leaseExpiresAt <= now) {
      return const CardEvolutionFinalizeOutcome('leaseLost');
    }
    final selection = await _selectedInputForClaim(claim);
    final selected = selection.json;
    if (selected == null) {
      return CardEvolutionFinalizeOutcome(
        'staleEvidence',
        null,
        selection.failureName,
      );
    }
    if (computeHash(selected) != claim.inputHash) {
      return const CardEvolutionFinalizeOutcome(
        'staleEvidence',
        null,
        'inputHashMismatch',
      );
    }
    final assembled = await _assemble(claim.sessionId, claim.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return const CardEvolutionFinalizeOutcome('canonUnavailable');
    }
    final input = assembled.$1;
    final assembly = assembled.$2;
    final allowedCardFields = CardRewritePolicy.nonEmptyEvolutionFields(
      assembly.character,
    );
    if (!_hasEvolutionOperations(
      operations,
      allowedCardFields: allowedCardFields,
    )) {
      return const CardEvolutionFinalizeOutcome('fieldMismatch');
    }
    if (await _activeJob(claim.sessionId, claim.characterId) != null) {
      return const CardEvolutionFinalizeOutcome('activeJob');
    }
    final cardOperations = operations.whereType<CardRewriteOperationSnapshot>();
    final lorebookOperations = operations
        .whereType<LorebookRewriteOperationSnapshot>()
        .toList(growable: false);
    final allowedLoreTargets = _loreTargetsFromInput(selected);
    if (allowedLoreTargets == null ||
        lorebookOperations.any((operation) {
          final target =
              allowedLoreTargets['${operation.lorebookId}\u0000${operation.entryId}'];
          return target == null ||
              target.$1 != operation.baseContent ||
              target.$2 != operation.expectedContentHash;
        })) {
      return const CardEvolutionFinalizeOutcome('invalidLorebookOperation');
    }
    final loreOnlyObservationKeys = _loreOnlyObservationKeys(selected);
    if (cardOperations.any(
      (operation) => {
        operation.transition.scopeKey,
        ...operation.transition.affectedTrackerKeys,
        ...operation.patches.map((patch) => patch.scopeKey),
      }.any((key) => loreOnlyObservationKeys.contains(_ledgerGroupKey(key))),
    )) {
      return const CardEvolutionFinalizeOutcome('invalidCardObservationTarget');
    }
    final values = {
      for (final field in CardRewriteField.values)
        field: _fieldValue(assembly.character, field),
    };
    for (final operation in cardOperations) {
      if (operation.patches.any(
        (patch) =>
            patch.anchor.trim().length < _minimumEvolutionAnchorCodeUnits,
      )) {
        return CardEvolutionFinalizeOutcome(
          'invalidOperation',
          null,
          '${operation.field.wireName}: anchorTooShort',
        );
      }
      final validation = AnchoredScalarPatchValidator.validate(
        patches: operation.patches,
        currentCardValues: values,
        requiredFields: [operation.field],
      );
      if (!validation.isValid) {
        return CardEvolutionFinalizeOutcome(
          'invalidOperation',
          null,
          '${operation.field.wireName}: '
              '${validation.violations.map((violation) => violation.name).join(', ')}',
        );
      }
    }
    final controls = input.manualControls;
    final controlledKeys = {
      for (final operation in cardOperations) ...{
        operation.transition.scopeKey,
        ...operation.transition.affectedTrackerKeys,
        ...operation.patches.map((patch) => patch.scopeKey),
      },
    };
    if (controlledKeys.any(
      (key) => controls.any(
        (control) =>
            control.name == 'canon_override:$key' ||
            control.name == 'canon_lock:$key',
      ),
    )) {
      return const CardEvolutionFinalizeOutcome('manualControl');
    }

    final snapshots = [
      for (final operation in operations)
        RewriteOperationSnapshotCodec.encode(operation),
    ];
    final jobId = 'rewrite-job-${generateId()}';
    final operationId = 'rewrite-op-${generateId()}';
    final proposalId = 'evolution-run-${generateId()}';
    final job = await jobRepo.insertPendingInTransaction(
      jobId: jobId,
      chatSessionId: claim.sessionId,
      characterId: claim.characterId,
      requestJson: _canonicalJson({
        'fields': [
          for (final operation in cardOperations) operation.field.wireName,
        ],
        'lorebookTargets': [
          for (final operation in lorebookOperations)
            '${operation.lorebookId}:${operation.entryId}',
        ],
        'provenance': 'automatedEvolution',
        'claimId': claim.id,
        'inputHash': claim.inputHash,
      }),
      requestKey: 'automated-evolution:${claim.inputHash}',
      basisRevision: assembly.effectiveRevision.number,
      basisRevisionHash: assembly.effectiveRevision.hash,
      canonStamp: assembly.identity,
      operations: [
        for (var index = 0; index < snapshots.length; index++)
          ManualRewriteOperationDraft(
            id: index == 0 ? operationId : 'rewrite-op-${generateId()}',
            snapshotJson: snapshots[index],
            evidence: index == 0
                ? [
                    ManualRewriteEvidenceDraft(
                      id: 'rewrite-evidence-${generateId()}',
                      evidenceJson: selected,
                    ),
                  ]
                : const [],
          ),
      ],
      now: now,
    );
    await db
        .into(db.cardEvolutionProposalRuns)
        .insert(
          CardEvolutionProposalRunsCompanion.insert(
            id: proposalId,
            claimId: claim.id,
            sessionId: claim.sessionId,
            characterId: claim.characterId,
            rewriteJobId: jobId,
            chatHistoryHash: claim.chatHistoryHash,
            effectiveCanonIdentity: claim.effectiveCanonIdentity,
            selectedInputJson: selected,
            inputHash: claim.inputHash,
            modelOutput: modelOutput,
            modelOutputHash: computeHash(modelOutput),
            operationSnapshotJson: _canonicalJson(snapshots),
            createdAt: now,
          ),
        );
    await beforeCursorInsert?.call();
    final changed =
        await (db.update(db.cardEvolutionClaims)
              ..where((row) => row.id.equals(claim.id))
              ..where((row) => row.ownerId.equals(ownerId))
              ..where((row) => row.status.equals('claimed'))
              ..where((row) => row.leaseExpiresAt.isBiggerThanValue(now)))
            .write(
              CardEvolutionClaimsCompanion(
                status: const Value('completed'),
                rewriteJobId: Value(jobId),
                completedAt: Value(now),
              ),
            );
    if (changed != 1) throw StateError('evolution claim CAS changed');
    return CardEvolutionFinalizeOutcome('persisted', job);
  });

  /// Records a successful automatic writer cycle that correctly produced no
  /// operations. This prevents the same three-collector boundary from being
  /// retried after every subsequent collector while retaining no review job.
  Future<bool> completeEmptyClaim({
    required String claimId,
    required String ownerId,
    required int now,
  }) async {
    final changed =
        await (db.update(db.cardEvolutionClaims)..where(
              (row) =>
                  row.id.equals(claimId) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed') &
                  row.predecessorRunOrdinal.isBiggerThanValue(0) &
                  row.leaseExpiresAt.isBiggerThanValue(now),
            ))
            .write(
              CardEvolutionClaimsCompanion(
                status: const Value('completed'),
                completedAt: Value(now),
              ),
            );
    return changed == 1;
  }

  /// Releases an uncompleted lease after work outside the transaction fails.
  /// Claims are otherwise retained only for successful idempotency records.
  Future<void> abandonClaim({
    required String claimId,
    required String ownerId,
  }) => db.transaction(() async {
    final owned =
        await (db.select(db.cardEvolutionClaims)..where(
              (row) =>
                  row.id.equals(claimId) &
                  row.ownerId.equals(ownerId) &
                  row.status.equals('claimed'),
            ))
            .getSingleOrNull();
    if (owned == null) return;
    await (db.delete(
      db.cardEvolutionWriterCalls,
    )..where((row) => row.claimId.equals(claimId))).go();
    await (db.delete(db.cardEvolutionClaims)
          ..where((row) => row.id.equals(claimId))
          ..where((row) => row.ownerId.equals(ownerId))
          ..where((row) => row.status.equals('claimed')))
        .go();
  });

  /// Replaces the session's diagnostic record after every writer call. It is
  /// deliberately separate from the proposal transaction so rejected outputs
  /// and transport failures remain inspectable.
  Future<void> saveDebugRun({
    required String sessionId,
    required String stage,
    required String status,
    required String model,
    required String? output,
    required String attemptsJson,
    required int updatedAt,
  }) => db
      .into(db.cardEvolutionDebugRuns)
      .insertOnConflictUpdate(
        CardEvolutionDebugRunsCompanion.insert(
          sessionId: sessionId,
          stage: stage,
          status: status,
          model: model,
          output: Value(output),
          attemptsJson: attemptsJson,
          updatedAt: updatedAt,
        ),
      );

  /// Latest replaceable writer diagnostics for each stage, newest first.
  Future<List<CardEvolutionDebugRunRow>> readDebugRuns(String sessionId) =>
      (db.select(db.cardEvolutionDebugRuns)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.desc(row.updatedAt),
              (row) => OrderingTerm.asc(row.stage),
            ]))
          .get();

  /// Builds a read-only observation snapshot (character + canonical selected
  /// input) without claiming a lease. Used by the observation pass which runs
  /// before the regular claim/finalize card-writer flow.
  Future<CardEvolutionObservationSnapshot?> buildObservationSnapshot(
    String sessionId,
  ) => db.transaction(() async {
    final selected = (await _selectInput(sessionId)).json;
    if (selected == null) return null;
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return null;
    final assembled = await _assemble(sessionId, session.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) {
      return null;
    }
    return CardEvolutionObservationSnapshot(
      character: assembled.$2.character,
      selectedInputJson: selected,
    );
  });

  /// Builds collector evidence from the exact immutable anchors committed by
  /// one successful reconciliation. It deliberately does not re-run the
  /// generic mutable-tail heuristic.
  Future<CardEvolutionObservationSnapshot?> buildObservationSnapshotForRun(
    LedgerReconciliationSuccessfulRunRow run,
  ) => db.transaction(() async {
    final selected = (await _selectInput(
      run.sessionId,
      reconciliationRun: run,
    )).json;
    if (selected == null) return null;
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(run.sessionId))).getSingleOrNull();
    if (session == null) return null;
    final assembled = await _assemble(run.sessionId, session.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) return null;
    return CardEvolutionObservationSnapshot(
      character: assembled.$2.character,
      selectedInputJson: selected,
    );
  });

  /// Builds one collector snapshot from a complete logical batch. Every
  /// immutable reconciliation history remains available as evidence.
  Future<CardEvolutionObservationSnapshot?> buildObservationSnapshotForRuns(
    List<LedgerReconciliationSuccessfulRunRow> runs,
  ) => db.transaction(() async {
    if (runs.length != collectorReconciliationBatchSize ||
        runs.any((run) => run.sessionId != runs.first.sessionId)) {
      return null;
    }
    final sessionId = runs.first.sessionId;
    final selected = (await _selectInput(
      sessionId,
      reconciliationRunIds: [for (final run in runs) run.id],
    )).json;
    if (selected == null) return null;
    final session = await (db.select(
      db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return null;
    final assembled = await _assemble(sessionId, session.characterId);
    if (assembled == null || assembled.$2.requiresBaselineDecision) return null;
    return CardEvolutionObservationSnapshot(
      character: assembled.$2.character,
      selectedInputJson: selected,
    );
  });

  /// Counts successful Ledger reconciliations for the session.
  Future<int> countSuccessfulReconciliations(String sessionId) async {
    final result = await db
        .customSelect(
          'SELECT COUNT(*) AS cnt FROM reconciliation_successful_runs '
          'WHERE session_id = ?',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    return result.read<int>('cnt');
  }

  /// Marks all promoted observations for the session as consumed after a
  /// successful card writer apply. Promoted observations that were not
  /// referenced by the proposal remain promoted for the next cycle.
  Future<void> consumePromotedObservations(
    String sessionId, {
    required int now,
  }) =>
      (db.update(db.cardEvolutionObservations)
            ..where((r) => r.sessionId.equals(sessionId))
            ..where((r) => r.status.equals('promoted')))
          .write(
            CardEvolutionObservationsCompanion(
              status: const Value('consumed'),
              updatedAt: Value(now),
            ),
          );

  Future<CardEvolutionSelection> _selectedInputForClaim(
    CardEvolutionClaimRow claim,
  ) async {
    final stored = claim.selectedInputJson;
    if (stored != null && computeHash(stored) != claim.inputHash) {
      return const CardEvolutionSelection.failed(
        CardEvolutionSelectionFailure.inputHashMismatch,
      );
    }
    final runIds = await _reconciliationRunIdsForClaim(claim);
    if (claim.predecessorRunOrdinal > 0 &&
        runIds.length != _writerReconciliationRunCount) {
      return const CardEvolutionSelection.failed(
        CardEvolutionSelectionFailure.collectorRunsUnresolved,
      );
    }
    final selection = await _selectInput(
      claim.sessionId,
      reconciliationRunIds: runIds,
    );
    final selected = selection.json;
    if (selected == null) return selection;
    if (computeHash(selected) != claim.inputHash) {
      return const CardEvolutionSelection.failed(
        CardEvolutionSelectionFailure.inputHashMismatch,
      );
    }
    final snapshot = jsonDecode(selected) as Map<String, dynamic>;
    if (snapshot['chatHistoryHash'] != claim.chatHistoryHash ||
        snapshot['effectiveCanonIdentity'] != claim.effectiveCanonIdentity) {
      return const CardEvolutionSelection.failed(
        CardEvolutionSelectionFailure.claimEvidenceMismatch,
      );
    }
    return stored == null ? selection : CardEvolutionSelection.selected(stored);
  }

  Future<CardEvolutionSelection> _selectInput(
    String sessionId, {
    LedgerReconciliationSuccessfulRunRow? reconciliationRun,
    List<String> reconciliationRunIds = const [],
  }) async {
    try {
      final session = await (db.select(
        db.chatSessions,
      )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
      if (session == null) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.sessionMissing,
        );
      }
      final messages = jsonDecode(session.messagesJson);
      if (messages is! List) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.messagesMalformed,
        );
      }
      final assembled = await _assemble(sessionId, session.characterId);
      if (assembled == null) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.canonUnavailable,
        );
      }
      if (assembled.$2.requiresBaselineDecision) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.baselineDecisionRequired,
        );
      }
      final boundaryRuns = reconciliationRunIds.isEmpty
          ? <LedgerReconciliationSuccessfulRunRow>[]
          : await (db.select(
              db.ledgerReconciliationSuccessfulRuns,
            )..where((row) => row.id.isIn(reconciliationRunIds))).get();
      if (boundaryRuns.length != reconciliationRunIds.length) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.reconciliationRunsMissing,
        );
      }
      boundaryRuns.sort(
        (a, b) => reconciliationRunIds
            .indexOf(a.id)
            .compareTo(reconciliationRunIds.indexOf(b.id)),
      );
      final history = reconciliationRun != null
          ? _selectReconciliationHistory(
              messages: messages,
              run: reconciliationRun,
            )
          : boundaryRuns.isNotEmpty
          ? _selectReconciliationHistories(
              messages: messages,
              runs: boundaryRuns,
            )
          : _selectChatHistory(messages: messages);
      if (history == null) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.historyUnresolved,
        );
      }
      if (history.length < 2) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.historyTooShort,
        );
      }
      final hasUser = history.any(
        (message) => message is Map && message['role'] == 'user',
      );
      final hasAssistant = history.any(
        (message) => message is Map && message['role'] == 'assistant',
      );
      if (!hasUser || !hasAssistant) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.historyRolesIncomplete,
        );
      }
      final lorebookEntries = await _selectInjectedLorebookEntries(
        sessionId: sessionId,
        history: history,
      );
      if (lorebookEntries == null) {
        return const CardEvolutionSelection.failed(
          CardEvolutionSelectionFailure.lorebookEvidenceUnavailable,
        );
      }
      final historyJson = _canonicalJson(history);
      final canonEvidence = _canonEvidence(assembled.$1, assembled.$2, history);
      final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(
        assembled.$2.character,
      );
      final accumulatedObservations =
          await (db.select(db.cardEvolutionObservations)
                ..where((r) => r.sessionId.equals(sessionId))
                ..where((r) => r.status.isIn(const ['active', 'promoted']))
                ..orderBy([(r) => OrderingTerm.desc(r.updatedAt)]))
              .get();
      final rangeTrackerKeys = await _rangeTrackerKeys(
        sessionId: sessionId,
        reconciliationRun: reconciliationRun,
        reconciliationRuns: boundaryRuns,
        history: history,
        candidateObservationKeys: {
          for (final observation in accumulatedObservations)
            ..._decodeJsonArray(
              observation.retrievalKeysJson,
            ).whereType<String>(),
        },
      );
      final availableRetrievalTargets = _retrievalTargets(
        input: assembled.$1,
        history: history,
        lorebookEntries: lorebookEntries,
        rangeTrackerKeys: rangeTrackerKeys,
      );
      final availableKeys = availableRetrievalTargets
          .map((target) => target['key'])
          .whereType<String>()
          .toSet();
      final relevantObservations = accumulatedObservations.where(
        (observation) => _observationMatches(
          observation: observation,
          availableKeys: availableKeys,
          input: assembled.$1,
        ),
      );
      final compactObservations = _compactObservations(
        relevantObservations,
        availableKeys: availableKeys,
      );
      final selected = _canonicalJson({
        'contractVersion': 8,
        'fields': [for (final field in writableFields) field.wireName],
        'chatHistoryHash': computeHash(historyJson),
        'effectiveCanonIdentity': assembled.$2.identity,
        'limits': {
          'maxChatHistoryMessages': _maxChatHistoryMessages,
          'excludesTrailingUserAssistantPair': reconciliationRun == null,
          'reconciliationRunId': reconciliationRun?.id,
          'reconciliationRunOrdinal': reconciliationRun?.ordinal,
          'reconciliationRunIds': reconciliationRunIds,
          'reconciliationRangeHash': reconciliationRun?.rangeHash,
        },
        'chatHistory': history,
        'card': _evolutionCardSnapshot(assembled.$2.character),
        'effectiveCanon': jsonDecode(canonEvidence),
        'injectedLorebookEntries': lorebookEntries,
        'availableObservationRetrievalTargets': availableRetrievalTargets,
        'accumulatedObservations': compactObservations,
      });
      return CardEvolutionSelection.selected(selected);
    } catch (_) {
      return const CardEvolutionSelection.failed(
        CardEvolutionSelectionFailure.unexpectedError,
      );
    }
  }

  List<Map<String, Object?>> _retrievalTargets({
    required EffectiveCanonAssemblyInput input,
    required List<Object?> history,
    required List<Object?> lorebookEntries,
    required Set<String> rangeTrackerKeys,
  }) {
    const maxTargets = 80;
    final primaryTargets = <String, Map<String, Object?>>{};
    final extraTargets = <String, Map<String, Object?>>{};
    final rangeMessages = {
      for (final message in history)
        if (message is Map)
          '${message['messageId']}\u0000${message['swipeId']}\u0000${message['agentSwipeId']}',
    };
    for (final key in rangeTrackerKeys) {
      primaryTargets['ledger_tracker\u0000$key'] = {
        'kind': 'ledger_tracker',
        'key': key,
      };
    }
    for (final fact in input.facts) {
      final sourceIdentity =
          '${fact.sourceMessageId}\u0000${fact.sourceSwipeId}\u0000${fact.sourceAgentSwipeId}';
      if (!rangeMessages.contains(sourceIdentity)) {
        continue;
      }
      final factGroup = _ledgerGroupKey(fact.scopeKey);
      if (factGroup == null) continue;
      extraTargets['knowledge_fact\u0000${fact.id}'] = {
        'kind': 'knowledge_fact',
        'key': factGroup,
        'factId': fact.id,
        'scopeKey': fact.scopeKey,
        'subjectKey': fact.subjectKey,
        'subjectName': fact.subjectName,
        'predicate': fact.predicate,
        'object': _boundedText(fact.object),
      };
    }
    for (final raw in lorebookEntries) {
      if (raw is! Map ||
          raw['lorebookId'] is! String ||
          raw['entryId'] is! String) {
        continue;
      }
      final identity = '${raw['lorebookId']}:${raw['entryId']}';
      extraTargets['injected_lorebook_entry\u0000$identity'] = {
        'kind': 'injected_lorebook_entry',
        'key': identity,
      };
    }
    int compare(Map<String, Object?> a, Map<String, Object?> b) {
      final kind = (a['kind']! as String).compareTo(b['kind']! as String);
      return kind != 0
          ? kind
          : (a['key']! as String).compareTo(b['key']! as String);
    }

    final primary = primaryTargets.values.toList()..sort(compare);
    final extras = extraTargets.values.toList()..sort(compare);
    // Exact groups from this range are never displaced by fact/lorebook
    // metadata. Reconciliation itself bounds the primary set.
    return [
      ...primary,
      ...extras.take((maxTargets - primary.length).clamp(0, maxTargets)),
    ];
  }

  bool _observationMatches({
    required CardEvolutionObservationRow observation,
    required Set<String> availableKeys,
    required EffectiveCanonAssemblyInput input,
  }) {
    final keys = _decodeJsonArray(
      observation.retrievalKeysJson,
    ).whereType<String>().map((key) => _ledgerGroupKey(key) ?? key);
    if (keys.any(availableKeys.contains)) return true;
    // Legacy best effort is exact and local to identities in this snapshot.
    // It never treats an unkeyed row as globally relevant.
    final legacyScope = _ledgerGroupKey(observation.semanticScopeKey);
    if (legacyScope != null && availableKeys.contains(legacyScope)) return true;
    if (observation.lorebookEntryId case final String loreId
        when loreId.isNotEmpty && availableKeys.contains(loreId)) {
      return true;
    }
    return input.facts.any(
      (fact) =>
          fact.scopeKey.isNotEmpty &&
          (_ledgerGroupKey(fact.scopeKey) == legacyScope) &&
          availableKeys.contains(legacyScope),
    );
  }

  Future<Set<String>> _rangeTrackerKeys({
    required String sessionId,
    required LedgerReconciliationSuccessfulRunRow? reconciliationRun,
    List<LedgerReconciliationSuccessfulRunRow> reconciliationRuns = const [],
    required List<Object?> history,
    required Set<String> candidateObservationKeys,
  }) async {
    final runs = reconciliationRun != null
        ? [reconciliationRun]
        : reconciliationRuns.isNotEmpty
        ? reconciliationRuns
        : await (db.select(db.ledgerReconciliationSuccessfulRuns)
                ..where((row) => row.sessionId.equals(sessionId))
                ..orderBy([(row) => OrderingTerm.desc(row.ordinal)])
                ..limit(3))
              .get();
    final groups = <String>{};
    for (final run in runs) {
      try {
        final result = jsonDecode(run.canonicalResultJson);
        if (result is! Map || result['export'] is! Map) continue;
        final ops = (result['export'] as Map)['ops'];
        if (ops is! List) continue;
        for (final op in ops) {
          if (op is! Map || op['key'] is! String) continue;
          final key = op['key'] as String;
          final group = _ledgerGroupKey(key);
          if (group != null) groups.add(group);
          if (key == 'scene.present_entities' && op['value'] is String) {
            groups.addAll(_presentEntityGroups(op['value'] as String));
          }
        }
        final sceneState = (result['export'] as Map)['sceneState'];
        if (sceneState is Map && sceneState['presentEntities'] is List) {
          for (final raw in sceneState['presentEntities'] as List) {
            if (raw is Map && raw['name'] is String) {
              final group = _npcGroup(raw['name'] as String);
              if (group != null) groups.add(group);
            }
          }
        }
      } catch (_) {
        // Fail closed for legacy/malformed ranges.
      }
    }
    final chatText = history
        .whereType<Map<Object?, Object?>>()
        .map((message) => message['content'])
        .whereType<String>()
        .join('\n');
    for (final key in candidateObservationKeys) {
      final group = _ledgerGroupKey(key);
      if (group == null) continue;
      final subjects = _groupSearchSubjects(group);
      if (subjects.any((subject) => _containsExactToken(chatText, subject))) {
        groups.add(group);
      }
    }
    return groups;
  }

  static String? _ledgerGroupKey(String key) {
    if (key.startsWith('npc:') || key.startsWith('arc:')) {
      final dot = key.lastIndexOf('.');
      final group = dot > key.indexOf(':') + 1 ? key.substring(0, dot) : key;
      return CardRewriteScope.tryParse(group)?.key;
    }
    if (key.startsWith('relationship:')) {
      final dot = key.lastIndexOf('.');
      final group = dot > 'relationship:'.length ? key.substring(0, dot) : key;
      return CardRewriteScope.tryParse(group)?.key;
    }
    return CardRewriteScope.tryParse(key)?.key;
  }

  static Iterable<String> _presentEntityGroups(String value) sync* {
    for (final raw in value.split(RegExp(r'[;,\n]+'))) {
      final group = _npcGroup(raw);
      if (group != null) yield group;
    }
  }

  static String? _npcGroup(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final group = 'npc:$trimmed';
    return CardRewriteScope.tryParse(group)?.key;
  }

  static Iterable<String> _groupSearchSubjects(String group) sync* {
    if (group.startsWith('npc:') || group.startsWith('arc:')) {
      yield group.substring(group.indexOf(':') + 1);
      return;
    }
    if (group.startsWith('relationship:')) {
      final identities = group.substring('relationship:'.length).split(':');
      if (identities.length == 2) yield* identities;
    }
  }

  static bool _containsExactToken(String text, String subject) {
    final foldedText = text.toLowerCase();
    final foldedSubject = subject.toLowerCase();
    if (foldedSubject.isEmpty) return false;
    var start = 0;
    while (true) {
      final index = foldedText.indexOf(foldedSubject, start);
      if (index < 0) return false;
      final before = index == 0
          ? null
          : foldedText.substring(0, index).runes.last;
      final end = index + foldedSubject.length;
      final after = end == foldedText.length
          ? null
          : foldedText.substring(end).runes.first;
      if (!_isWordRune(before) && !_isWordRune(after)) return true;
      start = index + 1;
    }
  }

  static bool _isWordRune(int? rune) {
    if (rune == null) return false;
    final character = String.fromCharCode(rune);
    return RegExp(r'^[\p{L}\p{N}_]$', unicode: true).hasMatch(character);
  }

  Future<List<String>> _reconciliationRunIdsForClaim(
    CardEvolutionClaimRow claim,
  ) async {
    if (claim.predecessorRunOrdinal <= 0) return const [];
    final rows =
        await (db.select(db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(claim.sessionId))
              ..where(
                (row) => row.collectorOrdinal.isBetweenValues(
                  claim.predecessorRunOrdinal - _writerCollectorBatchSize + 1,
                  claim.predecessorRunOrdinal,
                ),
              )
              ..where((row) => row.status.equals('completed'))
              ..orderBy([(row) => OrderingTerm.asc(row.collectorOrdinal)]))
            .get();
    if (rows.length != _writerCollectorBatchSize ||
        rows.last.reconciliationChainHash != claim.predecessorCursorHash) {
      return const [];
    }
    return [
      for (final run in await CardEvolutionCollectorRunRepo(
        db,
      ).runsForCollectors(claim.sessionId, rows))
        run.id,
    ];
  }

  List<Object?>? _selectReconciliationHistories({
    required List<dynamic> messages,
    required List<LedgerReconciliationSuccessfulRunRow> runs,
  }) {
    final byIdentity = <String, Object?>{};
    for (final run in runs) {
      final history = _selectReconciliationHistory(
        messages: messages,
        run: run,
      );
      if (history == null) return null;
      for (final item in history) {
        if (item is Map) {
          byIdentity['${item['messageId']}\u0000${item['swipeId']}\u0000${item['agentSwipeId']}'] =
              item;
        }
      }
    }
    return byIdentity.values.toList();
  }

  List<Map<String, Object?>> _compactObservations(
    Iterable<CardEvolutionObservationRow> observations, {
    required Set<String> availableKeys,
  }) {
    const maxCount = 12;
    const maxCharacters = 8000;
    final sorted = observations.toList()
      ..sort((a, b) {
        final updated = b.updatedAt.compareTo(a.updatedAt);
        return updated != 0 ? updated : a.id.compareTo(b.id);
      });
    final result = <Map<String, Object?>>[];
    var characters = 0;
    for (final obs in sorted) {
      if (result.length == maxCount) break;
      final clusters = _decodeJsonClusters(obs.evidenceClustersJson);
      final recentClusters = clusters.length <= 3
          ? clusters
          : clusters.sublist(clusters.length - 3);
      final value = <String, Object?>{
        'id': obs.id,
        'status': obs.status,
        'scopeKey': obs.semanticScopeKey,
        'observedChange': obs.observedChange,
        'canonicalClaim': obs.canonicalClaim,
        'evidenceClusters': recentClusters,
        'retrievalKeys':
            _decodeJsonArray(obs.retrievalKeysJson)
                .whereType<String>()
                .map((key) => _ledgerGroupKey(key) ?? key)
                .toSet()
                .toList()
              ..sort(),
        'targetKind': obs.targetKind,
        'cardFieldPath': obs.cardFieldPath,
        'lorebookEntryId': obs.lorebookEntryId,
        'confidence': obs.confidence,
        'repeatCount': obs.repeatCount,
        'firstSeenRun': obs.firstSeenRun,
        'lastConfirmedRun': obs.lastConfirmedRun,
      };
      if (_decodeJsonArray(obs.retrievalKeysJson).isEmpty) {
        final legacyKeys = <String>{};
        final legacyScope = _ledgerGroupKey(obs.semanticScopeKey);
        if (legacyScope != null && availableKeys.contains(legacyScope)) {
          legacyKeys.add(legacyScope);
        }
        if (obs.lorebookEntryId != null &&
            availableKeys.contains(obs.lorebookEntryId)) {
          legacyKeys.add(obs.lorebookEntryId!);
        }
        value['retrievalKeys'] = legacyKeys.toList()..sort();
      }
      final size = jsonEncode(value).length;
      if (characters + size > maxCharacters) continue;
      result.add(value);
      characters += size;
    }
    return result;
  }

  Future<List<Object?>?> _selectInjectedLorebookEntries({
    required String sessionId,
    required List<Object?> history,
  }) async {
    final selected = <String, ExactLorebookManifestEntry>{};
    for (final item in history) {
      if (item is! Map || item['role'] != 'assistant') continue;
      final messageId = item['messageId'];
      final swipeId = item['swipeId'];
      final agentSwipeId = item['agentSwipeId'];
      if (messageId is! String || swipeId is! int || agentSwipeId is! int) {
        return null;
      }
      final row =
          await (db.select(db.lorebookUseManifests)
                ..where((value) => value.sessionId.equals(sessionId))
                ..where((value) => value.messageId.equals(messageId))
                ..where((value) => value.swipeId.equals(swipeId))
                ..where((value) => value.agentSwipeId.equals(agentSwipeId)))
              .getSingleOrNull();
      if (row == null) continue;
      try {
        final manifest = ExactLorebookManifest.decodeDurable({
          ...Map<String, dynamic>.from(jsonDecode(row.manifestJson) as Map),
          'canonicalHash': row.manifestHash,
        });
        for (final entry in manifest.entries) {
          selected['${entry.lorebookId}\u0000${entry.entryId}'] = entry;
        }
      } catch (_) {
        return null;
      }
    }
    final overlays = await lorebookEvolutionRepo.getByTargets(
      sessionId: sessionId,
      targets: [
        for (final entry in selected.values) (entry.lorebookId, entry.entryId),
      ],
    );
    final result = <Object?>[];
    var totalCharacters = 0;
    for (final entry in selected.values) {
      final overlay = overlays['${entry.lorebookId}\u0000${entry.entryId}'];
      final baseContent = overlay?.baseContent ?? entry.rawContent;
      final content = overlay?.content ?? entry.rawContent;
      // The base is materialized only when session evolution diverged from
      // the source entry. Without an overlay base and content are identical,
      // and echoing both would double the shared writer context for every
      // injected entry.
      final carriesBase = baseContent != content;
      final size = carriesBase
          ? baseContent.length + content.length
          : content.length;
      // Exact content is required for safe anchored lorebook patching. Omit an
      // oversized target rather than truncating and weakening CAS validation.
      if (baseContent.length > _maxLorebookEntryCharacters ||
          content.length > _maxLorebookEntryCharacters ||
          totalCharacters + size > _maxLorebookTotalCharacters) {
        continue;
      }
      result.add(<String, Object?>{
        'lorebookId': entry.lorebookId,
        'entryId': entry.entryId,
        if (carriesBase) 'baseContent': baseContent,
        'content': content,
        'expectedContentHash': CardCanonicalizer.scalarSha256(content),
      });
      totalCharacters += size;
    }
    return result;
  }

  Future<(EffectiveCanonAssemblyInput, EffectiveCanonAssembly)?> _assemble(
    String sessionId,
    String characterId,
  ) async {
    try {
      final input = await canonReader.readInTransaction(
        sessionId: sessionId,
        characterId: characterId,
      );
      // The automated evolution lane stamps canon with the stable identity:
      // the per-turn Ledger mutates committed trackers and facts every turn,
      // which would invalidate every automated proposal within a minute.
      // Per-operation anchor CAS and evidence validation carry the safety.
      return (
        input,
        const EffectiveCanonAssembler().assemble(
          input,
          stampVolatileState: false,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<RewriteJobRow?> _activeJob(String sessionId, String characterId) =>
      (db.select(db.rewriteJobs)
            ..where((row) => row.chatSessionId.equals(sessionId))
            ..where((row) => row.characterId.equals(characterId))
            ..where((row) => row.status.isIn(const ['generating', 'pending']))
            ..limit(1))
          .getSingleOrNull();

  List<Object?>? _selectChatHistory({required List<dynamic> messages}) {
    final candidates = <Map<String, Object?>>[];
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (message is! Map || message['isHidden'] == true) continue;
      final id = message['id'];
      final role = message['role'];
      if (id is! String || (role != 'user' && role != 'assistant')) continue;
      final swipeId = message['swipeId'] as int? ?? 0;
      final agentSwipeId = message['agentSwipeId'] as int? ?? 0;
      final content = _anchoredContent(message, swipeId, agentSwipeId);
      if (content == null) return null;
      candidates.add({
        'messageId': id,
        'role': role,
        'swipeId': swipeId,
        'agentSwipeId': agentSwipeId,
        'content': content,
        'contentHash': computeHash(content),
      });
    }
    // The final assistant response remains mutable until the user follows up.
    // Its user prompt is omitted with it, so both chat evidence and the Ledger
    // snapshot describe only accepted turns.
    final stableCandidates = List<Map<String, Object?>>.from(candidates);
    if (stableCandidates.length >= 2 &&
        stableCandidates[stableCandidates.length - 2]['role'] == 'user' &&
        stableCandidates.last['role'] == 'assistant') {
      stableCandidates.removeRange(
        stableCandidates.length - 2,
        stableCandidates.length,
      );
    }
    final start = stableCandidates.length > _maxChatHistoryMessages
        ? stableCandidates.length - _maxChatHistoryMessages
        : 0;
    final result = stableCandidates.sublist(start, stableCandidates.length);
    return result.isEmpty ? null : result;
  }

  List<Object?>? _selectReconciliationHistory({
    required List<dynamic> messages,
    required LedgerReconciliationSuccessfulRunRow run,
  }) {
    try {
      final decoded = jsonDecode(run.anchorsJson);
      if (decoded is! List || decoded.isEmpty) return null;
      final byId = <String, Map<Object?, Object?>>{};
      for (final message in messages) {
        if (message is Map && message['id'] is String) {
          byId[message['id'] as String] = message;
        }
      }
      final result = <Map<String, Object?>>[];
      for (final raw in decoded) {
        if (raw is! Map ||
            raw['messageId'] is! String ||
            raw['swipeId'] is! int ||
            raw['agentSwipeId'] is! int ||
            raw['role'] is! String ||
            raw['contentHash'] is! String) {
          return null;
        }
        final message = byId[raw['messageId'] as String];
        if (message == null || message['role'] != raw['role']) return null;
        final content = _anchoredContent(
          message,
          raw['swipeId'] as int,
          raw['agentSwipeId'] as int,
        );
        if (content == null || computeHash(content) != raw['contentHash']) {
          return null;
        }
        result.add({
          'messageId': raw['messageId'],
          'role': raw['role'],
          'swipeId': raw['swipeId'],
          'agentSwipeId': raw['agentSwipeId'],
          'content': content,
          'contentHash': raw['contentHash'],
        });
      }
      final start = result.length > _maxChatHistoryMessages
          ? result.length - _maxChatHistoryMessages
          : 0;
      return result.sublist(start);
    } catch (_) {
      return null;
    }
  }

  String _canonEvidence(
    EffectiveCanonAssemblyInput input,
    EffectiveCanonAssembly assembly,
    List<Object?> history,
  ) => _canonicalJson({
    'identity': assembly.identity,
    'revision': {
      'number': assembly.effectiveRevision.number,
      'hash': assembly.effectiveRevision.hash,
    },
    'trackers': [
      for (final tracker in input.committedTrackers.take(80))
        {
          'name': tracker.name,
          'value': _boundedText(tracker.value),
          'scope': tracker.scope,
          'provenance': tracker.provenance,
        },
    ],
    'facts': [
      for (final fact
          in input.facts
              .where((fact) {
                return history.any(
                  (message) =>
                      message is Map &&
                      message['messageId'] == fact.sourceMessageId &&
                      message['swipeId'] == fact.sourceSwipeId &&
                      message['agentSwipeId'] == fact.sourceAgentSwipeId,
                );
              })
              .take(40))
        {
          'scopeKey': fact.scopeKey,
          'predicate': fact.predicate,
          'object': _boundedText(fact.object),
          'epistemicState': fact.epistemicState.wireName,
          'confidence': fact.confidence,
          'importance': fact.importance,
        },
    ],
    'transitions': [
      for (final transition in input.transitions.take(40))
        {
          'scopeKey': transition.semanticScopeKey,
          'canonicalClaim': _boundedText(transition.canonicalClaim),
          'promotionDestination': _boundedText(transition.promotionDestination),
        },
    ],
  });
}

String _boundedText(String value) => value.length <= _maxCanonValueCharacters
    ? value
    : value.substring(0, _maxCanonValueCharacters);

bool _hasEvolutionOperations(
  List<RewriteOperationSnapshot> operations, {
  required Set<CardRewriteField> allowedCardFields,
}) {
  final cards = operations.whereType<CardRewriteOperationSnapshot>().toList();
  final lores = operations
      .whereType<LorebookRewriteOperationSnapshot>()
      .toList();
  final fields = cards.map((operation) => operation.field).toSet();
  final targets = lores
      .map((operation) => '${operation.lorebookId}\u0000${operation.entryId}')
      .toSet();
  return operations.isNotEmpty &&
      fields.length == cards.length &&
      targets.length == lores.length &&
      allowedCardFields.containsAll(fields);
}

Map<String, (String, String)>? _loreTargetsFromInput(String selectedInputJson) {
  try {
    final input = jsonDecode(selectedInputJson) as Map;
    final entries = input['injectedLorebookEntries'];
    if (entries is! List) return null;
    final result = <String, (String, String)>{};
    for (final raw in entries) {
      // Entries without session evolution carry no separate base; their
      // current content is the CAS base the model must echo.
      final base = raw is Map ? raw['baseContent'] ?? raw['content'] : null;
      if (raw is! Map ||
          raw['lorebookId'] is! String ||
          raw['entryId'] is! String ||
          base is! String ||
          raw['expectedContentHash'] is! String) {
        return null;
      }
      result['${raw['lorebookId']}\u0000${raw['entryId']}'] = (
        base,
        raw['expectedContentHash'] as String,
      );
    }
    return result;
  } catch (_) {
    return null;
  }
}

Set<String> _loreOnlyObservationKeys(String selectedInputJson) {
  try {
    final input = jsonDecode(selectedInputJson) as Map;
    final observations = input['accumulatedObservations'];
    if (observations is! List) return const {};
    return {
      for (final observation in observations)
        if (observation is Map &&
            observation['targetKind'] == 'injected_lorebook_entry' &&
            observation['retrievalKeys'] is List)
          for (final key in observation['retrievalKeys'] as List)
            if (key is String) key,
    };
  } catch (_) {
    return const {};
  }
}

List<Object?> _decodeJsonArray(String encoded) {
  try {
    final decoded = jsonDecode(encoded);
    return decoded is List ? decoded : const [];
  } catch (_) {
    return const [];
  }
}

List<Object?> _decodeJsonClusters(String encoded) {
  try {
    final decoded = jsonDecode(encoded);
    return decoded is List ? decoded : const [];
  } catch (_) {
    return const [];
  }
}

String? _anchoredContent(
  Map<Object?, Object?> message,
  int swipeId,
  int agentSwipeId,
) {
  final swipes = message['swipes'];
  final String content;
  if (swipes is List && swipes.isNotEmpty) {
    if (swipeId < 0 || swipeId >= swipes.length || swipes[swipeId] is! String) {
      return null;
    }
    content = swipes[swipeId] as String;
  } else {
    if (swipeId != 0 || message['content'] is! String) return null;
    content = message['content'] as String;
  }
  final agentSwipes = message['agentSwipes'];
  if (agentSwipes is List && agentSwipes.isNotEmpty) {
    if (agentSwipeId < 0 || agentSwipeId >= agentSwipes.length) return null;
    final agent = agentSwipes[agentSwipeId];
    return agent is Map && agent['content'] is String
        ? agent['content'] as String
        : null;
  }
  return agentSwipeId == 0 ? content : null;
}

String? _fieldValue(Character character, CardRewriteField field) =>
    switch (field) {
      CardRewriteField.description => character.description,
      CardRewriteField.personality => character.personality,
      CardRewriteField.scenario => character.scenario,
      CardRewriteField.systemPrompt => character.systemPrompt,
      CardRewriteField.postHistoryInstructions =>
        character.postHistoryInstructions,
      CardRewriteField.creatorNotes => character.creatorNotes,
    };

Map<String, Object?> _evolutionCardSnapshot(Character character) {
  final snapshot = Map<String, Object?>.from(
    CardCanonicalizer.snapshot(character),
  );
  final writableFields = CardRewritePolicy.nonEmptyEvolutionFields(character);
  for (final field in CardRewritePolicy.evolutionFields) {
    if (!writableFields.contains(field)) snapshot.remove(field.wireName);
  }
  return snapshot;
}

String _canonicalJson(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is Iterable) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}

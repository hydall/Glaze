import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/chat_message.dart';
import '../../utils/cast_helpers.dart';
import '../app_db.dart';

/// A versioned, exact projection of one message variation.
final class ReconciliationAnchor {
  const ReconciliationAnchor({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.role,
    required this.contentHash,
  });
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String role;
  final String contentHash;
  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'swipeId': swipeId,
    'agentSwipeId': agentSwipeId,
    'role': role,
    'contentHash': contentHash,
  };
}

/// An accepted immutable lorebook manifest, including its exact variation anchor.
final class AcceptedManifestRef {
  const AcceptedManifestRef({
    required this.acceptanceId,
    required this.sessionId,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.manifestHash,
    required this.acceptedByUserMessageId,
  });
  final String acceptanceId;
  final String sessionId;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String manifestHash;
  final String acceptedByUserMessageId;
  Map<String, dynamic> toJson() => {
    'acceptanceId': acceptanceId,
    'sessionId': sessionId,
    'messageId': messageId,
    'swipeId': swipeId,
    'agentSwipeId': agentSwipeId,
    'manifestHash': manifestHash,
    'acceptedByUserMessageId': acceptedByUserMessageId,
  };
}

final class LedgerReconciliationRun {
  const LedgerReconciliationRun({
    required this.id,
    required this.sessionId,
    required this.ordinal,
    required this.anchors,
    required this.acceptedManifestRefs,
    required this.effectiveCanonStamp,
    required this.effectiveCanonRevision,
    required this.effectiveCanonHash,
    required this.canonicalResult,
    required this.predecessorChainHash,
    required this.contractVersion,
    required this.opsApplied,
    required this.createdAt,
  });
  final String id,
      sessionId,
      effectiveCanonStamp,
      effectiveCanonHash,
      predecessorChainHash;
  final int ordinal, effectiveCanonRevision, contractVersion, createdAt;
  final List<ReconciliationAnchor> anchors;
  final List<AcceptedManifestRef> acceptedManifestRefs;
  final Map<String, dynamic> canonicalResult;
  final List<String> opsApplied;
  ReconciliationAnchor get start => anchors.first;
  ReconciliationAnchor get end => anchors.last;
  String get anchorsJson =>
      _canonicalJson(anchors.map((a) => a.toJson()).toList());
  String get rangeHash => computeHash(anchorsJson);
  String get manifestsJson =>
      _canonicalJson(acceptedManifestRefs.map((a) => a.toJson()).toList());
  String get resultJson => _canonicalJson(canonicalResult);
  String get opsJson => _canonicalJson(opsApplied);
  String get contentHash => computeHash(
    _canonicalJson({
      'anchorSchemaVersion': 1,
      'sessionId': sessionId,
      'anchors': anchors.map((a) => a.toJson()).toList(),
      'rangeHash': rangeHash,
      'acceptedManifestRefs': acceptedManifestRefs
          .map((a) => a.toJson())
          .toList(),
      'effectiveCanonStamp': effectiveCanonStamp,
      'effectiveCanonRevision': effectiveCanonRevision,
      'effectiveCanonHash': effectiveCanonHash,
      'canonicalResult': canonicalResult,
      'cleanupOps': opsApplied,
      'contractVersion': contractVersion,
    }),
  );
  String get chainHash => computeHash(
    _canonicalJson({
      'sessionId': sessionId,
      'ordinal': ordinal,
      'predecessorChainHash': predecessorChainHash,
      'contentHash': contentHash,
    }),
  );
}

final class ReconciliationStateSnapshot {
  const ReconciliationStateSnapshot({
    required this.ledgerJson,
    required this.knowledgeJson,
  });

  final String ledgerJson;
  final String knowledgeJson;

  String get hash => computeHash(
    _canonicalJson({
      'ledger': jsonDecode(ledgerJson),
      'knowledge': jsonDecode(knowledgeJson),
    }),
  );
}

sealed class ReconciliationEffectValidation {
  const ReconciliationEffectValidation();
}

final class ReconciliationEffectValid extends ReconciliationEffectValidation {
  const ReconciliationEffectValid({required this.before, required this.after});

  final ReconciliationStateSnapshot before;
  final ReconciliationStateSnapshot after;
}

final class ReconciliationEffectInvalid extends ReconciliationEffectValidation {
  const ReconciliationEffectInvalid(this.reason);

  final String reason;
}

sealed class ReconciliationRunIntegrity {
  const ReconciliationRunIntegrity();
}

final class ReconciliationRunValid extends ReconciliationRunIntegrity {
  const ReconciliationRunValid();
}

final class ReconciliationRunMalformed extends ReconciliationRunIntegrity {
  const ReconciliationRunMalformed(this.reason);
  final String reason;
}

final class ReconciliationRunChainGap extends ReconciliationRunIntegrity {
  const ReconciliationRunChainGap(this.reason);
  final String reason;
}

final class ReconciliationRunConcurrencyConflict
    extends ReconciliationRunIntegrity {
  const ReconciliationRunConcurrencyConflict(this.reason);
  final String reason;
}

final class ReconciliationRunAppended extends ReconciliationRunIntegrity {
  const ReconciliationRunAppended();
}

final class ReconciliationRunIdempotent extends ReconciliationRunIntegrity {
  const ReconciliationRunIdempotent();
}

final class ReconciliationRunConflict extends ReconciliationRunIntegrity {
  const ReconciliationRunConflict(this.reason);
  final String reason;
}

sealed class ReconciliationHeadInvalidationOutcome {
  const ReconciliationHeadInvalidationOutcome();
}

final class ReconciliationHeadInvalidated
    extends ReconciliationHeadInvalidationOutcome {
  const ReconciliationHeadInvalidated();
}

final class ReconciliationHeadInvalidationConflict
    extends ReconciliationHeadInvalidationOutcome {
  const ReconciliationHeadInvalidationConflict(this.reason);

  final String reason;
}

class LedgerReconciliationRunRepo {
  LedgerReconciliationRunRepo(this._db);
  final AppDatabase _db;

  Future<bool> anchorsMatchSession(LedgerReconciliationRun run) =>
      _anchorsMatchSession(run);

  /// Content hashes bind a run to its session, but legacy branch copies could
  /// move the content-derived global id to another session. Keep the compact
  /// historical id when available and deterministically namespace collisions.
  Future<String> allocateId(String sessionId, String contentHash) async {
    final contentId = 'reconciliation-$contentHash';
    final occupied = await (_db.select(
      _db.ledgerReconciliationSuccessfulRuns,
    )..where((row) => row.id.equals(contentId))).getSingleOrNull();
    if (occupied == null || occupied.sessionId == sessionId) return contentId;
    return 'reconciliation-${computeHash('$sessionId\u001f$contentHash')}';
  }

  /// Caller owns the transaction. This method never opens a nested transaction.
  Future<ReconciliationRunIntegrity> append(LedgerReconciliationRun run) async {
    final valid = await _validate(run);
    if (valid is! ReconciliationRunValid) {
      return valid;
    }
    final existing = await getByContentHash(run.sessionId, run.contentHash);
    if (existing != null) {
      return _same(existing, run)
          ? const ReconciliationRunIdempotent()
          : const ReconciliationRunConflict(
              'content hash replay differs from immutable full row',
            );
    }
    // Appending must retain the physical chain even when a prior run has been
    // invalidated; invalidation changes the read projection, never history.
    final head = await _physicalHead(run.sessionId);
    final expectedOrdinal = head == null ? 1 : head.ordinal + 1;
    final expectedPredecessor = head?.chainHash ?? '';
    if (run.ordinal != expectedOrdinal ||
        run.predecessorChainHash != expectedPredecessor) {
      return const ReconciliationRunConcurrencyConflict(
        'head changed or ordinal is not contiguous',
      );
    }
    try {
      await _db
          .into(_db.ledgerReconciliationSuccessfulRuns)
          .insert(
            LedgerReconciliationSuccessfulRunsCompanion.insert(
              id: run.id,
              sessionId: run.sessionId,
              ordinal: run.ordinal,
              startMessageId: run.start.messageId,
              startSwipeId: run.start.swipeId,
              startAgentSwipeId: run.start.agentSwipeId,
              endMessageId: run.end.messageId,
              endSwipeId: run.end.swipeId,
              endAgentSwipeId: run.end.agentSwipeId,
              anchorsJson: run.anchorsJson,
              rangeHash: run.rangeHash,
              acceptedManifestRefsJson: run.manifestsJson,
              effectiveCanonStamp: run.effectiveCanonStamp,
              effectiveCanonRevision: run.effectiveCanonRevision,
              effectiveCanonHash: run.effectiveCanonHash,
              canonicalResultJson: run.resultJson,
              contentHash: run.contentHash,
              predecessorChainHash: run.predecessorChainHash,
              chainHash: run.chainHash,
              contractVersion: run.contractVersion,
              opsAppliedJson: run.opsJson,
              createdAt: run.createdAt,
            ),
          );
      return const ReconciliationRunAppended();
    } catch (_) {
      final raced = await getByContentHash(run.sessionId, run.contentHash);
      return raced != null && _same(raced, run)
          ? const ReconciliationRunIdempotent()
          : const ReconciliationRunConcurrencyConflict(
              'immutable unique run identity conflict',
            );
    }
  }

  /// Caller owns the transaction. Allocates from the physical append head, not
  /// the invalidation-filtered read projection.
  Future<ReconciliationRunIntegrity> appendCandidate(
    LedgerReconciliationRun candidate,
  ) async {
    final existing = await getByContentHash(
      candidate.sessionId,
      candidate.contentHash,
    );
    final head = existing ?? await _physicalHead(candidate.sessionId);
    final replay = existing != null;
    final allocated = LedgerReconciliationRun(
      id: replay
          ? existing.id
          : await allocateId(candidate.sessionId, candidate.contentHash),
      sessionId: candidate.sessionId,
      ordinal: replay ? head!.ordinal : (head == null ? 1 : head.ordinal + 1),
      anchors: candidate.anchors,
      acceptedManifestRefs: candidate.acceptedManifestRefs,
      effectiveCanonStamp: candidate.effectiveCanonStamp,
      effectiveCanonRevision: candidate.effectiveCanonRevision,
      effectiveCanonHash: candidate.effectiveCanonHash,
      canonicalResult: candidate.canonicalResult,
      predecessorChainHash: replay
          ? head!.predecessorChainHash
          : head?.chainHash ?? '',
      contractVersion: candidate.contractVersion,
      opsApplied: candidate.opsApplied,
      createdAt: candidate.createdAt,
    );
    return append(allocated);
  }

  /// Exact variation acceptance only; selection evidence never becomes a ref.
  Future<List<AcceptedManifestRef>> readAcceptedManifestRefs({
    required String sessionId,
    required Iterable<ReconciliationAnchor> anchors,
  }) async {
    final refs = <AcceptedManifestRef>[];
    for (final anchor in anchors.where((item) => item.role == 'assistant')) {
      final acceptance =
          await (_db.select(_db.lorebookUseAcceptanceRecords)
                ..where((row) => row.sessionId.equals(sessionId))
                ..where((row) => row.messageId.equals(anchor.messageId))
                ..where((row) => row.swipeId.equals(anchor.swipeId))
                ..where((row) => row.agentSwipeId.equals(anchor.agentSwipeId))
                ..where((row) => row.acceptanceKind.equals('variation')))
              .getSingleOrNull();
      if (acceptance == null) continue;
      final manifest =
          await (_db.select(_db.lorebookUseManifests)
                ..where((row) => row.sessionId.equals(sessionId))
                ..where((row) => row.messageId.equals(anchor.messageId))
                ..where((row) => row.swipeId.equals(anchor.swipeId))
                ..where((row) => row.agentSwipeId.equals(anchor.agentSwipeId)))
              .getSingleOrNull();
      if (manifest == null || acceptance.acceptedByUserMessageId == null) {
        throw StateError('accepted variation provenance is incomplete');
      }
      if (!await _isAcceptingUser(
        sessionId: sessionId,
        assistantMessageId: anchor.messageId,
        userMessageId: acceptance.acceptedByUserMessageId!,
      )) {
        throw StateError('accepted variation provenance is incomplete');
      }
      refs.add(
        AcceptedManifestRef(
          acceptanceId: acceptance.acceptanceId,
          sessionId: sessionId,
          messageId: anchor.messageId,
          swipeId: anchor.swipeId,
          agentSwipeId: anchor.agentSwipeId,
          manifestHash: manifest.manifestHash,
          acceptedByUserMessageId: acceptance.acceptedByUserMessageId!,
        ),
      );
    }
    return refs;
  }

  Future<LedgerReconciliationSuccessfulRunRow?> getByContentHash(
    String sessionId,
    String contentHash,
  ) =>
      (_db.select(_db.ledgerReconciliationSuccessfulRuns)..where(
            (r) =>
                r.sessionId.equals(sessionId) &
                r.contentHash.equals(contentHash),
          ))
          .getSingleOrNull();
  Future<LedgerReconciliationSuccessfulRunRow?> _physicalHead(
    String sessionId,
  ) =>
      (_db.select(_db.ledgerReconciliationSuccessfulRuns)
            ..where((r) => r.sessionId.equals(sessionId))
            ..orderBy([(r) => OrderingTerm.desc(r.ordinal)])
            ..limit(1))
          .getSingleOrNull();

  /// Invalidates exactly the expected current logical head. The caller owns
  /// the transaction; no suffix inference or derived-state mutation occurs.
  Future<ReconciliationHeadInvalidationOutcome> invalidateLatestForReplacement({
    required String sessionId,
    required String expectedRunId,
    required String expectedChainHash,
    required int createdAt,
  }) async {
    final integrity = await validateChain(sessionId);
    if (integrity is! ReconciliationRunValid) {
      return const ReconciliationHeadInvalidationConflict(
        'reconciliation chain is invalid',
      );
    }
    final head = await getHead(sessionId);
    if (head == null ||
        head.id != expectedRunId ||
        head.chainHash != expectedChainHash) {
      return const ReconciliationHeadInvalidationConflict(
        'logical reconciliation head changed',
      );
    }
    final inserted = await _db
        .into(_db.ledgerReconciliationRunInvalidations)
        .insert(
          LedgerReconciliationRunInvalidationsCompanion.insert(
            sessionId: sessionId,
            runId: expectedRunId,
            causeMessageId: head.endMessageId,
            reason: 'latest_head_replaced',
            createdAt: createdAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (inserted == 0) {
      return const ReconciliationHeadInvalidationConflict(
        'logical reconciliation head was already invalidated',
      );
    }
    return const ReconciliationHeadInvalidated();
  }

  /// Logically invalidates the first reconciliation whose immutable evidence
  /// references one of [messageIds], plus its already-written causal suffix.
  /// Trigger messages are not anchors, so deleting a trigger does not touch the
  /// completed range it caused.
  ///
  /// Caller owns the surrounding transaction.
  Future<List<String>> invalidateForMessageMutation({
    required String sessionId,
    required Set<String> messageIds,
    required String reason,
    required int createdAt,
  }) async {
    if (messageIds.isEmpty) return const [];
    final rows =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
            .get();
    final existingInvalidations = await (_db.select(
      _db.ledgerReconciliationRunInvalidations,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    final alreadyInvalidated = existingInvalidations
        .map((row) => row.runId)
        .toSet();
    var firstAffected = -1;
    for (var i = 0; i < rows.length; i++) {
      if (alreadyInvalidated.contains(rows[i].id)) continue;
      try {
        final anchors = _decodeAnchors(rows[i].anchorsJson);
        if (anchors.any((anchor) => messageIds.contains(anchor.messageId))) {
          firstAffected = i;
          break;
        }
      } catch (_) {
        // Malformed immutable history remains an integrity failure; mutation
        // invalidation must not disguise it.
        return const [];
      }
    }
    if (firstAffected < 0) return const [];
    final affected = rows.sublist(firstAffected);
    for (final row in affected) {
      await _db
          .into(_db.ledgerReconciliationRunInvalidations)
          .insert(
            LedgerReconciliationRunInvalidationsCompanion.insert(
              sessionId: sessionId,
              runId: row.id,
              causeMessageId: messageIds.first,
              reason: reason,
              createdAt: createdAt,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }

    // Observations are aggregates rather than per-collector events, so a
    // suffix-only rollback cannot reliably subtract confirmations or
    // promotions derived from invalid evidence. Reset the derived collector
    // lane and rebuild it from the valid reconciliation backlog.
    final affectedIds = affected.map((row) => row.id).toSet();
    final hasAffectedCollector =
        await (_db.select(_db.cardEvolutionCollectorRuns)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.reconciliationRunId.isIn(affectedIds))
              ..limit(1))
            .getSingleOrNull();
    if (hasAffectedCollector != null) {
      await (_db.delete(
        _db.cardEvolutionCollectorRuns,
      )..where((row) => row.sessionId.equals(sessionId))).go();
      await (_db.delete(
        _db.cardEvolutionObservations,
      )..where((row) => row.sessionId.equals(sessionId))).go();
    }
    return affectedIds.toList(growable: false);
  }

  /// Rebuilds the transferable reconciliation prefix for a branched session.
  /// Run identities and hashes bind the session id, so source rows must never
  /// be copied directly. Runs with accepted lorebook refs remain fail-closed
  /// until their complete source provenance can be re-keyed for the branch.
  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final rows = await readSession(fromSessionId);
    if (rows.isEmpty) return;
    var predecessor = '';
    var ordinal = 1;
    for (final row in rows) {
      final anchors = _decodeAnchors(row.anchorsJson);
      final refs = _decodeRefs(row.acceptedManifestRefsJson);
      if (!anchors.every((anchor) => messageIds.contains(anchor.messageId)) ||
          refs.isNotEmpty) {
        break;
      }
      final result = jsonDecode(row.canonicalResultJson);
      final ops = jsonDecode(row.opsAppliedJson);
      if (result is! Map<Object?, Object?> || ops is! List) break;
      var run = LedgerReconciliationRun(
        id: '',
        sessionId: toSessionId,
        ordinal: ordinal,
        anchors: anchors,
        acceptedManifestRefs: const [],
        effectiveCanonStamp: row.effectiveCanonStamp,
        effectiveCanonRevision: row.effectiveCanonRevision,
        effectiveCanonHash: row.effectiveCanonHash,
        canonicalResult: Map<String, dynamic>.from(result),
        predecessorChainHash: predecessor,
        contractVersion: row.contractVersion,
        opsApplied: List<String>.from(ops),
        createdAt: row.createdAt,
      );
      run = LedgerReconciliationRun(
        id: await allocateId(toSessionId, run.contentHash),
        sessionId: run.sessionId,
        ordinal: run.ordinal,
        anchors: run.anchors,
        acceptedManifestRefs: run.acceptedManifestRefs,
        effectiveCanonStamp: run.effectiveCanonStamp,
        effectiveCanonRevision: run.effectiveCanonRevision,
        effectiveCanonHash: run.effectiveCanonHash,
        canonicalResult: run.canonicalResult,
        predecessorChainHash: run.predecessorChainHash,
        contractVersion: run.contractVersion,
        opsApplied: run.opsApplied,
        createdAt: run.createdAt,
      );
      final appended = await append(run);
      if (appended is! ReconciliationRunAppended &&
          appended is! ReconciliationRunIdempotent) {
        break;
      }
      predecessor = run.chainHash;
      ordinal++;
    }
  }

  /// A head is authoritative only if the whole durable chain is canonical and
  /// the latest run remains valid in the public read projection.
  Future<LedgerReconciliationSuccessfulRunRow?> getHead(
    String sessionId,
  ) async {
    final rows = await readSession(sessionId);
    return rows.isEmpty ? null : rows.last;
  }

  /// Complete immutable history, including logically invalidated runs.
  ///
  /// Unlike [readSession], this audit view does not hide malformed, stale, or
  /// invalidated rows. Callers must pair it with [validateChain] and
  /// [readInvalidations] before presenting a run as current.
  Future<List<LedgerReconciliationSuccessfulRunRow>> readPhysicalSession(
    String sessionId,
  ) =>
      (_db.select(_db.ledgerReconciliationSuccessfulRuns)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([(row) => OrderingTerm.asc(row.ordinal)]))
          .get();

  Future<List<LedgerReconciliationRunInvalidationRow>> readInvalidations(
    String sessionId,
  ) =>
      (_db.select(_db.ledgerReconciliationRunInvalidations)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();

  Future<LedgerReconciliationEffectRow?> readEffect(String runId) =>
      (_db.select(
        _db.ledgerReconciliationEffects,
      )..where((row) => row.runId.equals(runId))).getSingleOrNull();

  Future<List<LedgerReconciliationEffectRow>> readEffects(String sessionId) =>
      (_db.select(_db.ledgerReconciliationEffects)
            ..where((row) => row.sessionId.equals(sessionId))
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.runId),
            ]))
          .get();

  Future<ReconciliationEffectValidation> validateEffect(
    LedgerReconciliationSuccessfulRunRow run,
  ) async {
    final effect = await readEffect(run.id);
    if (effect == null) {
      return const ReconciliationEffectInvalid('exact effect is unavailable');
    }
    if (effect.sessionId != run.sessionId || effect.runId != run.id) {
      return const ReconciliationEffectInvalid(
        'effect does not belong to the reconciliation run',
      );
    }
    try {
      final before = ReconciliationStateSnapshot(
        ledgerJson: _validateCanonicalRowList(effect.beforeLedgerJson),
        knowledgeJson: _validateCanonicalRowList(effect.beforeKnowledgeJson),
      );
      final after = ReconciliationStateSnapshot(
        ledgerJson: _validateCanonicalRowList(effect.afterLedgerJson),
        knowledgeJson: _validateCanonicalRowList(effect.afterKnowledgeJson),
      );
      final expectedEffects = _canonicalJson({
        'ledger': _diffRows(
          jsonDecode(before.ledgerJson) as List,
          jsonDecode(after.ledgerJson) as List,
          identityKey: 'name',
        ),
        'knowledge': _diffRows(
          jsonDecode(before.knowledgeJson) as List,
          jsonDecode(after.knowledgeJson) as List,
          identityKey: 'id',
        ),
      });
      if (before.hash != effect.beforeStateHash ||
          after.hash != effect.afterStateHash ||
          effect.actualEffectsJson != expectedEffects ||
          effect.effectsHash != computeHash(expectedEffects)) {
        return const ReconciliationEffectInvalid(
          'effect integrity hashes do not match its state',
        );
      }
      return ReconciliationEffectValid(before: before, after: after);
    } catch (_) {
      return const ReconciliationEffectInvalid(
        'effect contains malformed state',
      );
    }
  }

  Future<bool> currentStateMatches(
    String sessionId,
    ReconciliationStateSnapshot expected,
  ) async => (await captureState(sessionId)).hash == expected.hash;

  /// Reconstructs the exact active message variations bound by [run].
  /// Returns null if the transcript, ordering, or selected variation changed.
  Future<List<ChatMessage>?> reconstructSelectedMessages(
    LedgerReconciliationSuccessfulRunRow run,
  ) async {
    try {
      final anchors = _decodeAnchors(run.anchorsJson);
      final session = await (_db.select(
        _db.chatSessions,
      )..where((row) => row.sessionId.equals(run.sessionId))).getSingleOrNull();
      if (session == null) return null;
      final decoded = jsonDecode(session.messagesJson);
      if (decoded is! List) return null;
      final messages = decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => ChatMessage.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList(growable: false);
      final selected = <ChatMessage>[];
      var previousIndex = -1;
      for (final anchor in anchors) {
        final index = messages.indexWhere(
          (message) => message.id == anchor.messageId,
        );
        if (index <= previousIndex) return null;
        previousIndex = index;
        final message = messages[index];
        if (message.role != anchor.role ||
            message.swipeId != anchor.swipeId ||
            message.agentSwipeId != anchor.agentSwipeId ||
            computeHash(message.content) != anchor.contentHash ||
            message.isHidden ||
            message.isError ||
            message.isTyping ||
            message.content.trim().isEmpty) {
          return null;
        }
        selected.add(message);
      }
      return List.unmodifiable(selected);
    } catch (_) {
      return null;
    }
  }

  /// Captures the complete reconciliation-owned state in canonical order.
  /// Caller may invoke this inside the reconciliation transaction.
  Future<ReconciliationStateSnapshot> captureState(String sessionId) async {
    final ledger =
        await (_db.select(_db.trackerRows)
              ..where((row) => row.sessionId.equals(sessionId))
              ..where((row) => row.scope.equals('ledger'))
              ..orderBy([(row) => OrderingTerm.asc(row.name)]))
            .get();
    final knowledge =
        await (_db.select(_db.characterKnowledgeFactRows)
              ..where((row) => row.chatSessionId.equals(sessionId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    return ReconciliationStateSnapshot(
      ledgerJson: _canonicalJson(ledger.map((row) => row.toJson()).toList()),
      knowledgeJson: _canonicalJson(
        knowledge.map((row) => row.toJson()).toList(),
      ),
    );
  }

  /// Persists exact effects once. Caller owns the surrounding transaction.
  Future<void> recordEffect({
    required String runId,
    required String sessionId,
    required ReconciliationStateSnapshot before,
    required ReconciliationStateSnapshot after,
    required int createdAt,
  }) async {
    final effectsJson = _canonicalJson({
      'ledger': _diffRows(
        jsonDecode(before.ledgerJson) as List,
        jsonDecode(after.ledgerJson) as List,
        identityKey: 'name',
      ),
      'knowledge': _diffRows(
        jsonDecode(before.knowledgeJson) as List,
        jsonDecode(after.knowledgeJson) as List,
        identityKey: 'id',
      ),
    });
    await _db
        .into(_db.ledgerReconciliationEffects)
        .insert(
          LedgerReconciliationEffectsCompanion.insert(
            runId: runId,
            sessionId: sessionId,
            beforeLedgerJson: before.ledgerJson,
            afterLedgerJson: after.ledgerJson,
            beforeKnowledgeJson: before.knowledgeJson,
            afterKnowledgeJson: after.knowledgeJson,
            actualEffectsJson: effectsJson,
            beforeStateHash: before.hash,
            afterStateHash: after.hash,
            effectsHash: computeHash(effectsJson),
            createdAt: createdAt,
          ),
        );
  }

  Future<List<LedgerReconciliationSuccessfulRunRow>> readSession(
    String sessionId,
  ) async {
    final rows =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((r) => r.sessionId.equals(sessionId))
              ..orderBy([(r) => OrderingTerm.asc(r.ordinal)]))
            .get();
    if ((await validateChain(sessionId)) is! ReconciliationRunValid) {
      return <LedgerReconciliationSuccessfulRunRow>[];
    }
    final invalidated = await (_db.select(
      _db.ledgerReconciliationRunInvalidations,
    )..where((row) => row.sessionId.equals(sessionId))).get();
    final runIds = rows.map((row) => row.id).toSet();
    if (invalidated.any((row) => !runIds.contains(row.runId))) {
      return <LedgerReconciliationSuccessfulRunRow>[];
    }
    final invalidatedIds = invalidated.map((row) => row.runId).toSet();
    final visible = <LedgerReconciliationSuccessfulRunRow>[];
    for (final row in rows) {
      if (invalidatedIds.contains(row.id)) continue;
      // Legacy databases may contain mutations made before production began
      // recording invalidations. Treat the first such stale row and its
      // physical suffix as logically unavailable without corrupting physical
      // hash-chain integrity. A later mutation records explicit suffix
      // invalidations, allowing newly appended valid rows to be visible again.
      if (!await _storedRowMatchesCurrentEvidence(row)) break;
      visible.add(row);
    }
    return visible;
  }

  Future<List<LedgerReconciliationCursorRow>> readCursors(
    String sessionId,
  ) async {
    final rows =
        await (_db.select(_db.ledgerReconciliationCursors)
              ..where((r) => r.sessionId.equals(sessionId))
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    if (rows.isEmpty) return rows;
    var predecessor = '';
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.sequence != i + 1 ||
          row.predecessorHash != predecessor ||
          !await _cursorEndpointMatches(row) ||
          row.cursorHash !=
              computeHash(
                _canonicalJson({
                  'sessionId': row.sessionId,
                  'sequence': row.sequence,
                  'predecessorHash': row.predecessorHash,
                  'throughRunId': row.throughRunId,
                  'throughRunOrdinal': row.throughRunOrdinal,
                  'throughRunChainHash': row.throughRunChainHash,
                }),
              )) {
        return <LedgerReconciliationCursorRow>[];
      }
      predecessor = row.cursorHash;
    }
    return rows;
  }

  Future<bool> _cursorEndpointMatches(
    LedgerReconciliationCursorRow cursor,
  ) async {
    final run =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((row) => row.id.equals(cursor.throughRunId))
              ..where((row) => row.sessionId.equals(cursor.sessionId)))
            .getSingleOrNull();
    if (run == null ||
        run.ordinal != cursor.throughRunOrdinal ||
        run.chainHash != cursor.throughRunChainHash) {
      return false;
    }
    final invalidation =
        await (_db.select(_db.ledgerReconciliationRunInvalidations)
              ..where((row) => row.sessionId.equals(cursor.sessionId))
              ..where((row) => row.runId.equals(cursor.throughRunId))
              ..limit(1))
            .getSingleOrNull();
    return invalidation == null;
  }

  Future<ReconciliationRunIntegrity> validateChain(String sessionId) async {
    final rows =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((r) => r.sessionId.equals(sessionId))
              ..orderBy([(r) => OrderingTerm.asc(r.ordinal)]))
            .get();
    var predecessor = '';
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.ordinal != i + 1 ||
          row.predecessorChainHash != predecessor ||
          !await _isCanonicalRunRow(row)) {
        return const ReconciliationRunChainGap(
          'non-canonical reconciliation chain',
        );
      }
      predecessor = row.chainHash;
    }
    return const ReconciliationRunValid();
  }

  Future<ReconciliationRunIntegrity> _validate(
    LedgerReconciliationRun run,
  ) async {
    final malformedReason = switch (run) {
      LedgerReconciliationRun(id: '') => 'run ID is empty',
      LedgerReconciliationRun(sessionId: '') => 'session ID is empty',
      LedgerReconciliationRun(ordinal: <= 0) => 'ordinal is not positive',
      LedgerReconciliationRun(contractVersion: <= 0) =>
        'contract version is not positive',
      LedgerReconciliationRun(effectiveCanonStamp: '') =>
        'effective canon stamp is empty',
      LedgerReconciliationRun(effectiveCanonHash: '') =>
        'effective canon hash is empty',
      LedgerReconciliationRun(anchors: []) => 'message anchors are empty',
      _ when !_validAnchors(run.anchors) => 'message anchors are malformed',
      _ when !_validRefs(run.sessionId, run.acceptedManifestRefs) =>
        'accepted manifest references are malformed',
      _ when !_isJsonValue(run.canonicalResult) =>
        'canonical result is not JSON-safe',
      _ when run.opsApplied.any((value) => value.isEmpty) =>
        'applied operation metadata contains an empty value',
      _ => null,
    };
    if (malformedReason != null) {
      return ReconciliationRunMalformed(malformedReason);
    }
    if (!await _anchorsMatchSession(run)) {
      return const ReconciliationRunMalformed(
        'message anchors do not match the current transcript',
      );
    }
    if (!await _refsMatchAcceptedManifests(run)) {
      return const ReconciliationRunMalformed(
        'accepted manifests do not match durable provenance',
      );
    }
    return const ReconciliationRunValid();
  }

  Future<bool> _isCanonicalRunRow(
    LedgerReconciliationSuccessfulRunRow row,
  ) async {
    try {
      final anchors = _decodeAnchors(row.anchorsJson);
      final refs = _decodeRefs(row.acceptedManifestRefsJson);
      final result = jsonDecode(row.canonicalResultJson);
      final ops = jsonDecode(row.opsAppliedJson);
      if (result is! Map<Object?, Object?> ||
          ops is! List ||
          !_isJsonValue(result) ||
          !_isJsonValue(ops) ||
          !_validAnchors(anchors) ||
          !_validRefs(row.sessionId, refs) ||
          row.anchorsJson !=
              _canonicalJson(anchors.map((a) => a.toJson()).toList()) ||
          row.acceptedManifestRefsJson !=
              _canonicalJson(refs.map((r) => r.toJson()).toList()) ||
          row.canonicalResultJson != _canonicalJson(result) ||
          row.opsAppliedJson != _canonicalJson(ops) ||
          row.rangeHash != computeHash(row.anchorsJson)) {
        return false;
      }
      final run = LedgerReconciliationRun(
        id: row.id,
        sessionId: row.sessionId,
        ordinal: row.ordinal,
        anchors: anchors,
        acceptedManifestRefs: refs,
        effectiveCanonStamp: row.effectiveCanonStamp,
        effectiveCanonRevision: row.effectiveCanonRevision,
        effectiveCanonHash: row.effectiveCanonHash,
        canonicalResult: Map<String, dynamic>.from(result),
        predecessorChainHash: row.predecessorChainHash,
        contractVersion: row.contractVersion,
        opsApplied: List<String>.from(ops),
        createdAt: row.createdAt,
      );
      return row.startMessageId == run.start.messageId &&
          row.startSwipeId == run.start.swipeId &&
          row.startAgentSwipeId == run.start.agentSwipeId &&
          row.endMessageId == run.end.messageId &&
          row.endSwipeId == run.end.swipeId &&
          row.endAgentSwipeId == run.end.agentSwipeId &&
          row.contentHash == run.contentHash &&
          row.chainHash == run.chainHash;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _storedRowMatchesCurrentEvidence(
    LedgerReconciliationSuccessfulRunRow row,
  ) async {
    try {
      final anchors = _decodeAnchors(row.anchorsJson);
      final refs = _decodeRefs(row.acceptedManifestRefsJson);
      final result = jsonDecode(row.canonicalResultJson);
      final ops = jsonDecode(row.opsAppliedJson);
      if (result is! Map<Object?, Object?> || ops is! List) return false;
      final run = LedgerReconciliationRun(
        id: row.id,
        sessionId: row.sessionId,
        ordinal: row.ordinal,
        anchors: anchors,
        acceptedManifestRefs: refs,
        effectiveCanonStamp: row.effectiveCanonStamp,
        effectiveCanonRevision: row.effectiveCanonRevision,
        effectiveCanonHash: row.effectiveCanonHash,
        canonicalResult: Map<String, dynamic>.from(result),
        predecessorChainHash: row.predecessorChainHash,
        contractVersion: row.contractVersion,
        opsApplied: List<String>.from(ops),
        createdAt: row.createdAt,
      );
      return await _anchorsMatchSession(run) &&
          await _refsMatchAcceptedManifests(run);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _anchorsMatchSession(LedgerReconciliationRun run) async {
    try {
      final session = await (_db.select(
        _db.chatSessions,
      )..where((row) => row.sessionId.equals(run.sessionId))).getSingleOrNull();
      if (session == null) return false;
      final messages = jsonDecode(session.messagesJson);
      if (messages is! List) return false;
      var previousIndex = -1;
      for (final anchor in run.anchors) {
        final index = messages.indexWhere(
          (message) => message is Map && message['id'] == anchor.messageId,
        );
        if (index <= previousIndex) return false;
        previousIndex = index;
        final message = messages[index];
        if (message is! Map ||
            message['role'] != anchor.role ||
            (anchor.role != 'user' && anchor.role != 'assistant')) {
          return false;
        }
        final content = _anchoredContent(
          message,
          anchor.swipeId,
          anchor.agentSwipeId,
        );
        if (content == null || computeHash(content) != anchor.contentHash) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
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
      if (swipeId < 0 ||
          swipeId >= swipes.length ||
          swipes[swipeId] is! String) {
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

  Future<bool> _refsMatchAcceptedManifests(LedgerReconciliationRun run) async {
    for (final ref in run.acceptedManifestRefs) {
      final manifest =
          await (_db.select(_db.lorebookUseManifests)
                ..where((row) => row.sessionId.equals(ref.sessionId))
                ..where((row) => row.messageId.equals(ref.messageId))
                ..where((row) => row.swipeId.equals(ref.swipeId))
                ..where((row) => row.agentSwipeId.equals(ref.agentSwipeId)))
              .getSingleOrNull();
      if (manifest == null || manifest.manifestHash != ref.manifestHash) {
        return false;
      }
      final accepted =
          await (_db.select(_db.lorebookUseAcceptanceRecords)
                ..where((row) => row.acceptanceId.equals(ref.acceptanceId)))
              .getSingleOrNull();
      if (accepted == null ||
          accepted.acceptanceKind != 'variation' ||
          accepted.sessionId != ref.sessionId ||
          accepted.messageId != ref.messageId ||
          accepted.swipeId != ref.swipeId ||
          accepted.agentSwipeId != ref.agentSwipeId ||
          accepted.acceptedByUserMessageId != ref.acceptedByUserMessageId ||
          !await _isAcceptingUser(
            sessionId: run.sessionId,
            assistantMessageId: ref.messageId,
            userMessageId: ref.acceptedByUserMessageId,
          )) {
        return false;
      }
    }
    return true;
  }

  /// A variation is accepted only by the immediately following user message.
  /// Merely finding a user message elsewhere in the transcript is not proof.
  Future<bool> _isAcceptingUser({
    required String sessionId,
    required String assistantMessageId,
    required String userMessageId,
  }) async {
    final session = await (_db.select(
      _db.chatSessions,
    )..where((row) => row.sessionId.equals(sessionId))).getSingleOrNull();
    if (session == null) return false;
    final messages = jsonDecode(session.messagesJson);
    if (messages is! List) return false;
    final assistantIndex = messages.indexWhere(
      (message) => message is Map && message['id'] == assistantMessageId,
    );
    if (assistantIndex < 0 || assistantIndex + 1 >= messages.length) {
      return false;
    }
    final accepting = messages[assistantIndex + 1];
    return accepting is Map &&
        accepting['id'] == userMessageId &&
        accepting['role'] == 'user';
  }

  bool _same(
    LedgerReconciliationSuccessfulRunRow row,
    LedgerReconciliationRun run,
  ) =>
      row.id == run.id &&
      row.ordinal == run.ordinal &&
      row.startMessageId == run.start.messageId &&
      row.startSwipeId == run.start.swipeId &&
      row.startAgentSwipeId == run.start.agentSwipeId &&
      row.endMessageId == run.end.messageId &&
      row.endSwipeId == run.end.swipeId &&
      row.endAgentSwipeId == run.end.agentSwipeId &&
      row.anchorsJson == run.anchorsJson &&
      row.rangeHash == run.rangeHash &&
      row.acceptedManifestRefsJson == run.manifestsJson &&
      row.effectiveCanonStamp == run.effectiveCanonStamp &&
      row.effectiveCanonRevision == run.effectiveCanonRevision &&
      row.effectiveCanonHash == run.effectiveCanonHash &&
      row.canonicalResultJson == run.resultJson &&
      row.contentHash == run.contentHash &&
      row.predecessorChainHash == run.predecessorChainHash &&
      row.chainHash == run.chainHash &&
      row.contractVersion == run.contractVersion &&
      row.opsAppliedJson == run.opsJson &&
      row.createdAt == run.createdAt;
}

bool _validAnchors(List<ReconciliationAnchor> anchors) =>
    anchors.isNotEmpty &&
    anchors.every(
      (a) =>
          a.messageId.isNotEmpty &&
          a.role.isNotEmpty &&
          a.contentHash.isNotEmpty &&
          a.swipeId >= 0 &&
          a.agentSwipeId >= 0,
    );
bool _validRefs(String sessionId, List<AcceptedManifestRef> refs) => refs.every(
  (r) =>
      r.sessionId == sessionId &&
      r.acceptanceId.isNotEmpty &&
      r.messageId.isNotEmpty &&
      r.manifestHash.isNotEmpty &&
      r.acceptedByUserMessageId.isNotEmpty &&
      r.swipeId >= 0 &&
      r.agentSwipeId >= 0,
);
List<ReconciliationAnchor> _decodeAnchors(String text) {
  final value = jsonDecode(text);
  if (value is! List || value.isEmpty) throw const FormatException();
  return value.map((v) {
    if (v is! Map<Object?, Object?> ||
        v.length != 5 ||
        !_keys(v, const {
          'messageId',
          'swipeId',
          'agentSwipeId',
          'role',
          'contentHash',
        })) {
      throw const FormatException();
    }
    return ReconciliationAnchor(
      messageId: _string(v['messageId']),
      swipeId: _int(v['swipeId']),
      agentSwipeId: _int(v['agentSwipeId']),
      role: _string(v['role']),
      contentHash: _string(v['contentHash']),
    );
  }).toList();
}

List<AcceptedManifestRef> _decodeRefs(String text) {
  final value = jsonDecode(text);
  if (value is! List) throw const FormatException();
  return value.map((v) {
    if (v is! Map<Object?, Object?> ||
        v.length != 7 ||
        !_keys(v, const {
          'acceptanceId',
          'sessionId',
          'messageId',
          'swipeId',
          'agentSwipeId',
          'manifestHash',
          'acceptedByUserMessageId',
        })) {
      throw const FormatException();
    }
    return AcceptedManifestRef(
      acceptanceId: _string(v['acceptanceId']),
      sessionId: _string(v['sessionId']),
      messageId: _string(v['messageId']),
      swipeId: _int(v['swipeId']),
      agentSwipeId: _int(v['agentSwipeId']),
      manifestHash: _string(v['manifestHash']),
      acceptedByUserMessageId: _string(v['acceptedByUserMessageId']),
    );
  }).toList();
}

bool _keys(Map<Object?, Object?> value, Set<String> keys) =>
    value.keys.every((k) => k is String && keys.contains(k));
String _string(Object? v) {
  if (v is! String) throw const FormatException();
  return v;
}

int _int(Object? v) {
  if (v is! int) throw const FormatException();
  return v;
}

bool _isJsonValue(Object? value) =>
    value == null ||
    value is String ||
    value is num ||
    value is bool ||
    value is List && value.every(_isJsonValue) ||
    value is Map &&
        value.keys.every((k) => k is String) &&
        value.values.every(_isJsonValue);

Map<String, dynamic> _diffRows(
  List<dynamic> before,
  List<dynamic> after, {
  required String identityKey,
}) {
  Map<String, Map<String, dynamic>> index(List<dynamic> rows) => {
    for (final row in rows.whereType<Map<Object?, Object?>>())
      if (row[identityKey] is String)
        row[identityKey] as String: Map<String, dynamic>.from(row),
  };

  final beforeById = index(before);
  final afterById = index(after);
  final ids = {...beforeById.keys, ...afterById.keys}.toList()..sort();
  final added = <Map<String, dynamic>>[];
  final removed = <Map<String, dynamic>>[];
  final changed = <Map<String, dynamic>>[];
  for (final id in ids) {
    final oldValue = beforeById[id];
    final newValue = afterById[id];
    if (oldValue == null) {
      added.add(newValue!);
    } else if (newValue == null) {
      removed.add(oldValue);
    } else if (_canonicalJson(oldValue) != _canonicalJson(newValue)) {
      changed.add({'before': oldValue, 'after': newValue});
    }
  }
  return {'added': added, 'removed': removed, 'changed': changed};
}

String _validateCanonicalRowList(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List ||
      decoded.any((row) => row is! Map<Object?, Object?>) ||
      !_isJsonValue(decoded)) {
    throw const FormatException('Expected a JSON row list');
  }
  final canonical = _canonicalJson(decoded);
  if (canonical != text) {
    throw const FormatException('State snapshot is not canonical');
  }
  return canonical;
}

String _canonicalJson(Object? value) => jsonEncode(_canonical(value));
Object? _canonical(Object? value) {
  if (value is Map<Object?, Object?>) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  if (!_isJsonValue(value)) throw const FormatException('non-JSON value');
  return value;
}

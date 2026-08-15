import 'dart:convert';

import 'package:drift/drift.dart';

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

class LedgerReconciliationRunRepo {
  LedgerReconciliationRunRepo(this._db);
  final AppDatabase _db;

  Future<bool> anchorsMatchSession(LedgerReconciliationRun run) =>
      _anchorsMatchSession(run);

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
      id: candidate.id,
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

  /// Copies all reconciliation runs from [fromSessionId] to [toSessionId],
  /// preserving the ordinal chain. Only runs whose endpoint message falls
  /// within the branched slice ([messageIds]) are copied. The chain hashes
  /// remain valid because ordinals are preserved and the physical order is
  /// unchanged. Used by `branchSession` so the cadence gate continues from
  /// the parent's reconciliation count instead of resetting to zero.
  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final rows =
        await (_db.select(_db.ledgerReconciliationSuccessfulRuns)
              ..where((r) => r.sessionId.equals(fromSessionId))
              ..where((r) => r.endMessageId.isIn(messageIds))
              ..orderBy([(r) => OrderingTerm.asc(r.ordinal)]))
            .get();
    if (rows.isEmpty) return;
    await _db.batch((batch) {
      for (final row in rows) {
        batch.insert(
          _db.ledgerReconciliationSuccessfulRuns,
          LedgerReconciliationSuccessfulRunsCompanion.insert(
            id: row.id,
            sessionId: toSessionId,
            ordinal: row.ordinal,
            startMessageId: row.startMessageId,
            startSwipeId: row.startSwipeId,
            startAgentSwipeId: row.startAgentSwipeId,
            endMessageId: row.endMessageId,
            endSwipeId: row.endSwipeId,
            endAgentSwipeId: row.endAgentSwipeId,
            anchorsJson: row.anchorsJson,
            rangeHash: row.rangeHash,
            acceptedManifestRefsJson: row.acceptedManifestRefsJson,
            effectiveCanonStamp: row.effectiveCanonStamp,
            effectiveCanonRevision: row.effectiveCanonRevision,
            effectiveCanonHash: row.effectiveCanonHash,
            canonicalResultJson: row.canonicalResultJson,
            contentHash: row.contentHash,
            predecessorChainHash: row.predecessorChainHash,
            chainHash: row.chainHash,
            contractVersion: row.contractVersion,
            opsAppliedJson: row.opsAppliedJson,
            createdAt: row.createdAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// A head is authoritative only if the whole durable chain is canonical and
  /// the latest run remains valid in the public read projection.
  Future<LedgerReconciliationSuccessfulRunRow?> getHead(
    String sessionId,
  ) async {
    final rows = await readSession(sessionId);
    return rows.isEmpty ? null : rows.last;
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
    if (run.id.isEmpty ||
        run.sessionId.isEmpty ||
        run.ordinal <= 0 ||
        run.contractVersion <= 0 ||
        run.effectiveCanonStamp.isEmpty ||
        run.effectiveCanonHash.isEmpty ||
        run.anchors.isEmpty ||
        !_validAnchors(run.anchors) ||
        !_validRefs(run.sessionId, run.acceptedManifestRefs) ||
        !_isJsonValue(run.canonicalResult) ||
        run.opsApplied.any((v) => v.isEmpty)) {
      return const ReconciliationRunMalformed(
        'missing or non-canonical reconciliation evidence',
      );
    }
    if (!await _anchorsMatchSession(run) ||
        !await _refsMatchAcceptedManifests(run)) {
      return const ReconciliationRunMalformed(
        'reconciliation evidence does not match durable canonical sources',
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

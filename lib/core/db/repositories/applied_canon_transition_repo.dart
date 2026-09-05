import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../services/card_rewriter/effective_canon_fence_resolver.dart';

final class AppliedCanonTransitionRecord {
  const AppliedCanonTransitionRecord({
    required this.id,
    required this.characterId,
    required this.chatSessionId,
    required this.rewriteOperationId,
    required this.revision,
    required this.revisionHash,
    required this.semanticScopeKey,
    required this.canonicalClaim,
    required this.promotionDestination,
    required this.affectedTrackerKeys,
    required this.transitionJson,
  });
  final String id;
  final String characterId;
  final String? chatSessionId;
  final String rewriteOperationId;
  final int revision;
  final String revisionHash;
  final String semanticScopeKey;
  final String canonicalClaim;
  final String promotionDestination;
  final List<String> affectedTrackerKeys;
  final String transitionJson;

  CanonFenceTransition toFenceTransition() => CanonFenceTransition(
    id: id,
    scopeKey: semanticScopeKey,
    revisionNumber: revision,
    revisionHash: revisionHash,
    canonicalClaim: canonicalClaim,
    affectedTrackerKeys: affectedTrackerKeys,
    provenance: rewriteOperationId,
  );
}

class AppliedCanonTransitionRepo {
  const AppliedCanonTransitionRepo(this._db);
  final AppDatabase _db;

  Future<List<AppliedCanonTransitionRecord>> getForContext({
    required String characterId,
    required String sessionId,
  }) =>
      (_db.select(_db.appliedCanonTransitionRows)..where(
            (row) =>
                row.characterId.equals(characterId) &
                (row.chatSessionId.equals(sessionId) |
                    row.chatSessionId.isNull()),
          ))
          .get()
          .then((rows) => rows.map(_fromRow).toList(growable: false));

  Future<void> insert(AppliedCanonTransitionRecord value) => _db
      .into(_db.appliedCanonTransitionRows)
      .insertOnConflictUpdate(
        AppliedCanonTransitionRowsCompanion.insert(
          id: value.id,
          characterId: value.characterId,
          chatSessionId: Value(value.chatSessionId),
          rewriteOperationId: Value(value.rewriteOperationId),
          revision: Value(value.revision),
          revisionHash: Value(value.revisionHash),
          semanticScopeKey: Value(value.semanticScopeKey),
          canonicalClaim: Value(value.canonicalClaim),
          promotionDestination: Value(value.promotionDestination),
          affectedTrackerKeysJson: Value(jsonEncode(value.affectedTrackerKeys)),
          transitionJson: value.transitionJson,
        ),
      );

  AppliedCanonTransitionRecord _fromRow(AppliedCanonTransitionRow row) {
    List<String> keys;
    try {
      keys = (jsonDecode(row.affectedTrackerKeysJson) as List)
          .whereType<String>()
          .toList(growable: false);
    } catch (_) {
      keys = const [];
    }
    return AppliedCanonTransitionRecord(
      id: row.id,
      characterId: row.characterId,
      chatSessionId: row.chatSessionId,
      rewriteOperationId: row.rewriteOperationId,
      revision: row.revision,
      revisionHash: row.revisionHash,
      semanticScopeKey: row.semanticScopeKey,
      canonicalClaim: row.canonicalClaim,
      promotionDestination: row.promotionDestination,
      affectedTrackerKeys: keys,
      transitionJson: row.transitionJson,
    );
  }
}

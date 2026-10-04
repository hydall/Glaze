import '../app_db.dart';
import '../../services/card_rewriter/effective_canon_fence_resolver.dart';

class CanonTransitionFactRefRepo {
  const CanonTransitionFactRefRepo(this._db);
  final AppDatabase _db;

  Future<List<CanonTransitionFactRef>> getForTransitionIds(
    Iterable<String> transitionIds,
  ) {
    final ids = transitionIds.toSet();
    if (ids.isEmpty) return Future.value(const []);
    return (_db.select(
      _db.canonTransitionFactRefs,
    )..where((row) => row.appliedCanonTransitionId.isIn(ids))).get().then(
      (rows) => rows
          .map(
            (row) => CanonTransitionFactRef(
              transitionId: row.appliedCanonTransitionId,
              factId: row.characterKnowledgeFactId,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> insert(CanonTransitionFactRef value) => _db
      .into(_db.canonTransitionFactRefs)
      .insertOnConflictUpdate(
        CanonTransitionFactRefsCompanion.insert(
          appliedCanonTransitionId: value.transitionId,
          characterKnowledgeFactId: value.factId,
        ),
      );
}

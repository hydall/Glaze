import 'package:drift/drift.dart';

import '../../application/sync_repo_interfaces.dart';
import '../../models/studio_config.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

class StudioConfigRepo implements SyncStudioConfigStore {
  final AppDatabase db;

  const StudioConfigRepo(this.db);

  Future<StudioConfig?> getBySessionId(String sessionId) async {
    final row = await (db.select(
      db.studioConfigRows,
    )..where((table) => table.sessionId.equals(sessionId))).getSingleOrNull();
    return row == null ? null : _rowToModel(row);
  }

  Future<bool> hasAnyEnabledConfig() async {
    final row =
        await (db.select(db.studioConfigRows)
              ..where((table) => table.enabled.equals(true))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  @override
  Future<List<StudioConfig>> getAll() async {
    final rows = await db.select(db.studioConfigRows).get();
    return rows.map(_rowToModel).toList(growable: false);
  }

  /// The profile new sessions inherit — the newest one, created on demand.
  ///
  /// Used by the global Studio slot settings, which have no session to scope
  /// to. Deliberately not called on read: creating a row just because a
  /// settings screen was opened would bind every unbound session to an empty
  /// profile.
  Future<StudioConfig> ensureDefaultProfile() async {
    final profiles = await getAll();
    if (profiles.isNotEmpty) return profiles.first;
    const id = 'studio_profile_default';
    final now = currentTimestampSeconds();
    const profile = StudioConfig(
      sessionId: id,
      enabled: true,
    );
    final stamped = profile.copyWith(createdAt: now, updatedAt: now);
    await upsert(stamped);
    return stamped;
  }

  @override
  Future<StudioConfig?> getById(String id) => getBySessionId(id);

  @override
  Future<void> put(StudioConfig config) {
    return db
        .into(db.studioConfigRows)
        .insertOnConflictUpdate(
          StudioConfigRowsCompanion.insert(
            sessionId: config.sessionId,
            enabled: Value(config.enabled),
            createdAt: Value(config.createdAt),
            updatedAt: Value(config.updatedAt),
          ),
        );
  }

  Future<void> upsert(StudioConfig config) {
    return db
        .into(db.studioConfigRows)
        .insertOnConflictUpdate(
          StudioConfigRowsCompanion.insert(
            sessionId: config.sessionId,
            enabled: Value(config.enabled),
            createdAt: Value(config.createdAt),
            updatedAt: Value(currentTimestampSeconds()),
          ),
        );
  }

  @override
  Future<void> delete(String id) => deleteBySessionId(id);

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.studioConfigRows,
    )..where((table) => table.sessionId.equals(sessionId))).go();
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    await upsert(
      source.copyWith(
        sessionId: toSessionId,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  StudioConfig _rowToModel(StudioConfigRow row) => StudioConfig(
    sessionId: row.sessionId,
    enabled: row.enabled,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

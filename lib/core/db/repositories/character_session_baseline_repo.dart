import 'package:drift/drift.dart';

import '../../models/character_session_baseline.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Persistence for immutable session-start card evidence.
class CharacterSessionBaselineRepo {
  const CharacterSessionBaselineRepo(this.db);

  final AppDatabase db;

  Future<CharacterSessionBaseline?> getBySessionId(String sessionId) async {
    final row = await (db.select(
      db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// First write wins: runtime source-card edits must not overwrite session
  /// evidence. Policy/source-hash updates are explicit through [updatePolicy]
  /// and [markSourceHashSeen].
  Future<CharacterSessionBaseline> ensureBaseline(
    CharacterSessionBaseline baseline,
  ) async {
    final existing = await getBySessionId(baseline.chatSessionId);
    if (existing != null) return existing;
    final now = currentTimestampSeconds();
    await db
        .into(db.characterSessionBaselineRows)
        .insert(
          CharacterSessionBaselineRow(
            chatSessionId: baseline.chatSessionId,
            characterId: baseline.characterId,
            baselineCardJson: baseline.baselineCardJson,
            baselineHash: baseline.baselineHash,
            sourceHashLastSeen: baseline.sourceHashLastSeen,
            cardUpdatePolicy: baseline.cardUpdatePolicy.wireName,
            createdAt: baseline.createdAt == 0 ? now : baseline.createdAt,
            updatedAt: baseline.updatedAt == 0 ? now : baseline.updatedAt,
          ),
        );
    return (await getBySessionId(baseline.chatSessionId))!;
  }

  Future<void> updatePolicy({
    required String sessionId,
    required CharacterCardUpdatePolicy policy,
  }) {
    return (db.update(
      db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).write(
      CharacterSessionBaselineRowsCompanion(
        cardUpdatePolicy: Value(policy.wireName),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> markSourceHashSeen({
    required String sessionId,
    required String sourceHash,
  }) {
    return (db.update(
      db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).write(
      CharacterSessionBaselineRowsCompanion(
        sourceHashLastSeen: Value(sourceHash),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.characterSessionBaselineRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await getBySessionId(fromSessionId);
    if (source == null) return;
    await ensureBaseline(
      source.copyWith(
        chatSessionId: toSessionId,
        createdAt: currentTimestampSeconds(),
        updatedAt: currentTimestampSeconds(),
      ),
    );
  }

  CharacterSessionBaseline _fromRow(CharacterSessionBaselineRow row) =>
      CharacterSessionBaseline(
        chatSessionId: row.chatSessionId,
        characterId: row.characterId,
        baselineCardJson: row.baselineCardJson,
        baselineHash: row.baselineHash,
        sourceHashLastSeen: row.sourceHashLastSeen,
        cardUpdatePolicy: CharacterCardUpdatePolicy.fromWireName(
          row.cardUpdatePolicy,
        ),
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}

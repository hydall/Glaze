import 'package:drift/drift.dart';

import '../../models/lorebook.dart';
import '../../services/card_rewriter/card_rewriter_contracts.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

final class SessionLorebookMutation {
  const SessionLorebookMutation({
    required this.baseContentHash,
    required this.previousContentHash,
    required this.content,
    required this.contentHash,
  });

  final String baseContentHash;
  final String previousContentHash;
  final String content;
  final String contentHash;
}

typedef SessionLorebookTarget = ({String lorebookId, String entryId});

final class EffectiveSessionLorebooks {
  const EffectiveSessionLorebooks({
    required this.lorebooks,
    required this.overlayTargets,
  });

  final List<Lorebook> lorebooks;
  final Set<SessionLorebookTarget> overlayTargets;
}

/// Owns session-local lorebook content. It never mutates global lorebooks.
class SessionLorebookEvolutionRepo {
  const SessionLorebookEvolutionRepo(this.db);

  final AppDatabase db;

  Stream<List<SessionLorebookEvolutionRow>> watchBySessionId(String sessionId) {
    return (db.select(db.sessionLorebookEvolutionRows)
          ..where((row) => row.chatSessionId.equals(sessionId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.lorebookId),
            (row) => OrderingTerm.asc(row.entryId),
          ]))
        .watch();
  }

  Future<List<Lorebook>> applyOverlays({
    required String sessionId,
    required List<Lorebook> lorebooks,
  }) async => (await resolveEffectiveLorebooks(
    sessionId: sessionId,
    lorebooks: lorebooks,
  )).lorebooks;

  Future<EffectiveSessionLorebooks> resolveEffectiveLorebooks({
    required String sessionId,
    required List<Lorebook> lorebooks,
  }) async {
    if (sessionId.isEmpty || lorebooks.isEmpty) {
      return EffectiveSessionLorebooks(
        lorebooks: lorebooks,
        overlayTargets: const {},
      );
    }
    final rows = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    if (rows.isEmpty) {
      return EffectiveSessionLorebooks(
        lorebooks: lorebooks,
        overlayTargets: const {},
      );
    }
    final contentByKey = {
      for (final row in rows)
        '${row.lorebookId}\u0000${row.entryId}': row.content,
    };
    final knownTargets = <SessionLorebookTarget>{};
    final effective = [
      for (final book in lorebooks)
        book.copyWith(
          entries: [
            for (final entry in book.entries)
              if (contentByKey.containsKey('${book.id}\u0000${entry.id}'))
                () {
                  knownTargets.add((lorebookId: book.id, entryId: entry.id));
                  return entry.copyWith(
                    content: contentByKey['${book.id}\u0000${entry.id}']!,
                  );
                }()
              else
                entry,
          ],
        ),
    ];
    return EffectiveSessionLorebooks(
      lorebooks: effective,
      overlayTargets: knownTargets,
    );
  }

  Future<Map<String, SessionLorebookEvolutionRow>> getByTargets({
    required String sessionId,
    required Iterable<(String lorebookId, String entryId)> targets,
  }) async {
    final keys = targets
        .map((target) => '${target.$1}\u0000${target.$2}')
        .toSet();
    if (sessionId.isEmpty || keys.isEmpty) return const {};
    final rows = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).get();
    return {
      for (final row in rows)
        if (keys.contains('${row.lorebookId}\u0000${row.entryId}'))
          '${row.lorebookId}\u0000${row.entryId}': row,
    };
  }

  Future<SessionLorebookEvolutionRow?> getByTarget({
    required String sessionId,
    required String lorebookId,
    required String entryId,
  }) =>
      (db.select(db.sessionLorebookEvolutionRows)..where(
            (row) =>
                row.chatSessionId.equals(sessionId) &
                row.lorebookId.equals(lorebookId) &
                row.entryId.equals(entryId),
          ))
          .getSingleOrNull();

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await (db.select(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(fromSessionId))).get();
    final now = currentTimestampSeconds();
    for (final row in source) {
      await db
          .into(db.sessionLorebookEvolutionRows)
          .insert(
            SessionLorebookEvolutionRowsCompanion.insert(
              chatSessionId: toSessionId,
              lorebookId: row.lorebookId,
              entryId: row.entryId,
              baseContent: row.baseContent,
              baseContentHash: row.baseContentHash,
              content: row.content,
              contentHash: row.contentHash,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  }

  /// Applies an exact-once patch batch to current session content. The caller
  /// owns the surrounding transaction and supplies immutable source evidence.
  Future<bool> applyPatchesInTransaction({
    required String sessionId,
    required String lorebookId,
    required String entryId,
    required String baseContent,
    required String expectedContentHash,
    required List<LorebookAnchoredPatch> patches,
  }) async =>
      await applyPatchesWithResultInTransaction(
        sessionId: sessionId,
        lorebookId: lorebookId,
        entryId: entryId,
        baseContent: baseContent,
        expectedContentHash: expectedContentHash,
        patches: patches,
      ) !=
      null;

  Future<SessionLorebookMutation?> applyPatchesWithResultInTransaction({
    required String sessionId,
    required String lorebookId,
    required String entryId,
    required String baseContent,
    required String expectedContentHash,
    required List<LorebookAnchoredPatch> patches,
  }) async {
    if (sessionId.isEmpty ||
        lorebookId.isEmpty ||
        entryId.isEmpty ||
        patches.isEmpty) {
      return null;
    }
    final existing =
        await (db.select(db.sessionLorebookEvolutionRows)..where(
              (row) =>
                  row.chatSessionId.equals(sessionId) &
                  row.lorebookId.equals(lorebookId) &
                  row.entryId.equals(entryId),
            ))
            .getSingleOrNull();
    var next = existing?.content ?? baseContent;
    if (CardCanonicalizer.scalarSha256(next) != expectedContentHash) {
      return null;
    }
    final seenAnchors = <String>{};
    for (final patch in patches) {
      if (!seenAnchors.add(patch.anchorSha256) ||
          CardCanonicalizer.scalarSha256(patch.anchor) != patch.anchorSha256 ||
          !AnchoredScalarPatchValidator.preservesMacroTokens(
            patch.anchor,
            patch.value,
          ) ||
          _occurrences(next, patch.anchor) != 1) {
        return null;
      }
      next = next.replaceFirst(patch.anchor, patch.value);
    }
    final nextHash = CardCanonicalizer.scalarSha256(next);
    final now = currentTimestampSeconds();
    if (existing == null) {
      try {
        await db
            .into(db.sessionLorebookEvolutionRows)
            .insert(
              SessionLorebookEvolutionRowsCompanion.insert(
                chatSessionId: sessionId,
                lorebookId: lorebookId,
                entryId: entryId,
                baseContent: baseContent,
                baseContentHash: CardCanonicalizer.scalarSha256(baseContent),
                content: next,
                contentHash: nextHash,
                createdAt: now,
                updatedAt: now,
              ),
            );
        return SessionLorebookMutation(
          baseContentHash: CardCanonicalizer.scalarSha256(baseContent),
          previousContentHash: expectedContentHash,
          content: next,
          contentHash: nextHash,
        );
      } catch (_) {
        return null;
      }
    }
    final changed =
        await (db.update(db.sessionLorebookEvolutionRows)..where(
              (row) =>
                  row.chatSessionId.equals(sessionId) &
                  row.lorebookId.equals(lorebookId) &
                  row.entryId.equals(entryId) &
                  row.contentHash.equals(expectedContentHash),
            ))
            .write(
              SessionLorebookEvolutionRowsCompanion(
                content: Value(next),
                contentHash: Value(nextHash),
                updatedAt: Value(now),
              ),
            );
    if (changed != 1) return null;
    return SessionLorebookMutation(
      baseContentHash: existing.baseContentHash,
      previousContentHash: expectedContentHash,
      content: next,
      contentHash: nextHash,
    );
  }

  static int _occurrences(String value, String anchor) {
    if (anchor.isEmpty) return value.isEmpty ? 1 : 0;
    var count = 0;
    var from = 0;
    while (true) {
      final index = value.indexOf(anchor, from);
      if (index == -1) return count;
      count++;
      from = index + anchor.length;
    }
  }
}

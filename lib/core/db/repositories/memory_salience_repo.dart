import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/memory_graph.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

class MemorySalienceRepo {
  final AppDatabase db;

  const MemorySalienceRepo(this.db);

  Future<MemorySalience?> getByEntryId(String entryId) {
    return (db.select(db.memorySalienceRows)
          ..where((row) => row.memoryEntryId.equals(entryId)))
        .getSingleOrNull()
        .then((row) => row == null ? null : _rowToModel(row));
  }

  Future<List<MemorySalience>> getBySessionId(String sessionId) {
    return (db.select(db.memorySalienceRows)
          ..where((row) => row.chatSessionId.equals(sessionId)))
        .get()
        .then((rows) => rows.map(_rowToModel).toList());
  }

  Future<void> upsert(MemorySalience salience) {
    return db
        .into(db.memorySalienceRows)
        .insertOnConflictUpdate(
          MemorySalienceRowsCompanion.insert(
            id: salience.id,
            chatSessionId: salience.chatSessionId,
            memoryEntryId: salience.memoryEntryId,
            score: Value(salience.score),
            emotionalTagsJson: Value(jsonEncode(salience.emotionalTags)),
            narrativeFlagsJson: Value(jsonEncode(salience.narrativeFlags)),
            hasDialogue: Value(salience.hasDialogue),
            hasAction: Value(salience.hasAction),
            wordCount: Value(salience.wordCount),
            scoreSource: Value(salience.scoreSource),
            scoredAt: Value(currentTimestampSeconds()),
            createdAt: Value(salience.createdAt),
          ),
        );
  }

  Future<void> deleteByEntryId(String entryId) {
    return (db.delete(
      db.memorySalienceRows,
    )..where((row) => row.memoryEntryId.equals(entryId))).go();
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.memorySalienceRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
  }

  MemorySalience _rowToModel(MemorySalienceRow row) {
    List<String> emotionalTags;
    try {
      emotionalTags = (jsonDecode(row.emotionalTagsJson) as List<dynamic>)
          .map((e) => e as String)
          .toList();
    } catch (_) {
      emotionalTags = [];
    }

    List<String> narrativeFlags;
    try {
      narrativeFlags = (jsonDecode(row.narrativeFlagsJson) as List<dynamic>)
          .map((e) => e as String)
          .toList();
    } catch (_) {
      narrativeFlags = [];
    }

    return MemorySalience(
      id: row.id,
      chatSessionId: row.chatSessionId,
      memoryEntryId: row.memoryEntryId,
      score: row.score,
      emotionalTags: emotionalTags,
      narrativeFlags: narrativeFlags,
      hasDialogue: row.hasDialogue,
      hasAction: row.hasAction,
      wordCount: row.wordCount,
      scoreSource: row.scoreSource,
      scoredAt: row.scoredAt,
      createdAt: row.createdAt,
    );
  }
}

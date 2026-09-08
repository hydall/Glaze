import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/memory_graph.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

class MemoryEntityRepo {
  final AppDatabase db;

  const MemoryEntityRepo(this.db);

  Future<List<MemoryEntity>> getBySessionId(String sessionId) {
    return (db.select(db.memoryEntityRows)
          ..where((row) => row.chatSessionId.equals(sessionId))
          ..orderBy([(row) => OrderingTerm(expression: row.name)]))
        .get()
        .then((rows) => rows.map(_rowToModel).toList());
  }

  Future<List<MemoryEntity>> getByEntryId(String entryId) {
    return (db.select(db.memoryEntityRows)
          ..where((row) => row.memoryEntryId.equals(entryId)))
        .get()
        .then((rows) => rows.map(_rowToModel).toList());
  }

  Future<void> upsert(MemoryEntity entity) {
    return db.into(db.memoryEntityRows).insertOnConflictUpdate(
      MemoryEntityRowsCompanion.insert(
        id: entity.id,
        chatSessionId: entity.chatSessionId,
        memoryEntryId: entity.memoryEntryId,
        name: entity.name,
        entityType: Value(entity.entityType),
        aliasesJson: Value(jsonEncode(entity.aliases)),
        description: Value(entity.description),
        salienceAvg: Value(entity.salienceAvg),
        saliencePeak: Value(entity.saliencePeak),
        status: Value(entity.status),
        factsJson: Value(jsonEncode(entity.facts)),
        emotionalValenceJson: Value(jsonEncode(entity.emotionalValence)),
        mentionCount: Value(entity.mentionCount),
        lastSeenMessageIndex: Value(entity.lastSeenMessageIndex),
        sourceHash: Value(entity.sourceHash),
        createdAt: Value(entity.createdAt),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> deleteByEntryId(String entryId) {
    return (db.delete(
      db.memoryEntityRows,
    )..where((row) => row.memoryEntryId.equals(entryId))).go();
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.memoryEntityRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
  }

  Stream<List<MemoryEntity>> watchBySessionId(String sessionId) {
    return (db.select(db.memoryEntityRows)
          ..where((row) => row.chatSessionId.equals(sessionId))
          ..orderBy([(row) => OrderingTerm(expression: row.name)]))
        .watch()
        .map((rows) => rows.map(_rowToModel).toList());
  }

  Future<void> replaceForEntry(
    String entryId,
    String sessionId,
    List<MemoryEntity> entities,
  ) {
    return db.transaction(() async {
      await deleteByEntryId(entryId);
      for (final entity in entities) {
        await upsert(entity);
      }
    });
  }

  MemoryEntity _rowToModel(MemoryEntityRow row) {
    List<String> aliases;
    try {
      aliases = (jsonDecode(row.aliasesJson) as List<dynamic>)
          .map((e) => e as String)
          .toList();
    } catch (_) {
      aliases = [];
    }

    List<String> facts;
    try {
      facts = (jsonDecode(row.factsJson) as List<dynamic>)
          .map((e) => e as String)
          .toList();
    } catch (_) {
      facts = [];
    }

    Map<String, double> emotionalValence;
    try {
      emotionalValence = (jsonDecode(row.emotionalValenceJson)
              as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      emotionalValence = {};
    }

    return MemoryEntity(
      id: row.id,
      chatSessionId: row.chatSessionId,
      memoryEntryId: row.memoryEntryId,
      name: row.name,
      entityType: row.entityType,
      aliases: aliases,
      description: row.description,
      salienceAvg: row.salienceAvg,
      saliencePeak: row.saliencePeak,
      status: row.status,
      facts: facts,
      emotionalValence: emotionalValence,
      mentionCount: row.mentionCount,
      lastSeenMessageIndex: row.lastSeenMessageIndex,
      sourceHash: row.sourceHash,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}

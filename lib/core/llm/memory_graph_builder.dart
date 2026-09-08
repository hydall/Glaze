import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../db/repositories/memory_entity_repo.dart';
import '../db/repositories/memory_salience_repo.dart';
import '../models/memory_book.dart';
import '../utils/time_helpers.dart';
import 'memory_entity_extractor.dart';
import 'memory_salience_scorer.dart';

/// Builds and maintains the derived entity graph over Memory Book entries.
///
/// The graph is **derived state** — it can always be rebuilt from Memory Book.
/// Each entity row stores a [sourceHash] (sha256 of content+keys+title) so
/// that unchanged entries skip re-extraction on subsequent passes.
class MemoryGraphBuilder {
  final MemoryEntityRepo _entityRepo;
  final MemorySalienceRepo _salienceRepo;

  const MemoryGraphBuilder(this._entityRepo, this._salienceRepo);

  /// Update entities + salience for a single [entry] if its content has changed.
  /// Skips work if [sourceHash] matches the stored hash.
  Future<void> updateForEntry(
    MemoryEntry entry, {
    required String sessionId,
    List<String> knownCharacterNames = const [],
  }) async {
    final sourceHash = _computeSourceHash(entry);

    // Check if entities already exist with the same sourceHash
    final existingEntities = await _entityRepo.getByEntryId(entry.id);
    if (existingEntities.isNotEmpty &&
        existingEntities.first.sourceHash == sourceHash) {
      return; // Up to date
    }

    // Extract new entities
    final entities = MemoryEntityExtractor.extract(
      entry,
      sessionId: sessionId,
      knownCharacterNames: knownCharacterNames,
    );

    // Stamp sourceHash on all entities
    final stamped = entities
        .map(
          (e) => e.copyWith(
            sourceHash: sourceHash,
            updatedAt: currentTimestampSeconds(),
          ),
        )
        .toList();

    // Transactional replace
    await _entityRepo.replaceForEntry(entry.id, sessionId, stamped);

    // Rescore salience
    final salience = MemorySalienceScorer.score(entry, sessionId: sessionId);
    await _salienceRepo.upsert(salience);
  }

  /// Rebuild the entire entity graph + salience for a session.
  /// Deletes all existing entities for the session and rebuilds from
  /// the given [entries].
  Future<void> rebuildSession(
    String sessionId,
    List<MemoryEntry> entries, {
    List<String> knownCharacterNames = const [],
  }) async {
    await _entityRepo.deleteBySessionId(sessionId);
    await _salienceRepo.deleteBySessionId(sessionId);

    for (final entry in entries) {
      if (entry.status != 'active' || entry.content.trim().isEmpty) continue;
      await updateForEntry(
        entry,
        sessionId: sessionId,
        knownCharacterNames: knownCharacterNames,
      );
    }
  }

  /// Match entity names + aliases in [queryText] and return a map of
  /// entryId → count of query-mentioned entities found in that entry.
  Future<Map<String, int>> computeEntityOverlap({
    required String sessionId,
    required String queryText,
  }) async {
    final entities = await _entityRepo.getBySessionId(sessionId);
    if (entities.isEmpty) return const {};

    final lowerQuery = queryText.toLowerCase();
    final overlapByEntry = <String, int>{};

    for (final entity in entities) {
      final names = <String>[entity.name, ...entity.aliases];
      var matched = false;
      for (final name in names) {
        if (name.isEmpty) continue;
        if (lowerQuery.contains(name.toLowerCase())) {
          matched = true;
          break;
        }
      }
      if (matched) {
        overlapByEntry[entity.memoryEntryId] =
            (overlapByEntry[entity.memoryEntryId] ?? 0) + 1;
      }
    }

    return overlapByEntry;
  }

  String _computeSourceHash(MemoryEntry entry) {
    final input = '${entry.content}|${entry.keys.join(",")}|${entry.title}';
    return sha256.convert(utf8.encode(input)).toString();
  }
}

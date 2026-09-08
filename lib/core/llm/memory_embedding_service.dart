import 'dart:convert';

import '../models/memory_book.dart';
import '../db/repositories/embedding_repo.dart';
import '../utils/cast_helpers.dart';
import 'embedding_service.dart';
import 'lorebook_embedding_service.dart';
import 'retrieval_hints.dart';

class MemoryEmbeddingService {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;

  MemoryEmbeddingService(this._repo, this._embeddingService);

  Future<void> indexMemoryEntry(
    MemoryEntry entry, {
    required String charId,
    required String sessionId,
    required EmbeddingConfig config,
    String embeddingTarget = 'content',
  }) async {
    if (config.endpoint.isEmpty) return;
    // excludeFromVectorization: user opt-out for spoiler entries or
    // entries that should only activate via keyword, never via semantic
    // similarity. Drop any existing embedding row too so the entry is
    // fully invisible to vector search. Mirrors Marinara's
    // `excludeFromVectorization` flag. Rationale: spoiler entries or entries
    // that should only activate via keyword are excluded from the embedding
    // pipeline entirely — the existing embedding row is also deleted so the
    // entry is fully invisible to vector search (Marinara analog).
    if (entry.excludeFromVectorization) {
      await _repo.deleteByEntryId(entry.id);
      return;
    }

    final text = _getEmbeddingText(entry, embeddingTarget);
    if (text.trim().isEmpty) return;

    final hints = extractMemoryRetrievalHints(entry);
    final fingerprint = _buildFingerprint(entry, text);
    final textHash = computeHash(fingerprint);

    final existing = await _repo.getByEntryId(entry.id);
    if (existing != null &&
        existing.textHash == textHash &&
        _repo.hasUsableVectors(existing) &&
        existing.errorJson == null) {
      return;
    }

    try {
      final chunks = await _embeddingService.getEmbeddingsWithChunks([
        text,
      ], config);
      final vectors = chunks.map((c) => c.vector).toList();
      final chunkTexts = chunks.map((c) => c.text).toList(growable: false);

      await _repo.putEmbeddingVector(
        entryId: entry.id,
        sourceType: 'memory_entry',
        sourceId: 'memorybook_${charId}_$sessionId',
        vectors: vectors,
        textHash: textHash,
        retrievalMetadata: embeddingMetadataForConfig(
          config,
          vectors,
          hints: hints,
          chunks: [
            for (int i = 0; i < chunkTexts.length; i++)
              {'index': i, 'text': chunkTexts[i]},
          ],
        ),
      );
    } on RateLimitException {
      await _repo.putEmbeddingError(
        entryId: entry.id,
        sourceType: 'memory_entry',
        sourceId: 'memorybook_${charId}_$sessionId',
        textHash: textHash,
        error: {
          'type': 'rate_limit',
          'message': 'Rate limited, deferred',
          'retryable': true,
        },
        retrievalMetadata: embeddingMetadataForConfig(
          config,
          const [],
          hints: hints,
        ),
      );
      rethrow;
    } catch (e) {
      await _repo.putEmbeddingError(
        entryId: entry.id,
        sourceType: 'memory_entry',
        sourceId: 'memorybook_${charId}_$sessionId',
        textHash: textHash,
        error: {
          'type': 'api_error',
          'message': e.toString(),
          'retryable': true,
        },
        retrievalMetadata: embeddingMetadataForConfig(
          config,
          const [],
          hints: hints,
        ),
      );
    }
  }

  Future<IndexResult> reindexAll(
    MemoryBook book, {
    required String charId,
    required String sessionId,
    required EmbeddingConfig config,
    String embeddingTarget = 'content',
    void Function(int current, int total)? onProgress,
  }) async {
    int indexed = 0;
    int skipped = 0;
    int failed = 0;
    bool rateLimited = false;
    int retryAfter = 0;

    final entries = book.entries.where((e) => e.status == 'active').toList();
    // Drop any existing embeddings for excluded entries up front so the
    // reindex leaves the embedding table clean for them.
    final excluded = entries.where((e) => e.excludeFromVectorization).toList();
    for (final e in excluded) {
      await _repo.deleteByEntryId(e.id);
    }
    final indexable = entries
        .where((e) => !e.excludeFromVectorization)
        .toList();

    for (int i = 0; i < indexable.length; i++) {
      onProgress?.call(i, indexable.length);
      try {
        final existing = await _repo.getByEntryId(indexable[i].id);
        final text = _getEmbeddingText(indexable[i], embeddingTarget);
        final fingerprint = _buildFingerprint(indexable[i], text);
        final textHash = computeHash(fingerprint);

        if (existing != null &&
            existing.textHash == textHash &&
            _repo.hasUsableVectors(existing) &&
            existing.errorJson == null) {
          skipped++;
          continue;
        }

        await indexMemoryEntry(
          indexable[i],
          charId: charId,
          sessionId: sessionId,
          config: config,
          embeddingTarget: embeddingTarget,
        );
        indexed++;
      } on RateLimitException catch (e) {
        rateLimited = true;
        retryAfter = e.retryAfter;
        failed++;
        break;
      } catch (_) {
        failed++;
      }
    }

    return IndexResult(
      indexed: indexed,
      skipped: skipped,
      failed: failed,
      rateLimited: rateLimited,
      retryAfter: retryAfter,
    );
  }

  Future<void> deleteMemoryEntryIndex(String entryId) async {
    await _repo.deleteByEntryId(entryId);
  }

  Future<void> deleteAllMemoryIndexes() async {
    await _repo.deleteBySourceType('memory_entry');
  }

  String _getEmbeddingText(MemoryEntry entry, String target) {
    if (target == 'keys') {
      return entry.keys.join(', ');
    }
    return entry.content;
  }

  String _buildFingerprint(MemoryEntry entry, String text) {
    return jsonEncode({
      'text': text,
      'retrievalHints': extractMemoryRetrievalHints(entry),
    });
  }

  static List<String> extractMemoryRetrievalHints(MemoryEntry entry) {
    return extractRetrievalHintsFrom(
      label: entry.title,
      keys: entry.keys,
      content: entry.content,
    );
  }
}

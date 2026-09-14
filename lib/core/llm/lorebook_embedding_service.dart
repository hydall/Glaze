import 'dart:convert';

import '../models/lorebook.dart';
import '../db/repositories/embedding_repo.dart';
import '../utils/cast_helpers.dart';
import 'embedding_service.dart';
import 'lorebook_embedding_text.dart';
import 'retrieval_hints.dart';

class LorebookEmbeddingService {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;
  LorebookEmbeddingService(this._repo, this._embeddingService);

  Future<void> clearLorebookEmbeddings(String lorebookId) {
    return _repo.deleteBySourceId(lorebookId);
  }

  Future<IndexResult> indexLorebookEntries(
    String lorebookId,
    List<LorebookEntry> entries,
    EmbeddingConfig config, {
    void Function(int current, int total, String entryName)? onProgress,
    bool retryFailedOnly = false,
    bool forceReindex = false,
    String embeddingTarget = LorebookEmbeddingTarget.content,
    bool vectorizeAll = false,
  }) async {
    int indexed = 0;
    int skipped = 0;
    int failed = 0;
    bool rateLimited = false;
    int retryAfter = 0;

    // Both embedding pools are indexed here — the main one (entries that opt
    // into vector search, or every entry when the book sets vectorizeAll) and
    // the keyless fallback pool, whose entries cannot activate by keyword at
    // all and would otherwise be dead weight. lorebookVectorPoolFor decides;
    // the search asks the same function, so the two cannot disagree about
    // what is supposed to be in the index. Entries opted out of embedding
    // (excludeFromVectorization — spoilers, keyword-only entries) are dropped
    // from both pools and any embedding they still carry is purged.
    final excluded = entries
        .where((e) => e.excludeFromVectorization && e.enabled && !e.constant)
        .toList();
    for (final e in excluded) {
      final namespacedId = '${lorebookId}_${e.id}';
      await _repo.deleteByEntryId(namespacedId);
    }
    final indexable = entries
        .where((e) => isLorebookEntryIndexable(e, vectorizeAll: vectorizeAll))
        .toList();

    for (int i = 0; i < indexable.length; i++) {
      final entry = indexable[i];
      onProgress?.call(
        i,
        indexable.length,
        entry.comment.isNotEmpty ? entry.comment : entry.id,
      );

      final text = lorebookEmbeddingText(entry, embeddingTarget);
      final hints = extractRetrievalHints(entry);
      final fingerprint = buildEmbeddingFingerprint(entry, text);
      final textHash = computeHash(fingerprint);

      final namespacedId = '${lorebookId}_${entry.id}';
      final existing = forceReindex
          ? null
          : await _repo.getByEntryId(namespacedId);

      // Skip if already indexed with matching hash (unless forcing reindex)
      if (existing != null &&
          existing.textHash == textHash &&
          _repo.decodeMetadata(existing)?['embeddingSignature'] ==
              embeddingModelSignature(config) &&
          _repo.hasUsableVectors(existing) &&
          existing.errorJson == null) {
        skipped++;
        continue;
      }

      // retryFailedOnly: skip entries that have no error (i.e. already good or just not indexed)
      if (retryFailedOnly && existing != null && existing.errorJson == null) {
        skipped++;
        continue;
      }

      if (text.trim().isEmpty) {
        await _repo.putEmbeddingError(
          entryId: namespacedId,
          sourceType: 'lorebook_entry',
          sourceId: lorebookId,
          textHash: textHash,
          error: {
            'type': 'empty_text',
            'message': 'Entry content is empty',
            'retryable': false,
          },
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            const [],
            hints: hints,
          ),
        );
        failed++;
        continue;
      }

      try {
        final chunks = await _embeddingService.getEmbeddingsWithChunks([
          text,
        ], config);
        final vectors = chunks.map((c) => c.vector).toList();

        await _repo.putEmbeddingVector(
          entryId: namespacedId,
          sourceType: 'lorebook_entry',
          sourceId: lorebookId,
          vectors: vectors,
          textHash: textHash,
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            vectors,
            hints: hints,
          ),
        );
        indexed++;
      } on RateLimitException catch (e) {
        rateLimited = true;
        retryAfter = e.retryAfter;

        for (int j = i + 1; j < indexable.length; j++) {
          final laterEntry = indexable[j];
          final laterText = lorebookEmbeddingText(laterEntry, embeddingTarget);
          final laterHash = computeHash(
            buildEmbeddingFingerprint(laterEntry, laterText),
          );
          await _repo.putEmbeddingError(
            entryId: '${lorebookId}_${laterEntry.id}',
            sourceType: 'lorebook_entry',
            sourceId: lorebookId,
            textHash: laterHash,
            error: {
              'type': 'rate_limit',
              'message': 'Rate limited, deferred',
              'retryable': true,
            },
            retrievalMetadata: embeddingMetadataForConfig(
              config,
              const [],
              hints: extractRetrievalHints(laterEntry),
            ),
          );
          failed++;
        }
        break;
      } catch (e) {
        final laterHash = computeHash(buildEmbeddingFingerprint(entry, text));
        await _repo.putEmbeddingError(
          entryId: namespacedId,
          sourceType: 'lorebook_entry',
          sourceId: lorebookId,
          textHash: laterHash,
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

  static String buildEmbeddingFingerprint(LorebookEntry entry, String text) {
    return jsonEncode({
      'text': text,
      'retrievalHints': extractRetrievalHints(entry),
    });
  }

  static List<String> extractRetrievalHints(LorebookEntry entry) {
    return extractRetrievalHintsFrom(
      label: entry.comment,
      keys: entry.keys,
      content: entry.content,
    );
  }
}

class IndexResult {
  final int indexed;
  final int skipped;
  final int failed;
  final bool rateLimited;
  final int retryAfter;

  const IndexResult({
    this.indexed = 0,
    this.skipped = 0,
    this.failed = 0,
    this.rateLimited = false,
    this.retryAfter = 0,
  });
}

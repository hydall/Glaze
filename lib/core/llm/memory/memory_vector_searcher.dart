import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

import '../../db/app_db.dart';
import '../../db/repositories/embedding_repo.dart';
import '../../models/chat_message.dart';
import '../../models/memory_book.dart';
import '../embedding_service.dart';
import '../memory_embedding_service.dart';
import '../retrieval_query_builder.dart';
import '../vector_math.dart';

/// Result of a memory vector search: per-entry similarity scores and the
/// matched chunk texts keyed by entry id.
class MemoryVectorMatchResult {
  final Map<String, double> scores;
  final Map<String, List<String>> chunksByEntryId;

  const MemoryVectorMatchResult({
    this.scores = const {},
    this.chunksByEntryId = const {},
  });
}

/// Performs vector similarity search over memory entries using stored
/// embeddings and a live embedding API call for the retrieval query.
///
/// Extracted from `MemoryInjectionService` (Phase 6a). The service holds
/// the embedding repo + embedding service; the matcher is pure I/O.
class MemoryVectorSearcher {
  final EmbeddingRepo _embeddingRepo;
  final EmbeddingService _embeddingService;

  MemoryVectorSearcher(this._embeddingRepo, this._embeddingService);

  /// Search memory entries by vector similarity.
  ///
  /// - Loads stored embedding rows for `memory_entry` source type.
  /// - Filters entries with usable, hash-matched vectors.
  /// - Builds a retrieval query (legacy or v2) and embeds it.
  /// - Returns top-K entries above [settings.vectorThreshold] with their
  ///   best matching chunk texts (plus immediate neighbors).
  Future<MemoryVectorMatchResult> search(
    List<MemoryEntry> entries,
    List<ChatMessage> history,
    String currentText,
    EmbeddingConfig config,
    MemoryGlobalSettings settings, {
    bool Function()? shouldAbort,
    CancelToken? cancelToken,
  }) async {
    try {
      if (shouldAbort?.call() == true) return const MemoryVectorMatchResult();
      debugPrint('[mem-vec] reading embeddings from DB...');
      final embeddingRows = await _embeddingRepo.getBySourceType(
        'memory_entry',
      );
      if (shouldAbort?.call() == true) return const MemoryVectorMatchResult();
      final embeddingMap = <String, EmbeddingRow>{};
      for (final row in embeddingRows) {
        embeddingMap[row.entryId] = row;
      }
      debugPrint('[mem-vec] loaded ${embeddingRows.length} embedding rows');

      final candidates = <VectorCandidate>[];
      for (int i = 0; i < entries.length; i++) {
        final entry = entries[i];
        debugPrint(
          '[mem-vec] processing entry ${i + 1}/${entries.length}: id=${entry.id}',
        );
        final row = embeddingMap[entry.id];
        if (shouldAbort?.call() == true) {
          return const MemoryVectorMatchResult();
        }
        if (row == null || !_embeddingRepo.hasUsableVectors(row)) {
          debugPrint('[mem-vec]   skipped: no row or no vectorsBlob');
          continue;
        }

        final text = entry.content;
        final hints = MemoryEmbeddingService.extractMemoryRetrievalHints(entry);
        final fingerprint = jsonEncode({'text': text, 'retrievalHints': hints});
        final currentHash = sha256.convert(utf8.encode(fingerprint)).toString();
        if (row.textHash != currentHash) {
          debugPrint('[mem-vec]   skipped: hash mismatch');
          continue;
        }

        final vectors = _embeddingRepo.decodeVectors(row);
        if (vectors == null || vectors.isEmpty) {
          debugPrint('[mem-vec]   skipped: vectors null or empty');
          continue;
        }
        final chunkTexts = decodeMemoryChunkTexts(row, vectors.length);

        candidates.add(
          VectorCandidate(
            id: entry.id,
            vectors: vectors
                .asMap()
                .entries
                .map(
                  (v) => VectorChunk(
                    text: v.key < chunkTexts.length ? chunkTexts[v.key] : '',
                    vector: v.value,
                  ),
                )
                .toList(),
            metadata: {
              'hints': _embeddingRepo.decodeHints(row) ?? [],
              'chunkTexts': chunkTexts,
            },
          ),
        );
        debugPrint(
          '[mem-vec]   added candidate with ${vectors.length} vectors',
        );
      }
      debugPrint('[mem-vec] valid candidates: ${candidates.length}');

      if (candidates.isEmpty) return const MemoryVectorMatchResult();

      final queryText = settings.memoryMode == 'legacy'
          ? legacyVectorQuery(history, currentText)
          : RetrievalQueryBuilder.build(
              currentText: currentText,
              history: history,
              includeAssistant: settings.queryIncludeAssistant,
              recentTurns: settings.queryRecentTurns,
              maxChars: settings.queryMaxChars,
            );
      if (queryText.isEmpty) return const MemoryVectorMatchResult();
      if (shouldAbort?.call() == true) return const MemoryVectorMatchResult();

      debugPrint(
        '[mem-vec] calling embedding API (endpoint=${config.endpoint})...',
      );
      final queryChunks = await _embeddingService
          .getEmbeddingsWithChunks(
            [queryText],
            config,
            cancelToken: cancelToken,
          )
          .timeout(const Duration(seconds: 30), onTimeout: () => []);
      if (cancelToken?.isCancelled == true) {
        return const MemoryVectorMatchResult();
      }
      debugPrint(
        '[mem-vec] embedding API returned ${queryChunks.length} chunks',
      );
      if (queryChunks.isEmpty) return const MemoryVectorMatchResult();

      final queryVecChunks = queryChunks
          .map((c) => VectorChunk(text: c.text, vector: c.vector))
          .toList();
      final results = findTopKMulti(
        queryVecChunks,
        candidates,
        candidates.length,
        0,
      );

      final threshold = settings.vectorThreshold;
      final topK = settings.maxInjectedEntries.clamp(1, 50);
      final scores = <String, double>{};
      final chunksByEntryId = <String, List<String>>{};
      for (final result
          in results.where((r) => r.score >= threshold).take(topK)) {
        scores[result.id] = result.score;
        final chunkTexts = result.metadata['chunkTexts'];
        if (chunkTexts is List && result.bestCandidateChunk != null) {
          final bestIndex = result.bestCandidateChunk!;
          final matched = <String>[];
          if (bestIndex >= 0 && bestIndex < chunkTexts.length) {
            final text = chunkTexts[bestIndex];
            if (text is String && text.trim().isNotEmpty) matched.add(text);
          }
          final neighboringIndexes = [bestIndex - 1, bestIndex + 1];
          for (final index in neighboringIndexes) {
            if (index < 0 || index >= chunkTexts.length) continue;
            final text = chunkTexts[index];
            if (text is String && text.trim().isNotEmpty) matched.add(text);
          }
          if (matched.isNotEmpty) chunksByEntryId[result.id] = matched;
        }
      }
      return MemoryVectorMatchResult(
        scores: scores,
        chunksByEntryId: chunksByEntryId,
      );
    } catch (_) {
      return const MemoryVectorMatchResult();
    }
  }

  /// Decode the per-chunk text metadata stored alongside vectors.
  List<String> decodeMemoryChunkTexts(EmbeddingRow row, int vectorCount) {
    final metadata = _embeddingRepo.decodeMetadata(row);
    final chunks = metadata?['chunks'];
    if (chunks is! List) return const [];
    final texts = List<String>.filled(vectorCount, '');
    for (final chunk in chunks) {
      if (chunk is! Map) continue;
      final indexRaw = chunk['index'];
      final textRaw = chunk['text'];
      if (indexRaw is! num || textRaw is! String) continue;
      final index = indexRaw.toInt();
      if (index < 0 || index >= texts.length) continue;
      texts[index] = textRaw;
    }
    return texts;
  }

  /// Legacy vector query: current text + recent user turns up to 1500 chars.
  static String legacyVectorQuery(
    List<ChatMessage> history,
    String currentText,
  ) {
    final parts = <String>[];
    if (currentText.trim().isNotEmpty) parts.add(currentText.trim());
    var chars = parts.fold<int>(0, (sum, part) => sum + part.length);
    for (int i = history.length - 1; i >= 0; i--) {
      final msg = history[i];
      if (msg.isHidden || msg.isTyping || msg.role != 'user') continue;
      final text = msg.content.trim();
      if (text.isEmpty || text == currentText.trim()) continue;
      if (chars + text.length > 1500) break;
      parts.add(text);
      chars += text.length;
    }
    return parts.join('\n').trim();
  }
}

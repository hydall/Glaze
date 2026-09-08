import '../models/character.dart';
import '../models/lorebook.dart';
import '../db/app_db.dart';
import '../db/repositories/embedding_repo.dart';
import '../utils/cast_helpers.dart';
import 'package:dio/dio.dart';
import 'embedding_service.dart';
import 'embedding_types.dart';
import 'lorebook_embedding_service.dart';
import 'vector_math.dart';

class VectorSearchResult {
  final String entryId;
  final double score;
  final String lorebookId;

  const VectorSearchResult({
    required this.entryId,
    required this.score,
    required this.lorebookId,
  });
}

class LorebookVectorSearch {
  final EmbeddingRepo _repo;
  final EmbeddingService _embeddingService;

  LorebookVectorSearch(this._repo, this._embeddingService);

  Future<List<VectorSearchResult>> search(
    List<ChatMessageForSearch> history,
    String currentText,
    List<Lorebook> lorebooks,
    LorebookGlobalSettings settings,
    EmbeddingConfig config, {
    String? charWorld,
    Character? character,
    LorebookActivations? activations,
    String? chatId,
    int? overrideTopK,
    CancelToken? cancelToken,
  }) async {
    if (settings.searchType == 'keyword') return [];

    final charId = character?.id;
    final activeLorebooks = lorebooks.where((lb) {
      if (lb.enabled) return true;
      if (charId != null &&
          activations?.character[charId]?.contains(lb.id) == true) {
        return true;
      }
      if (chatId != null &&
          activations?.chat[chatId]?.contains(lb.id) == true) {
        return true;
      }
      if (charId != null &&
          lb.activationScope == 'character' &&
          lb.activationTargetId == charId) {
        return true;
      }
      if (chatId != null &&
          lb.activationScope == 'chat' &&
          lb.activationTargetId == chatId) {
        return true;
      }
      if (charWorld != null && charWorld.isNotEmpty && lb.name == charWorld) {
        return true;
      }
      return false;
    }).toList();

    activeLorebooks.removeWhere((lb) {
      final lbSettings = lb.settings;
      return lbSettings != null && !lbSettings.vectorSearchEnabled;
    });

    var effectiveThreshold = settings.vectorThreshold;
    var effectiveTopK = overrideTopK ?? settings.vectorTopK;
    int? configuredScanDepth;
    for (final lb in activeLorebooks) {
      final lbSettings = lb.settings;
      if (lbSettings != null) {
        if (lbSettings.vectorThreshold < effectiveThreshold) {
          effectiveThreshold = lbSettings.vectorThreshold;
        }
        if (lbSettings.vectorTopK > effectiveTopK) {
          effectiveTopK = lbSettings.vectorTopK;
        }
        if (configuredScanDepth == null ||
            lbSettings.vectorScanDepth > configuredScanDepth) {
          configuredScanDepth = lbSettings.vectorScanDepth;
        }
      }
    }
    final effectiveScanDepth = configuredScanDepth ?? 5;

    final vectorEntries = <(LorebookEntry, String)>[];
    // NEW (patch #4 follow-up — Marinara analog): semantic fallback pool
    // for keyless entries. Entries with no keys AND no secondaryKeys cannot
    // activate via keyword scan; this fallback activates them via cosine
    // similarity against the current chat text. Threshold is lower (default
    // 0.3) and topK is smaller (default 3) to avoid flooding the prompt.
    // Rationale: keyless entries cannot activate via keyword scan; this
    // semantic fallback activates them via cosine similarity (Marinara
    // supplementary system 4 analog).
    final fallbackEntries = <(LorebookEntry, String)>[];
    for (final lb in activeLorebooks) {
      for (final entry in lb.entries) {
        if (!entry.enabled || entry.constant) continue;
        if (entry.excludeFromVectorization) continue;
        if (_isFilteredByCharacter(entry, character)) continue;
        if (entry.vectorSearch) {
          vectorEntries.add((entry, lb.id));
        } else if (entry.keys.isEmpty && entry.secondaryKeys.isEmpty) {
          // Keyless + vectorSearch=false → eligible for semantic fallback.
          // These are indexed by LorebookEmbeddingService (which now
          // extends its indexable pool to include keyless entries).
          fallbackEntries.add((entry, lb.id));
        }
      }
    }

    if (vectorEntries.isEmpty && fallbackEntries.isEmpty) return [];

    final relevantLorebookIds = {
      for (final (_, lorebookId) in vectorEntries) lorebookId,
      for (final (_, lorebookId) in fallbackEntries) lorebookId,
    };
    final embeddingRows = await _repo.getBySourceIds(
      'lorebook_entry',
      relevantLorebookIds,
    );

    final embeddingMap = <String, EmbeddingRow>{};
    for (final row in embeddingRows) {
      embeddingMap[row.entryId] = row;
    }

    final candidates = <VectorCandidate>[];
    for (final (entry, lbId) in vectorEntries) {
      final namespacedId = '${lbId}_${entry.id}';
      final row = embeddingMap[namespacedId];
      if (row == null || row.vectorsBlob == null) continue;

      final text = _getEmbeddingText(entry, lorebooks, lbId);
      final fingerprint = LorebookEmbeddingService.buildEmbeddingFingerprint(
        entry,
        text,
      );
      final currentHash = computeHash(fingerprint);
      if (row.textHash != currentHash) continue;

      final vectors = _repo.decodeVectors(row);
      if (vectors == null || vectors.isEmpty) continue;

      candidates.add(
        VectorCandidate(
          id: entry.id,
          vectors: vectors
              .map((v) => VectorChunk(text: '', vector: v))
              .toList(),
          metadata: {
            'lorebookId': lbId,
            'entry': entry,
            'hints': _repo.decodeHints(row) ?? [],
          },
        ),
      );
    }

    // Separate candidate pool for fallback (keyless) entries.
    final fallbackCandidates = <VectorCandidate>[];
    for (final (entry, lbId) in fallbackEntries) {
      final namespacedId = '${lbId}_${entry.id}';
      final row = embeddingMap[namespacedId];
      if (row == null || row.vectorsBlob == null) continue;

      final text = _getEmbeddingText(entry, lorebooks, lbId);
      final fingerprint = LorebookEmbeddingService.buildEmbeddingFingerprint(
        entry,
        text,
      );
      final currentHash = computeHash(fingerprint);
      if (row.textHash != currentHash) continue;

      final vectors = _repo.decodeVectors(row);
      if (vectors == null || vectors.isEmpty) continue;

      fallbackCandidates.add(
        VectorCandidate(
          id: entry.id,
          vectors: vectors
              .map((v) => VectorChunk(text: '', vector: v))
              .toList(),
          metadata: {
            'lorebookId': lbId,
            'entry': entry,
            'hints': _repo.decodeHints(row) ?? [],
          },
        ),
      );
    }

    if (candidates.isEmpty && fallbackCandidates.isEmpty) return [];

    final recentHistory = effectiveScanDepth <= 0
        ? const <ChatMessageForSearch>[]
        : history
              .skip(
                (history.length - effectiveScanDepth).clamp(0, history.length),
              )
              .toList();
    final focusedQuery = _buildFocusedQuery(
      recentHistory,
      currentText,
      config.maxChunkTokens,
    );
    final fallbackQuery = _buildFallbackQuery(
      recentHistory,
      currentText,
      config.maxChunkTokens,
    );

    final allResults = <String, double>{};
    final allLorebookIds = <String, String>{};

    Future<List<VectorChunk>> embedQuery(String query) async {
      final chunks = await _embeddingService.getEmbeddingsWithChunks(
        [query],
        config,
        cancelToken: cancelToken,
      );
      return chunks
          .map((c) => VectorChunk(text: c.text, vector: c.vector))
          .toList();
    }

    final focusedChunks = focusedQuery.isNotEmpty
        ? embedQuery(focusedQuery)
        : null;

    Future<void> searchPool(
      List<VectorCandidate> pool,
      String query,
      Future<List<VectorChunk>>? sharedChunks,
    ) async {
      if (query.isEmpty || pool.isEmpty) return;
      final vecChunks = await (sharedChunks ?? embedQuery(query));
      final results = findTopKMulti(vecChunks, pool, pool.length, 0);
      for (final r in results) {
        final entry = r.metadata['entry'] as LorebookEntry;
        final lorebookId = r.metadata['lorebookId'] as String;
        final resultId = '${lorebookId}_${entry.id}';
        final hints = r.metadata['hints'] as List<String>;
        final boosted = _applyHybridBoost(r.score, entry, hints, query);
        if (allResults[resultId] == null || boosted > allResults[resultId]!) {
          allResults[resultId] = boosted;
        }
        allLorebookIds[resultId] = lorebookId;
      }
    }

    // Main vector pool (vectorSearch=true entries) — both focused and
    // fallback queries if available. Run in parallel with a 1s stagger
    // to avoid bursting the embedding endpoint with simultaneous requests.
    final mainFutures = <Future<void>>[];
    if (focusedQuery.isNotEmpty) {
      mainFutures.add(searchPool(candidates, focusedQuery, focusedChunks));
    }
    if (fallbackQuery.isNotEmpty && fallbackQuery != focusedQuery) {
      mainFutures.add(
        Future.delayed(
          const Duration(seconds: 1),
          () => searchPool(candidates, fallbackQuery, null),
        ),
      );
    }
    // Keyless fallback reuses the focused query's in-flight embedding request.
    // Starting another identical request here bypasses the cache until the
    // first one completes and can trigger rate limits on slower endpoints.
    final fallbackThreshold = settings.fallbackThreshold;
    final fallbackTopK = settings.fallbackTopK;
    final fallbackResults = <String, double>{};
    final fallbackLorebookIds = <String, String>{};
    if (focusedChunks != null && fallbackCandidates.isNotEmpty) {
      mainFutures.add(() async {
        final vecChunks = await focusedChunks;
        final results = findTopKMulti(
          vecChunks,
          fallbackCandidates,
          fallbackCandidates.length,
          0,
        );
        for (final r in results) {
          final entry = r.metadata['entry'] as LorebookEntry;
          final lorebookId = r.metadata['lorebookId'] as String;
          final resultId = '${lorebookId}_${entry.id}';
          final score = r.score;
          if (score >= fallbackThreshold) {
            fallbackResults[resultId] = score;
            fallbackLorebookIds[resultId] = lorebookId;
          }
        }
      }());
    }
    await Future.wait(mainFutures);

    final threshold = effectiveThreshold;
    final topK = effectiveTopK;

    final sorted = allResults.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final mainResults = sorted
        .where((e) => e.value >= threshold)
        .take(topK)
        .map(
          (e) => VectorSearchResult(
            entryId: e.key.substring((allLorebookIds[e.key]?.length ?? -1) + 1),
            score: e.value,
            lorebookId: allLorebookIds[e.key] ?? '',
          ),
        )
        .toList();

    // Merge fallback results into the final list. Take top fallbackTopK
    // sorted by score, then dedupe against mainResults (entryId) so a
    // keyless entry that also has vectorSearch=true is not double-counted.
    final fallbackSorted = fallbackResults.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final mainIds = mainResults
        .map((r) => '${r.lorebookId}_${r.entryId}')
        .toSet();
    final fallbackFinal = fallbackSorted
        .where((e) => !mainIds.contains(e.key))
        .take(fallbackTopK)
        .map(
          (e) => VectorSearchResult(
            entryId: e.key.substring(
              (fallbackLorebookIds[e.key]?.length ?? -1) + 1,
            ),
            score: e.value,
            lorebookId: fallbackLorebookIds[e.key] ?? '',
          ),
        )
        .toList();

    return [...mainResults, ...fallbackFinal];
  }

  String _buildFocusedQuery(
    List<ChatMessageForSearch> history,
    String currentText,
    int maxChunkTokens,
  ) {
    final userMessages = history
        .where((m) => m.role == 'user')
        .toList()
        .reversed;
    final maxChars = (maxChunkTokens * 2).clamp(0, 1024) * 4;
    final buffer = StringBuffer();

    buffer.write(currentText);

    var skippedCurrent = false;
    for (final msg in userMessages) {
      if (!skippedCurrent && msg.content == currentText) {
        skippedCurrent = true;
        continue;
      }
      final toAdd = '\n${msg.content}';
      if (buffer.length + toAdd.length > maxChars.clamp(0, 6000)) break;
      buffer.write(toAdd);
    }

    return _sanitizeQuery(buffer.toString());
  }

  String _buildFallbackQuery(
    List<ChatMessageForSearch> history,
    String currentText,
    int maxChunkTokens,
  ) {
    final maxChars = (maxChunkTokens * 3).clamp(0, 1536) * 4;
    final buffer = StringBuffer();

    buffer.write(currentText);

    var skippedCurrent = false;
    for (final msg in history.reversed) {
      if (!skippedCurrent && msg.content == currentText) {
        skippedCurrent = true;
        continue;
      }
      final toAdd = '\n${msg.content}';
      if (buffer.length + toAdd.length > maxChars.clamp(0, 10000)) break;
      buffer.write(toAdd);
    }

    return _sanitizeQuery(buffer.toString());
  }

  String _sanitizeQuery(String text) {
    var clean = text;
    clean = clean.replaceAll(RegExp(r'<[^>]+>'), '');
    clean = clean.replaceAll(RegExp(r'\(OOC:.*?\)', caseSensitive: false), '');
    clean = clean.replaceAll(RegExp(r'data:image/[^;]+;base64,[^\s]+'), '');
    return clean.trim();
  }

  double _applyHybridBoost(
    double rawScore,
    LorebookEntry entry,
    List<String> hints,
    String queryText,
  ) {
    double boost = 0;
    final queryLower = queryText.toLowerCase();

    final nameInQuery =
        entry.comment.isNotEmpty &&
        queryLower.contains(entry.comment.toLowerCase());
    if (nameInQuery) {
      boost += 0.18;
    }

    int keyOverlap = 0;
    for (final key in entry.keys) {
      if (queryLower.contains(key.toLowerCase())) {
        keyOverlap++;
      }
    }
    boost += (keyOverlap * 0.04).clamp(0, 0.12);

    int hintOverlap = 0;
    final queryTokens = _tokenize(queryLower);
    for (final hint in hints) {
      final hintTokens = _tokenize(hint.toLowerCase());
      for (final ht in hintTokens) {
        if (queryTokens.contains(ht)) {
          hintOverlap++;
        }
      }
    }
    boost += (hintOverlap * 0.025).clamp(0, 0.10);

    return (rawScore + boost).clamp(0, 1);
  }

  List<String> _tokenize(String text) {
    return text
        .split(RegExp(r'[\s,.;:!?]+'))
        .where((t) => t.length > 2)
        .toList();
  }

  String _getEmbeddingText(
    LorebookEntry entry,
    List<Lorebook> lorebooks,
    String lbId,
  ) {
    final lb = lorebooks.where((l) => l.id == lbId).firstOrNull;
    final target = lb?.settings?.embeddingTarget ?? 'content';
    if (target == 'keys') {
      return entry.keys.join(', ');
    }
    return entry.content;
  }

  bool _isFilteredByCharacter(LorebookEntry entry, Character? character) {
    if (character == null) return false;
    final filter = entry.characterFilter;
    if (filter == null) return false;
    if (filter.names.isEmpty) return false;
    final charName = character.name.toLowerCase();
    final isInCategory = filter.names.any(
      (n) => charName.contains(n.toLowerCase()),
    );
    if (filter.isExclude && isInCategory) return true;
    if (!filter.isExclude && !isInCategory) return true;
    return false;
  }
}

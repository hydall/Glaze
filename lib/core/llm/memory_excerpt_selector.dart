import '../models/memory_book.dart';
import 'memory/memory_chunker.dart';
import 'memory/excerpt_scorer.dart';
import 'memory_selector.dart';
import 'tokenizer.dart';

export 'memory/memory_chunker.dart' show ExcerptChunk, MemoryChunker;
export 'memory/excerpt_scorer.dart'
    show ScoredChunk, GlobalChunkCandidate, ExcerptScorer;

const defaultMemoryExcerptTokensPerEntry = 500;
const defaultMemoryExcerptChunksPerEntry = 2;

class MemoryInjectionItem {
  final MemoryEntry entry;
  final bool excerpt;
  final String text;
  final int tokenCost;
  final int originalTokenCost;
  final List<int> chunkIndexes;
  final List<String> matchedTerms;
  final String reason;

  const MemoryInjectionItem({
    required this.entry,
    required this.excerpt,
    required this.text,
    required this.tokenCost,
    required this.originalTokenCost,
    this.chunkIndexes = const [],
    this.matchedTerms = const [],
    this.reason = 'full_entry',
  });
}

class MemoryExcerptSelection {
  final List<MemoryInjectionItem> items;
  final int totalTokens;
  final bool budgetTrimmed;

  const MemoryExcerptSelection({
    this.items = const [],
    this.totalTokens = 0,
    this.budgetTrimmed = false,
  });

  List<MemoryEntry> get entries => items.map((item) => item.entry).toList();
}

class MemoryExcerptSelector {
  const MemoryExcerptSelector._();

  static MemoryExcerptSelection fullEntries(MemorySelection selection) {
    final items = selection.entries
        .map(
          (entry) => MemoryInjectionItem(
            entry: entry,
            excerpt: false,
            text: entry.content.trim(),
            tokenCost: estimateTokens(entry.content),
            originalTokenCost: estimateTokens(entry.content),
          ),
        )
        .toList(growable: false);
    return MemoryExcerptSelection(
      items: items,
      totalTokens: items.fold<int>(0, (sum, item) => sum + item.tokenCost),
      budgetTrimmed: selection.budgetTrimmed,
    );
  }

  static MemoryExcerptSelection select(
    MemorySelection selection, {
    String packingMode = 'hybrid',
    int maxExcerptTokensPerEntry = defaultMemoryExcerptTokensPerEntry,
    int maxExcerptChunksPerEntry = defaultMemoryExcerptChunksPerEntry,
    int chunkFirstTopEntries = 3,
    int chunkFirstTopChunks = 1,
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    final budget = selection.budgetTokens;
    final normalizedPackingMode = _normalizePackingMode(packingMode);
    final selectedIds = selection.entries.map((entry) => entry.id).toSet();
    final selectedFullTokens = selection.entries.fold<int>(
      0,
      (sum, entry) => sum + tokenFn(entry.content),
    );

    if (normalizedPackingMode == 'chunk_first') {
      return selectChunkFirstGlobal(
        selection,
        maxExcerptTokensPerChunk: maxExcerptTokensPerEntry,
        maxExcerptChunksPerEntry: maxExcerptChunksPerEntry,
        topEntries: chunkFirstTopEntries,
        topChunks: chunkFirstTopChunks,
        tokenCounter: tokenFn,
      );
    }

    if (normalizedPackingMode == 'full' ||
        budget == null ||
        (normalizedPackingMode == 'hybrid' &&
            selectedFullTokens <= budget &&
            !selection.budgetTrimmed)) {
      return fullEntries(selection);
    }

    final cap = selection.entryCap > 0
        ? selection.entryCap
        : selection.entries.length;
    final items = <MemoryInjectionItem>[];
    var usedTokens = 0;
    var trimmed = selection.budgetTrimmed;

    for (final score in selection.allScores) {
      if (score.excludedBySourceWindow) continue;
      if (items.length >= cap) break;
      final entry = score.entry;
      final fullText = entry.content.trim();
      if (fullText.isEmpty) continue;
      final fullTokens = tokenFn(fullText);

      if (normalizedPackingMode == 'hybrid' &&
          usedTokens + fullTokens <= budget) {
        items.add(
          MemoryInjectionItem(
            entry: entry,
            excerpt: false,
            text: fullText,
            tokenCost: fullTokens,
            originalTokenCost: fullTokens,
          ),
        );
        usedTokens += fullTokens;
        continue;
      }

      final remaining = budget - usedTokens;
      if (remaining <= 0 && items.isNotEmpty) {
        trimmed = true;
        continue;
      }

      final perEntryBudget = budget <= 0
          ? 0
          : items.isEmpty
          ? maxExcerptTokensPerEntry.clamp(1, budget)
          : maxExcerptTokensPerEntry.clamp(1, remaining);
      final excerpt = _buildExcerpt(
        score,
        maxTokens: perEntryBudget,
        maxChunks: maxExcerptChunksPerEntry,
        tokenCounter: tokenFn,
      );

      if (excerpt == null) {
        if (items.isEmpty && selectedIds.contains(entry.id)) {
          items.add(
            MemoryInjectionItem(
              entry: entry,
              excerpt: false,
              text: fullText,
              tokenCost: fullTokens,
              originalTokenCost: fullTokens,
              reason: 'first_entry_fallback',
            ),
          );
          usedTokens += fullTokens;
        } else {
          trimmed = true;
        }
        continue;
      }

      if (usedTokens + excerpt.tokenCost <= budget || items.isEmpty) {
        items.add(excerpt);
        usedTokens += excerpt.tokenCost;
      } else {
        trimmed = true;
      }
    }

    return MemoryExcerptSelection(
      items: _chronologicalItems(items),
      totalTokens: usedTokens,
      budgetTrimmed: trimmed,
    );
  }

  /// Ranks every chunk from every candidate entry globally, then packs by
  /// injected chunk token cost (not full-entry cost). One query embedding
  /// still compares against all stored chunk vectors upstream.
  static MemoryExcerptSelection selectChunkFirstGlobal(
    MemorySelection selection, {
    int maxExcerptTokensPerChunk = defaultMemoryExcerptTokensPerEntry,
    int maxExcerptChunksPerEntry = defaultMemoryExcerptChunksPerEntry,
    int topEntries = 3,
    int topChunks = 1,
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    final budget = selection.budgetTokens;
    final ranked = <GlobalChunkCandidate>[];

    for (final score in selection.allScores) {
      if (score.excludedBySourceWindow) continue;
      final fullText = score.entry.content.trim();
      if (fullText.isEmpty) continue;

      final chunks = MemoryChunker.chunk(fullText, maxExcerptTokensPerChunk, tokenFn);
      final terms = ExcerptScorer.termsFor(score);
      for (final chunk in chunks) {
        ranked.add(
          GlobalChunkCandidate(
            entry: score.entry,
            entryScore: score.score,
            recencyScore: score.recencyScore,
            vectorScore: score.vectorScore,
            chunkIndex: chunk.index,
            text: chunk.text,
            tokenCost: chunk.tokenCost,
            relevance: ExcerptScorer.chunkRelevance(chunk.text, score, terms),
          ),
        );
      }
    }

    ranked.sort((a, b) {
      final byRel = b.relevance.compareTo(a.relevance);
      if (byRel != 0) return byRel;
      final byEntry = b.entryScore.compareTo(a.entryScore);
      if (byEntry != 0) return byEntry;
      return a.chunkIndex.compareTo(b.chunkIndex);
    });

    final perEntry = <String, List<GlobalChunkCandidate>>{};
    var usedTokens = 0;
    var trimmed = false;

    // Phase 1: top entries by entry score each get up to [topChunks] best chunks
    // so recency / vector-implied relevance is not drowned out by keyword-heavy
    // older arcs.
    final rankedByEntry = <String, List<GlobalChunkCandidate>>{};
    for (final candidate in ranked) {
      rankedByEntry
          .putIfAbsent(candidate.entry.id, () => <GlobalChunkCandidate>[])
          .add(candidate);
    }
    final entryFloorCap = topEntries.clamp(0, 64);
    final chunksPerGuaranteedEntry = topChunks.clamp(1, maxExcerptChunksPerEntry);
    if (entryFloorCap > 0) {
      var floorEntriesProcessed = 0;
      for (final score in selection.allScores) {
        if (score.excludedBySourceWindow) continue;
        final entryChunks = rankedByEntry[score.entry.id];
        if (entryChunks == null || entryChunks.isEmpty) continue;
        if (floorEntriesProcessed >= entryFloorCap) break;
        floorEntriesProcessed++;

        var addedForEntry = 0;
        for (final candidate in entryChunks) {
          if (addedForEntry >= chunksPerGuaranteedEntry) break;
          if (_tryAddGlobalChunk(
            candidate,
            perEntry,
            maxExcerptChunksPerEntry: maxExcerptChunksPerEntry,
            budget: budget,
            usedTokens: usedTokens,
          )) {
            usedTokens += candidate.tokenCost;
            addedForEntry++;
          } else {
            trimmed = true;
          }
        }
      }
    }

    // Phase 2: fill remaining budget with globally ranked chunks.
    for (final candidate in ranked) {
      if (_tryAddGlobalChunk(
        candidate,
        perEntry,
        maxExcerptChunksPerEntry: maxExcerptChunksPerEntry,
        budget: budget,
        usedTokens: usedTokens,
      )) {
        usedTokens += candidate.tokenCost;
      } else if (perEntry[candidate.entry.id]?.any(
            (c) => c.chunkIndex == candidate.chunkIndex,
          ) !=
          true) {
        trimmed = true;
      }
    }

    final items = <MemoryInjectionItem>[];
    for (final entry in perEntry.entries) {
      final chunks = entry.value
        ..sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
      final score = selection.allScores.firstWhere(
        (s) => s.entry.id == entry.key,
      );
      final text = chunks.map((c) => c.text).join('\n\n').trim();
      if (text.isEmpty) continue;
      final terms = ExcerptScorer.termsFor(score);
      items.add(
        MemoryInjectionItem(
          entry: chunks.first.entry,
          excerpt: true,
          text: text,
          tokenCost: tokenFn(text),
          originalTokenCost: tokenFn(chunks.first.entry.content),
          chunkIndexes: chunks.map((c) => c.chunkIndex).toList(growable: false),
          matchedTerms: terms
              .where((term) => text.toLowerCase().contains(term))
              .toList(growable: false),
          reason: 'chunk_first_global',
        ),
      );
    }

    return MemoryExcerptSelection(
      items: _chronologicalItems(items),
      totalTokens: usedTokens,
      budgetTrimmed: trimmed,
    );
  }

  static int countChunks(
    String content,
    int maxTokensPerChunk, {
    int Function(String text)? tokenCounter,
  }) {
    return MemoryChunker.countChunks(
      content,
      maxTokensPerChunk,
      tokenCounter: tokenCounter,
    );
  }

  static String _normalizePackingMode(String raw) {
    if (raw == 'full' || raw == 'chunk_first') return raw;
    return 'hybrid';
  }

  static List<MemoryInjectionItem> _chronologicalItems(
    List<MemoryInjectionItem> items,
  ) {
    final out = [...items];
    out.sort((a, b) {
      final ar = a.entry.messageRange;
      final br = b.entry.messageRange;
      final as = ar?.start ?? 1 << 30;
      final bs = br?.start ?? 1 << 30;
      if (as != bs) return as.compareTo(bs);
      final ae = ar?.end ?? as;
      final be = br?.end ?? bs;
      if (ae != be) return ae.compareTo(be);
      return a.entry.id.compareTo(b.entry.id);
    });
    return out;
  }

  static MemoryInjectionItem? _buildExcerpt(
    MemoryCandidateScore score, {
    required int maxTokens,
    required int maxChunks,
    required int Function(String text) tokenCounter,
  }) {
    if (maxTokens <= 0 || maxChunks <= 0) return null;
    final chunks = MemoryChunker.chunk(score.entry.content, maxTokens, tokenCounter);
    if (chunks.isEmpty) return null;
    final terms = ExcerptScorer.termsFor(score);
    final ranked =
        chunks
            .map(
              (chunk) => ScoredChunk(
                chunk,
                ExcerptScorer.chunkRelevance(chunk.text, score, terms),
              ),
            )
            .toList(growable: false)
          ..sort((a, b) {
            final byScore = b.score.compareTo(a.score);
            if (byScore != 0) return byScore;
            return a.chunk.index.compareTo(b.chunk.index);
          });

    final picked = <ExcerptChunk>[];
    var used = 0;
    for (final rankedChunk in ranked) {
      if (picked.length >= maxChunks) break;
      final chunk = rankedChunk.chunk;
      if (used + chunk.tokenCost > maxTokens && picked.isNotEmpty) continue;
      picked.add(chunk);
      used += chunk.tokenCost;
    }
    if (picked.isEmpty) return null;
    picked.sort((a, b) => a.index.compareTo(b.index));
    final text = picked.map((chunk) => chunk.text).join('\n\n').trim();
    if (text.isEmpty) return null;
    final matched = terms
        .where((term) => text.toLowerCase().contains(term))
        .toList(growable: false);
    return MemoryInjectionItem(
      entry: score.entry,
      excerpt: true,
      text: text,
      tokenCost: tokenCounter(text),
      originalTokenCost: tokenCounter(score.entry.content),
      chunkIndexes: picked.map((chunk) => chunk.index).toList(growable: false),
      matchedTerms: matched,
      reason: 'over_budget_excerpt',
    );
  }

  static bool _tryAddGlobalChunk(
    GlobalChunkCandidate candidate,
    Map<String, List<GlobalChunkCandidate>> perEntry, {
    required int maxExcerptChunksPerEntry,
    required int? budget,
    required int usedTokens,
  }) {
    final chunksForEntry = perEntry.putIfAbsent(
      candidate.entry.id,
      () => <GlobalChunkCandidate>[],
    );
    if (chunksForEntry.any((c) => c.chunkIndex == candidate.chunkIndex)) {
      return false;
    }
    if (chunksForEntry.length >= maxExcerptChunksPerEntry) return false;
    if (budget != null &&
        usedTokens + candidate.tokenCost > budget &&
        perEntry.isNotEmpty) {
      return false;
    }
    chunksForEntry.add(candidate);
    return true;
  }
}

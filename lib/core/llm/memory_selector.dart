import 'dart:math' as math;

import '../models/memory_book.dart';
import '../models/memory_graph.dart';
import 'memory_salience_scorer.dart';
import 'tokenizer.dart';
import 'glaze_matcher.dart';

/// Result of one candidate after the deterministic selector.
class MemoryCandidateScore {
  final MemoryEntry entry;
  final double score;
  final double keywordScore;
  final double vectorScore;
  final double recencyScore;
  final double importanceScore;
  final double catalogScore;
  final double diversityPenalty;
  final List<String> matchedKeys;
  final List<String> catalogMatchedTerms;
  final List<String> vectorMatchedChunks;
  final bool excludedBySourceWindow;
  final String? exclusionReason;
  final bool isCore;
  final double salienceScore;
  final double emotionalScore;
  final double entityScore;
  final List<String> emotionalTags;
  final List<String> narrativeFlags;

  const MemoryCandidateScore({
    required this.entry,
    required this.score,
    this.keywordScore = 0,
    this.vectorScore = 0,
    this.recencyScore = 0,
    this.importanceScore = 0,
    this.catalogScore = 0,
    this.diversityPenalty = 0,
    this.matchedKeys = const [],
    this.catalogMatchedTerms = const [],
    this.vectorMatchedChunks = const [],
    this.excludedBySourceWindow = false,
    this.exclusionReason,
    this.isCore = false,
    this.salienceScore = 0,
    this.emotionalScore = 0,
    this.entityScore = 0,
    this.emotionalTags = const [],
    this.narrativeFlags = const [],
  });
}

/// Aggregated result of [MemorySelector.select].
class MemorySelection {
  final String selectionMode;
  final List<MemoryEntry> entries;
  final List<MemoryCandidateScore> allScores;
  final int totalTokens;
  final int? budgetTokens;
  final int entryCap;
  final bool budgetTrimmed;
  final int excludedBySourceWindow;

  const MemorySelection({
    this.selectionMode = 'v2',
    this.entries = const [],
    this.allScores = const [],
    this.totalTokens = 0,
    this.budgetTokens,
    this.entryCap = 0,
    this.budgetTrimmed = false,
    this.excludedBySourceWindow = 0,
  });
}

/// Inputs to [MemorySelector.select]. Both keyword and vector layers are
/// optional so the same selector works in the isolate (no vector API) and
/// in the async injection service (with vector search).
class MemorySelectionInput {
  final String selectionMode;
  final List<MemoryEntry> entries;
  final Map<String, double> vectorScores;
  final Map<String, List<String>> vectorMatchedChunks;
  final Map<String, double> catalogScores;
  final Map<String, List<String>> catalogMatchedTerms;
  final Map<String, List<String>> keywordMatchedTerms;
  final Set<String> visibleMessageIds;
  final int? maxInjectionTokens;
  final int maxInjectedEntries;
  final bool diversityAware;
  final double diversityPenalty;
  final bool recencyBoost;

  /// Historical field name kept for persisted/settings compatibility.
  /// Interpreted as message-count half-life, not wall-clock days.
  final double recencyHalfLifeDays;
  final bool importanceBoost;
  final double importanceWeight;
  final bool sourceWindowExclusion;
  final int currentMessageIndex;
  final double keywordWeight;
  final double vectorWeight;

  /// When true, entry-level token budget is deferred to
  /// [MemoryExcerptSelector] chunk packing (chunk_first mode).
  final bool chunkBudgeting;
  final Map<String, MemorySalience> salienceByEntryId;
  final List<String> queryEmotions;
  final Map<String, int> entityOverlapByEntryId;
  final int now;

  const MemorySelectionInput({
    this.selectionMode = 'v2',
    required this.entries,
    this.vectorScores = const {},
    this.vectorMatchedChunks = const {},
    this.catalogScores = const {},
    this.catalogMatchedTerms = const {},
    this.keywordMatchedTerms = const {},
    this.visibleMessageIds = const {},
    this.maxInjectionTokens,
    this.maxInjectedEntries = 7,
    this.diversityAware = true,
    this.diversityPenalty = 0.15,
    this.recencyBoost = true,
    this.recencyHalfLifeDays = 100,
    this.importanceBoost = true,
    this.importanceWeight = 0.5,
    this.sourceWindowExclusion = true,
    this.currentMessageIndex = 0,
    this.keywordWeight = 6.0,
    this.vectorWeight = 5.0,
    this.chunkBudgeting = false,
    this.salienceByEntryId = const {},
    this.queryEmotions = const [],
    this.entityOverlapByEntryId = const {},
    int? nowSeconds,
  }) : now = nowSeconds ?? 0;

  /// Backwards-compat: callers used `nowSeconds` historically.
  // ignore: prefer_initializing_formals
  factory MemorySelectionInput.legacy({
    required List<MemoryEntry> entries,
    Map<String, double> vectorScores = const {},
    Set<String> visibleMessageIds = const {},
    int? maxInjectionTokens,
    int maxInjectedEntries = 7,
  }) => MemorySelectionInput(
    selectionMode: 'legacy',
    entries: entries,
    vectorScores: vectorScores,
    visibleMessageIds: visibleMessageIds,
    maxInjectionTokens: maxInjectionTokens,
    maxInjectedEntries: maxInjectedEntries,
  );
}

/// Pure selector. No I/O, no DB, no embeddings. Deterministic, testable.
/// Keeps the legacy "first entry always admitted" behavior of
/// [MemoryInjectionBudget] so we don't regress on empty-result corner cases.
class MemorySelector {
  const MemorySelector._();

  /// Per-entry tokens used for budget calculation. Centralized so tests
  /// can stub the estimator without touching the selector.
  static int tokenCost(MemoryEntry entry) => estimateTokens(entry.content);

  static MemorySelection select(
    MemorySelectionInput input, {
    String Function(String key, String text)? keyMatcher,
    int Function(MemoryEntry entry)? tokenCounter,
  }) {
    final entries = input.entries
        .where((e) => e.status == 'active' && e.content.trim().isNotEmpty)
        .toList();

    if (entries.isEmpty) return const MemorySelection();

    final costFn = tokenCounter ?? tokenCost;
    final currentMessageIndex = input.currentMessageIndex > 0
        ? input.currentMessageIndex
        : _latestSourcedMessageIndex(entries);

    final visibleSet = input.visibleMessageIds;
    final legacyMode = input.selectionMode == 'legacy';

    final scored = <MemoryCandidateScore>[];
    for (final entry in entries) {
      if (!legacyMode &&
          input.sourceWindowExclusion &&
          entry.messageIds.isNotEmpty &&
          entry.messageIds.any(visibleSet.contains)) {
        scored.add(
          MemoryCandidateScore(
            entry: entry,
            score: 0,
            excludedBySourceWindow: true,
            exclusionReason: 'source_visible_in_prompt',
          ),
        );
        continue;
      }
      final matched = _matchedKeys(entry, input.keywordMatchedTerms);
      if (legacyMode) {
        final vector = (input.vectorScores[entry.id] ?? 0) * 5.0;
        final keyword = matched.isEmpty ? 0.0 : input.keywordWeight;
        final messageSource = entry.messageIds.isNotEmpty ? 2.0 : 0.0;
        final contentLength = entry.content.trim().length > 20 ? 1.0 : 0.0;
        scored.add(
          MemoryCandidateScore(
            entry: entry,
            score: keyword + vector + messageSource + contentLength,
            keywordScore: keyword,
            vectorScore: vector,
            matchedKeys: matched,
            vectorMatchedChunks:
                input.vectorMatchedChunks[entry.id] ?? const [],
          ),
        );
        continue;
      }
      final vector = (input.vectorScores[entry.id] ?? 0) * input.vectorWeight;
      final keyword = matched.isEmpty
          ? 0.0
          : input.keywordWeight * _keywordBoost(matched, entry.keys.length);
      final catalog = input.catalogScores[entry.id] ?? 0;
      final salience = input.salienceByEntryId[entry.id];
      final recency = input.recencyBoost
          ? _recencyBoost(
              entry,
              input.recencyHalfLifeDays,
              currentMessageIndex,
              salience,
            )
          : 0.0;
      final importance = input.importanceBoost
          ? (entry.importance.clamp(0, 1)) * input.importanceWeight
          : 0.0;
      final baseline = entry.content.trim().length > 20 ? 0.5 : 0.0;

      // Emotional recall (Phase G2): Jaccard overlap between query emotions
      // and entry salience emotional tags, weighted at 0.3.
      final emotionalComponent = _emotionalOverlap(
        input.queryEmotions,
        salience?.emotionalTags ?? const [],
      );

      // Entity fusion (Phase G3): query-mentioned entities that appear in
      // this entry. Weighted at 0.15 per entity, capped at 0.5.
      final entityOverlap = input.entityOverlapByEntryId[entry.id] ?? 0;
      final entityComponent = entityOverlap > 0
          ? math.min(0.5, entityOverlap * 0.15)
          : 0.0;

      final score =
          keyword +
          vector +
          catalog +
          recency +
          importance +
          emotionalComponent +
          entityComponent +
          baseline;
      scored.add(
        MemoryCandidateScore(
          entry: entry,
          score: score,
          keywordScore: keyword,
          vectorScore: vector,
          catalogScore: catalog,
          recencyScore: recency,
          importanceScore: importance,
          matchedKeys: matched,
          catalogMatchedTerms: input.catalogMatchedTerms[entry.id] ?? const [],
          vectorMatchedChunks: input.vectorMatchedChunks[entry.id] ?? const [],
          isCore: MemorySalienceScorer.isCore(salience),
          salienceScore: salience?.score ?? 0,
          emotionalScore: emotionalComponent,
          entityScore: entityComponent,
          emotionalTags: salience?.emotionalTags ?? const [],
          narrativeFlags: salience?.narrativeFlags ?? const [],
        ),
      );
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Deterministic tiebreaker: newer entries win, then by id.
      final at = a.entry.createdAt ?? 0;
      final bt = b.entry.createdAt ?? 0;
      if (at != bt) return bt.compareTo(at);
      return a.entry.id.compareTo(b.entry.id);
    });

    final picked = <MemoryCandidateScore>[];
    final seenTokens = <String>{};
    var usedTokens = 0;
    var trimmedByBudget = false;
    final cap = input.maxInjectedEntries.clamp(0, 64);
    final budget = input.maxInjectionTokens;

    for (final c in scored) {
      if (c.excludedBySourceWindow) continue;
      if (input.chunkBudgeting) {
        picked.add(c);
        continue;
      }
      if (picked.length >= cap) break;
      final cost = costFn(c.entry);
      final wouldOverflow =
          budget != null && usedTokens + cost > budget && picked.isNotEmpty;
      if (wouldOverflow) {
        trimmedByBudget = true;
        break;
      }
      picked.add(c);
      usedTokens += cost;
      if (!legacyMode && input.diversityAware) {
        _accumulateDiversityTokens(c.entry, seenTokens);
        final penalty = _diversityPenaltyFor(
          c.entry,
          picked.sublist(0, picked.length - 1),
          seenTokens,
          input.diversityPenalty,
        );
        // Apply penalty in-place so diagnostics reflect the reranked score.
        final reranked = MemoryCandidateScore(
          entry: c.entry,
          score: c.score - penalty,
          keywordScore: c.keywordScore,
          vectorScore: c.vectorScore,
          catalogScore: c.catalogScore,
          recencyScore: c.recencyScore,
          importanceScore: c.importanceScore,
          diversityPenalty: penalty,
          matchedKeys: c.matchedKeys,
          catalogMatchedTerms: c.catalogMatchedTerms,
          vectorMatchedChunks: c.vectorMatchedChunks,
          isCore: c.isCore,
          salienceScore: c.salienceScore,
          emotionalScore: c.emotionalScore,
          entityScore: c.entityScore,
          emotionalTags: c.emotionalTags,
          narrativeFlags: c.narrativeFlags,
        );
        picked[picked.length - 1] = reranked;
        // Also stamp the reranked score into allScores so the diagnostic
        // surface reflects what was actually injected, not the pre-penalty
        // ranking score. Excluded entries keep their original 0.
        final idx = scored.indexWhere((s) => identical(s.entry, c.entry));
        if (idx >= 0) {
          scored[idx] = reranked;
        }
      }
    }

    return MemorySelection(
      selectionMode: legacyMode ? 'legacy' : 'v2',
      entries: picked.map((p) => p.entry).toList(growable: false),
      allScores: scored,
      totalTokens: usedTokens,
      budgetTokens: budget,
      entryCap: cap,
      budgetTrimmed: trimmedByBudget,
      excludedBySourceWindow: scored
          .where((s) => s.excludedBySourceWindow)
          .length,
    );
  }

  /// Default keyword matcher: case-insensitive substring across the
  /// entries' own keys. Used by the isolate path where the scan text
  /// is not precomputed.
  static List<String> defaultKeywordMatch(MemoryEntry entry, String scanText) {
    final text = scanText.toLowerCase();
    final matched = <String>[];
    for (final key in entry.keys) {
      if (key.isEmpty) continue;
      if (text.contains(key.toLowerCase())) matched.add(key);
    }
    return matched;
  }

  /// Recency boost: message-distance half-life decay.
  ///
  /// This intentionally ignores wall-clock time. A memory's distance is based
  /// on its source message range relative to the newest sourced memory entry.
  /// Entries without source positions get no boost because their narrative
  /// position is unknown.
  ///
  /// Core memory protection (Phase G1, decision C):
  /// - [temporallyBlind] → 1.0 (permanent facts always win).
  /// - Core entries (death/promise/high salience) → 5x slower decay, floor 0.5.
  /// - Normal entries → standard half-life decay.
  /// Returns a value in [0, 1] that callers can scale with recencyWeight.
  static double _recencyBoost(
    MemoryEntry entry,
    double halfLifeMessages,
    int currentMessageIndex,
    MemorySalience? salience,
  ) {
    if (halfLifeMessages <= 0) return 0;

    // temporallyBlind entries bypass decay entirely.
    if (entry.temporallyBlind) return 1.0;

    final end = entry.messageRange?.end;
    if (end == null || end <= 0 || currentMessageIndex <= 0) return 0;

    final distance = (currentMessageIndex - end).clamp(0, currentMessageIndex);

    // Core memory protection: 5x slower decay, floor 0.5.
    if (MemorySalienceScorer.isCore(salience)) {
      final effectiveHalfLife = halfLifeMessages * 5.0;
      final halvings = distance / effectiveHalfLife;
      final decayed = 1.0 / (1.0 + halvings);
      return math.max(0.5, decayed * 0.2);
    }

    final halvings = distance / halfLifeMessages;
    return 1.0 / (1.0 + halvings);
  }

  static int _latestSourcedMessageIndex(List<MemoryEntry> entries) {
    var latest = 0;
    for (final entry in entries) {
      final end = entry.messageRange?.end ?? 0;
      if (end > latest) latest = end;
    }
    return latest;
  }

  static double _keywordBoost(List<String> matched, int totalKeys) {
    if (matched.isEmpty) return 0;
    final t = totalKeys <= 0 ? matched.length : totalKeys;
    return (matched.length / t).clamp(0.0, 1.0);
  }

  /// Jaccard overlap between query emotions and entry emotional tags (Phase G2).
  /// Returns a value in [0, 1] that callers scale by the emotional weight (0.3).
  static double _emotionalOverlap(
    List<String> queryEmotions,
    List<String> entryEmotions,
  ) {
    if (queryEmotions.isEmpty || entryEmotions.isEmpty) return 0;
    final querySet = queryEmotions.toSet();
    final entrySet = entryEmotions.toSet();
    final intersection = querySet.intersection(entrySet).length;
    final union = querySet.union(entrySet).length;
    if (union == 0) return 0;
    return intersection / union;
  }

  static List<String> _matchedKeys(
    MemoryEntry entry,
    Map<String, List<String>> keywordMatchedTerms,
  ) {
    return keywordMatchedTerms[entry.id] ?? const [];
  }

  static void _accumulateDiversityTokens(MemoryEntry entry, Set<String> sink) {
    for (final token in _entryTokens(entry)) {
      sink.add(token);
    }
  }

  static double _diversityPenaltyFor(
    MemoryEntry candidate,
    List<MemoryCandidateScore> alreadyPicked,
    Set<String> seenTokens,
    double penalty,
  ) {
    if (alreadyPicked.isEmpty || penalty <= 0) return 0;
    final candTokens = _entryTokens(candidate);
    var overlap = 0;
    for (final t in candTokens) {
      if (seenTokens.contains(t)) overlap++;
    }
    final tokenPenalty = candTokens.isEmpty
        ? 0.0
        : penalty * (overlap / candTokens.length);
    final temporalPenalty = _temporalDiversityPenaltyFor(
      candidate,
      alreadyPicked,
      penalty,
    );
    return (tokenPenalty + temporalPenalty).clamp(0.0, penalty * 2);
  }

  static double _temporalDiversityPenaltyFor(
    MemoryEntry candidate,
    List<MemoryCandidateScore> alreadyPicked,
    double penalty,
  ) {
    if (candidate.temporallyBlind) return 0;
    final candidateRange = candidate.messageRange;
    final candidateBucket = _temporalBucket(candidateRange);
    if (candidateRange == null || candidateBucket == null) return 0;

    var temporalPenalty = 0.0;
    for (final picked in alreadyPicked) {
      final pickedEntry = picked.entry;
      if (pickedEntry.temporallyBlind) continue;
      final pickedRange = pickedEntry.messageRange;
      final pickedBucket = _temporalBucket(pickedRange);
      if (pickedRange == null || pickedBucket == null) continue;
      if (candidateBucket == pickedBucket) {
        temporalPenalty = math.max(temporalPenalty, penalty);
      } else if (_rangesOverlap(candidateRange, pickedRange)) {
        temporalPenalty = math.max(temporalPenalty, penalty * 0.5);
      }
    }
    return temporalPenalty;
  }

  static int? _temporalBucket(MessageRange? range) {
    final end = range?.end;
    if (end == null || end <= 0) return null;
    const bucketSize = 10;
    return (end - 1) ~/ bucketSize;
  }

  static bool _rangesOverlap(MessageRange a, MessageRange b) {
    return a.start <= b.end && b.start <= a.end;
  }

  static Set<String> _entryTokens(MemoryEntry e) {
    final tokens = <String>{};
    final titleWords = e.title.toLowerCase().split(RegExp(r'[\s,.;:()]+'));
    final keyWords = e.keys.expand(
      (k) => k.toLowerCase().split(RegExp(r'[\s,.;:()]+')),
    );
    final arcWords = e.arc.toLowerCase().split(RegExp(r'[\s,.;:()]+'));
    for (final w in [...titleWords, ...keyWords, ...arcWords]) {
      if (w.length >= 3) tokens.add(w);
    }
    return tokens;
  }
}

/// Re-exports the glaze whole-word matcher for callers that want the
/// same key matching behavior the legacy code used in the async path.
bool memoryKeyMatchesGlaze(String key, String scanText) {
  return glazeCheckMatch(
    key,
    scanText.toLowerCase(),
    false,
    WholeWordMode.glaze,
  );
}

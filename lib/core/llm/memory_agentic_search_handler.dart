import '../models/memory_book.dart';
import 'memory_agentic_policy.dart';
import 'memory_selector.dart';

/// Result of a `searchMemory` tool call.
///
/// Extracted from `memory_agentic_tools.dart` (plan §7.3 cosmetic split).
class MemorySearchResult {
  final List<MemorySearchHit> hits;
  final String? error;

  const MemorySearchResult({this.hits = const [], this.error});

  bool get isEmpty => hits.isEmpty && (error == null || error!.isEmpty);

  Map<String, dynamic> toJson() => {
        'hits': hits.map((h) => h.toJson()).toList(),
        if (error != null) 'error': error,
      };
}

class MemorySearchHit {
  final String entryId;
  final String title;
  final double score;
  final List<String> matchedKeys;
  final int tokenCost;

  const MemorySearchHit({
    required this.entryId,
    required this.title,
    required this.score,
    this.matchedKeys = const [],
    this.tokenCost = 0,
  });

  Map<String, dynamic> toJson() => {
        'entryId': entryId,
        'title': title,
        'score': score.toStringAsFixed(2),
        if (matchedKeys.isNotEmpty) 'matchedKeys': matchedKeys,
        if (tokenCost > 0) 'tokenCost': tokenCost,
      };
}

/// Handler for `searchMemory` tool calls. Bounded retrieval from Memory Book.
///
/// Enforces:
/// - [MemoryAgenticPolicy] permissions (read-only default)
/// - Max results cap (10)
/// - Source-window exclusion
/// - Returns only metadata (id, title, score, keys), NOT full content
///
/// Extracted from `memory_agentic_tools.dart` (plan §7.3 cosmetic split).
class MemoryAgenticToolHandler {
  final MemoryAgenticPolicy policy;

  const MemoryAgenticToolHandler(this.policy);

  /// Execute a `searchMemory` tool call.
  MemorySearchResult searchMemory({
    required List<MemoryEntry> entries,
    required String query,
    required Set<String> visibleMessageIds,
    int maxResults = 5,
    Map<String, double> vectorScores = const {},
    Map<String, List<String>> keywordMatchedTerms = const {},
  }) {
    final decision = policy.canUse(MemoryAgenticTool.inspectContext);
    if (!decision.allowed) {
      return MemorySearchResult(error: decision.reason);
    }

    final capped = maxResults.clamp(1, 10);
    final active = entries
        .where((e) =>
            e.status == 'active' && e.content.trim().isNotEmpty)
        .toList();
    if (active.isEmpty) return const MemorySearchResult();

    final queryTerms = _queryTerms(query);
    final queryScores = <String, double>{};
    final queryMatches = <String, List<String>>{};
    if (queryTerms.isNotEmpty) {
      for (final entry in active) {
        final matches = _queryMatches(entry, queryTerms);
        if (matches.isEmpty) continue;
        queryScores[entry.id] =
            (vectorScores[entry.id] ?? 0) + matches.length.toDouble();
        queryMatches[entry.id] = matches;
      }
    }

    final effectiveVectorScores = queryScores.isEmpty
        ? vectorScores
        : {...vectorScores, ...queryScores};
    final effectiveKeywordMatches = queryMatches.isEmpty
        ? keywordMatchedTerms
        : {...keywordMatchedTerms, ...queryMatches};

    // Run deterministic selector to get scored candidates
    final selection = MemorySelector.select(
      MemorySelectionInput(
        entries: active,
        vectorScores: effectiveVectorScores,
        keywordMatchedTerms: effectiveKeywordMatches,
        visibleMessageIds: visibleMessageIds,
        maxInjectedEntries: capped,
        sourceWindowExclusion: true,
        diversityAware: true,
        recencyBoost: true,
        importanceBoost: true,
      ),
    );

    final hits = selection.allScores
        .where((s) => !s.excludedBySourceWindow && s.score > 0)
        .take(capped)
        .map((s) => MemorySearchHit(
              entryId: s.entry.id,
              title: s.entry.title,
              score: s.score,
              matchedKeys: s.matchedKeys,
              tokenCost: MemorySelector.tokenCost(s.entry),
            ))
        .toList();

    return MemorySearchResult(hits: hits);
  }

  static Set<String> _queryTerms(String query) {
    return query
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}_]+', unicode: true))
        .where((term) => term.length >= 3)
        .toSet();
  }

  static List<String> _queryMatches(MemoryEntry entry, Set<String> terms) {
    final haystack = [
      entry.title,
      entry.content,
      entry.arc,
      ...entry.keys,
    ].join(' ').toLowerCase();
    return terms.where(haystack.contains).toList(growable: false);
  }
}

import '../../db/app_db.dart';
import '../../db/repositories/memory_catalog_repo.dart';
import '../../models/chat_message.dart';
import '../../models/memory_book.dart';
import '../retrieval_query_builder.dart';
import '../memory_catalog_builder.dart' show MemoryCatalogRowJson;
import '../memory_selector.dart' show memoryKeyMatchesGlaze;
import 'memory_vector_searcher.dart' show MemoryVectorSearcher;

/// Result of a memory catalog match: per-entry catalog scores and the
/// matched terms keyed by entry id.
class CatalogMatchResult {
  final Map<String, double> scores;
  final Map<String, List<String>> termsByEntryId;

  const CatalogMatchResult({
    this.scores = const {},
    this.termsByEntryId = const {},
  });
}

/// Matches memory entries against the catalog index (keys, entities,
/// locations, topics, title) using the retrieval query text.
///
/// Extracted from `MemoryInjectionService` (Phase 6a). The matcher holds
/// the catalog repo; all scoring is pure.
class MemoryCatalogMatcher {
  final MemoryCatalogRepo _catalogRepo;

  MemoryCatalogMatcher(this._catalogRepo);

  /// Match active entries against the catalog.
  ///
  /// - Loads catalog rows for the session.
  /// - If row count != active entry count (stale), rebuilds the catalog.
  /// - Builds a retrieval query from history + current text.
  /// - For each active row, collects matched terms (keys, entities,
  ///   locations, topics, title) and computes a catalog score.
  Future<CatalogMatchResult> match({
    required MemoryBook book,
    required List<MemoryEntry> activeEntries,
    required List<ChatMessage> history,
    required String currentText,
  }) async {
    try {
      var rows = await _catalogRepo.getBySessionId(book.sessionId);
      final activeIds = activeEntries.map((entry) => entry.id).toSet();
      final usableRows = rows
          .where(
            (row) =>
                activeIds.contains(row.memoryEntryId) &&
                row.status == 'active' &&
                !row.stale,
          )
          .toList(growable: false);
      if (usableRows.length != activeEntries.length) {
        rows = await _catalogRepo.rebuildForMemoryBook(book);
      }

      final scanText = RetrievalQueryBuilder.build(
        currentText: currentText,
        history: history,
        includeAssistant: book.settings.queryIncludeAssistant,
        recentTurns: book.settings.queryRecentTurns,
        maxChars: book.settings.queryMaxChars,
      ).toLowerCase();
      if (scanText.isEmpty) return const CatalogMatchResult();

      final activeMap = {for (final entry in activeEntries) entry.id: entry};
      final scores = <String, double>{};
      final termsByEntryId = <String, List<String>>{};
      for (final row in rows) {
        final entry = activeMap[row.memoryEntryId];
        if (entry == null || row.status != 'active' || row.stale) continue;
        final matched = matchedCatalogTerms(row, scanText);
        if (matched.isEmpty) continue;
        termsByEntryId[row.memoryEntryId] = matched;
        scores[row.memoryEntryId] = catalogScore(matched, row);
      }
      return CatalogMatchResult(
        scores: scores,
        termsByEntryId: termsByEntryId,
      );
    } catch (_) {
      return const CatalogMatchResult();
    }
  }

  /// Build the scan text used for keyword/catalog matching.
  ///
  /// In legacy mode this is the legacy vector query lowercased; otherwise
  /// it uses the v2 retrieval query builder.
  static String selectorScanText(
    MemoryBookSettings settings,
    List<ChatMessage> history,
    String currentText,
  ) {
    if (settings.memoryMode == 'legacy') {
      return MemoryVectorSearcher.legacyVectorQuery(
        history,
        currentText,
      ).toLowerCase();
    }
    return RetrievalQueryBuilder.build(
      currentText: currentText,
      history: history,
      includeAssistant: settings.queryIncludeAssistant,
      recentTurns: settings.queryRecentTurns,
      maxChars: settings.queryMaxChars,
    ).toLowerCase();
  }

  /// Match entry keys against the scan text using the configured match mode.
  static Map<String, List<String>> keywordMatches(
    List<MemoryEntry> entries,
    String scanText,
    String keyMatchMode,
  ) {
    if (scanText.isEmpty) return const {};
    final matchedByEntry = <String, List<String>>{};
    for (final entry in entries) {
      final matched = <String>[];
      for (final key in entry.keys) {
        if (key.trim().isEmpty) continue;
        final lowerKey = key.toLowerCase();
        final hit = switch (keyMatchMode) {
          'glaze' => memoryKeyMatchesGlaze(lowerKey, scanText),
          'both' =>
            scanText.contains(lowerKey) ||
                memoryKeyMatchesGlaze(lowerKey, scanText),
          _ => scanText.contains(lowerKey),
        };
        if (hit) matched.add(key);
      }
      if (matched.isNotEmpty) matchedByEntry[entry.id] = matched;
    }
    return matchedByEntry;
  }

  /// Collect matched catalog terms (keys, entities, locations, topics,
  /// title) that appear in the scan text. Terms shorter than 3 chars
  /// are skipped.
  static List<String> matchedCatalogTerms(
    MemoryCatalogRow row,
    String scanText,
  ) {
    final terms = <String>{
      ...row.keys,
      ...row.entities,
      ...row.locations,
      ...row.topics,
      row.title,
    };
    final matched = <String>[];
    for (final raw in terms) {
      final term = raw.trim().toLowerCase();
      if (term.length < 3) continue;
      if (scanText.contains(term)) matched.add(raw.trim());
    }
    matched.sort();
    return matched;
  }

  /// Score a catalog match: matched term count * 0.75 + importance * 0.5,
  /// scaled by a token-count decay factor.
  static double catalogScore(List<String> matched, MemoryCatalogRow row) {
    final tokenFactor = row.tokenCount <= 0
        ? 1.0
        : 1.0 / (1.0 + row.tokenCount / 8000);
    final importance = row.importance.clamp(0, 1) * 0.5;
    return (matched.length.clamp(1, 6) * 0.75 + importance) * tokenFactor;
  }
}
